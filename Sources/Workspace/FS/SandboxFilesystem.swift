import Foundation

/// A disk-backed filesystem rooted in a standard app sandbox location.
public final class SandboxFilesystem: FileSystem, @unchecked Sendable {
    /// Supported strategies for choosing the sandbox root.
    public enum Root: Sendable {
        /// The user's documents directory.
        case documents
        /// The user's caches directory.
        case caches
        /// The process temporary directory.
        case temporary
        /// An app group container identified by its group identifier.
        case appGroup(String)
        /// A caller-supplied URL inside the app sandbox.
        case url(URL)
    }

    private let backing: ReadWriteFilesystem

    /// Creates a sandbox filesystem rooted according to `root`.
    public init(root: Root, fileManager: FileManager = .default) throws {
        backing = ReadWriteFilesystem(fileManager: fileManager)
        let resolvedRoot = try Self.resolveRootURL(root, fileManager: fileManager)
        try backing.applyConfiguration(rootDirectory: resolvedRoot)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    public func configure(rootDirectory: URL) async throws {
        try await backing.configure(rootDirectory: rootDirectory)
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try await backing.readFile(path: path)
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await backing.writeFile(path: path, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await backing.remove(path: path, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await backing.createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await backing.createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await backing.resolveRealPath(path: path)
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        await backing.exists(path: path)
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await backing.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private static func resolveRootURL(_ root: Root, fileManager: FileManager) throws -> URL {
        switch root {
        case .temporary:
            return fileManager.temporaryDirectory
        case .documents:
            guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw WorkspaceError.unsupported("documents directory is unavailable")
            }
            return url
        case .caches:
            guard let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw WorkspaceError.unsupported("caches directory is unavailable")
            }
            return url
        case let .appGroup(identifier):
            guard identifier.hasPrefix("group.") else {
                throw WorkspaceError.unsupported("invalid app group identifier: \(identifier)")
            }
            guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                throw WorkspaceError.unsupported("app group container unavailable: \(identifier)")
            }
            return url
        case let .url(url):
            return url
        }
    }
}
