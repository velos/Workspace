import Foundation

/// A filesystem that snapshots a disk directory into an in-memory overlay.
///
/// Mutations apply only to the overlay, leaving the source directory untouched until the overlay is
/// rebuilt.
public final class OverlayFilesystem: FileSystem, @unchecked Sendable {
    private let fileManager: FileManager
    private let overlay: InMemoryFilesystem
    private var rootURL: URL?

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
        rootURL = rootDirectory.standardizedFileURL
        try await reload()
    }

    /// Rebuilds the overlay from the configured root directory.
    public func reload() async throws {
        guard rootURL != nil else {
            throw WorkspaceError.unsupported("overlay filesystem requires rootDirectory")
        }
        try await rebuildOverlay()
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await overlay.stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await overlay.listDirectory(path: path)
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await overlay.readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await overlay.writeFile(path: path, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await overlay.createDirectory(path: path, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await overlay.remove(path: path, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await overlay.move(from: sourcePath, to: destinationPath)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await overlay.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await overlay.createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await overlay.createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await overlay.readSymlink(path: path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await overlay.setPermissions(path: path, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await overlay.resolveRealPath(path: path)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        await overlay.exists(path: path)
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await overlay.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func rebuildOverlay() async throws {
        overlay.reset()

        guard let rootURL else {
            return
        }

        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }

        let names = try fileManager.contentsOfDirectory(atPath: rootURL.path).sorted()
        for name in names {
            let childURL = rootURL.appendingPathComponent(name, isDirectory: true)
            try await importItem(at: childURL, virtualPath: WorkspacePath.root.appending(name))
        }
    }

    private func importItem(at url: URL, virtualPath: WorkspacePath) async throws {
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
                try await importItem(at: childURL, virtualPath: virtualPath.appending(child))
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
