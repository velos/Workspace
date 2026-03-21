import Foundation

public final class SandboxFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    public enum Root: Sendable {
        case documents
        case caches
        case temporary
        case appGroup(String)
        case url(URL)
    }

    private let backing: ReadWriteFilesystem

    public init(root: Root, fileManager: FileManager = .default) throws {
        backing = ReadWriteFilesystem(fileManager: fileManager)
        let resolvedRoot = try Self.resolveRootURL(root, fileManager: fileManager)
        try backing.configure(rootDirectory: resolvedRoot)
    }

    public func configure(rootDirectory: URL) throws {
        try backing.configure(rootDirectory: rootDirectory)
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    public func readFile(path: WorkspacePath) async throws -> Data {
        try await backing.readFile(path: path)
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await backing.writeFile(path: path, data: data, append: append)
    }

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await backing.remove(path: path, recursive: recursive)
    }

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await backing.createSymlink(path: path, target: target)
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await backing.createHardLink(path: path, target: target)
    }

    public func readSymlink(path: WorkspacePath) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    public func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await backing.resolveRealPath(path: path)
    }

    public func exists(path: WorkspacePath) async -> Bool {
        await backing.exists(path: path)
    }

    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await backing.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private static func resolveRootURL(_ root: Root, fileManager: FileManager) throws -> URL {
        switch root {
        case .temporary:
            return fileManager.temporaryDirectory
        case .documents:
            guard let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw ShellError.unsupported("documents directory is unavailable")
            }
            return url
        case .caches:
            guard let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw ShellError.unsupported("caches directory is unavailable")
            }
            return url
        case let .appGroup(identifier):
            guard identifier.hasPrefix("group.") else {
                throw ShellError.unsupported("invalid app group identifier: \(identifier)")
            }
            guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                throw ShellError.unsupported("app group container unavailable: \(identifier)")
            }
            return url
        case let .url(url):
            return url
        }
    }
}
