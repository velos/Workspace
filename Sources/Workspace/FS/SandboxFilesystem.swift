import Foundation

public final class SandboxFilesystem: SessionConfigurableFilesystem, @unchecked Sendable {
    public enum Root: Sendable {
        case documents
        case caches
        case temporary
        case appGroup(String)
        case url(URL)
    }

    private let root: Root
    private let fileManager: FileManager
    private let backing: ReadWriteFilesystem

    public init(root: Root, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        backing = ReadWriteFilesystem(fileManager: fileManager)
    }

    public func configureForSession() throws {
        let resolvedRoot = try resolveRootURL()
        try backing.configure(rootDirectory: resolvedRoot)
    }

    public func configure(rootDirectory: URL) throws {
        try backing.configure(rootDirectory: rootDirectory)
    }

    public func stat(path: String) async throws -> FileInfo {
        try await backing.stat(path: path)
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await backing.listDirectory(path: path)
    }

    public func readFile(path: String) async throws -> Data {
        try await backing.readFile(path: path)
    }

    public func writeFile(path: String, data: Data, append: Bool) async throws {
        try await backing.writeFile(path: path, data: data, append: append)
    }

    public func createDirectory(path: String, recursive: Bool) async throws {
        try await backing.createDirectory(path: path, recursive: recursive)
    }

    public func remove(path: String, recursive: Bool) async throws {
        try await backing.remove(path: path, recursive: recursive)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await backing.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try await backing.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    public func createSymlink(path: String, target: String) async throws {
        try await backing.createSymlink(path: path, target: target)
    }

    public func createHardLink(path: String, target: String) async throws {
        try await backing.createHardLink(path: path, target: target)
    }

    public func readSymlink(path: String) async throws -> String {
        try await backing.readSymlink(path: path)
    }

    public func setPermissions(path: String, permissions: Int) async throws {
        try await backing.setPermissions(path: path, permissions: permissions)
    }

    public func resolveRealPath(path: String) async throws -> String {
        try await backing.resolveRealPath(path: path)
    }

    public func exists(path: String) async -> Bool {
        await backing.exists(path: path)
    }

    public func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try await backing.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    private func resolveRootURL() throws -> URL {
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
