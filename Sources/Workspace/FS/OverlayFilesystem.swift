import Foundation

/// A filesystem that snapshots a disk directory into an in-memory overlay.
///
/// Mutations apply only to the overlay, leaving the source directory untouched until the overlay is
/// rebuilt.
public final class OverlayFilesystem: FileSystem, @unchecked Sendable {
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var overlay: InMemoryFilesystem
    private var rootURL: URL?

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// Creates an unconfigured overlay filesystem.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        overlay = InMemoryFilesystem()
    }

    /// Creates and configures an overlay for `rootDirectory`.
    public convenience init(rootDirectory: URL, fileManager: FileManager = .default) async throws {
        self.init(fileManager: fileManager)
        try await configure(rootDirectory: rootDirectory)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        let standardizedRoot = rootDirectory.standardizedFileURL
        let newOverlay = try await makeOverlay(from: standardizedRoot)
        withLock {
            rootURL = standardizedRoot
            overlay = newOverlay
        }
    }

    /// Rebuilds the overlay from the configured root directory.
    public func reload() async throws {
        let currentRoot = try withLock { () throws -> URL in
            guard let rootURL else {
                throw WorkspaceError.unsupported("overlay filesystem requires rootDirectory")
            }
            return rootURL
        }
        let newOverlay = try await makeOverlay(from: currentRoot)
        withLock {
            overlay = newOverlay
        }
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await currentOverlay().stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await currentOverlay().listDirectory(path: path)
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await currentOverlay().readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await currentOverlay().writeFile(path: path, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await currentOverlay().createDirectory(path: path, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await currentOverlay().remove(path: path, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await currentOverlay().move(from: sourcePath, to: destinationPath)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await currentOverlay().copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await currentOverlay().createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await currentOverlay().createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await currentOverlay().readSymlink(path: path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await currentOverlay().setPermissions(path: path, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await currentOverlay().resolveRealPath(path: path)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        await currentOverlay().exists(path: path)
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await currentOverlay().glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func currentOverlay() -> InMemoryFilesystem {
        withLock { overlay }
    }

    private func makeOverlay(from rootURL: URL) async throws -> InMemoryFilesystem {
        let overlay = InMemoryFilesystem()
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return overlay
        }

        let names = try fileManager.contentsOfDirectory(atPath: rootURL.path).sorted()
        for name in names {
            let childURL = rootURL.appendingPathComponent(name, isDirectory: true)
            try await importItem(at: childURL, virtualPath: WorkspacePath.root.appending(name), into: overlay)
        }
        return overlay
    }

    private func importItem(at url: URL, virtualPath: WorkspacePath, into overlay: InMemoryFilesystem) async throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissionBits = (attributes[.posixPermissions] as? NSNumber)?.intValue
        let permissions = permissionBits.map(POSIXPermissions.init(_:))

        if values.isSymbolicLink == true {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            try await overlay.createSymlink(path: virtualPath, target: target)
            if let permissions {
                try await overlay.setPermissions(path: virtualPath, permissions: permissions)
            }
            return
        }

        if values.isDirectory == true {
            try await overlay.createDirectory(path: virtualPath, recursive: true)
            if let permissions {
                try await overlay.setPermissions(path: virtualPath, permissions: permissions)
            }

            let children = try fileManager.contentsOfDirectory(atPath: url.path).sorted()
            for child in children {
                let childURL = url.appendingPathComponent(child, isDirectory: true)
                try await importItem(at: childURL, virtualPath: virtualPath.appending(child), into: overlay)
            }
            return
        }

        let data = try Data(contentsOf: url)
        try await overlay.writeFile(path: virtualPath, data: data, append: false)
        if let permissions {
            try await overlay.setPermissions(path: virtualPath, permissions: permissions)
        }
    }
}
