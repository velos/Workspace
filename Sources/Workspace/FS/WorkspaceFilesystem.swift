import Foundation

public protocol WorkspaceFilesystem: AnyObject, Sendable {
    func configure(rootDirectory: URL) throws

    func stat(path: WorkspacePath) async throws -> FileInfo
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry]
    func readFile(path: WorkspacePath) async throws -> Data
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws
    func remove(path: WorkspacePath, recursive: Bool) async throws
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws
    func createSymlink(path: WorkspacePath, target: String) async throws
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws
    func readSymlink(path: WorkspacePath) async throws -> String
    func setPermissions(path: WorkspacePath, permissions: Int) async throws
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath

    func exists(path: WorkspacePath) async -> Bool
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath]
}

public extension WorkspaceFilesystem {
    func stat(path: String) async throws -> FileInfo {
        try await stat(path: WorkspacePath(validating: path))
    }

    func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await listDirectory(path: WorkspacePath(validating: path))
    }

    func readFile(path: String) async throws -> Data {
        try await readFile(path: WorkspacePath(validating: path))
    }

    func writeFile(path: String, data: Data, append: Bool) async throws {
        try await writeFile(path: WorkspacePath(validating: path), data: data, append: append)
    }

    func createDirectory(path: String, recursive: Bool) async throws {
        try await createDirectory(path: WorkspacePath(validating: path), recursive: recursive)
    }

    func remove(path: String, recursive: Bool) async throws {
        try await remove(path: WorkspacePath(validating: path), recursive: recursive)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(
            from: WorkspacePath(validating: sourcePath),
            to: WorkspacePath(validating: destinationPath)
        )
    }

    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try await copy(
            from: WorkspacePath(validating: sourcePath),
            to: WorkspacePath(validating: destinationPath),
            recursive: recursive
        )
    }

    func createSymlink(path: String, target: String) async throws {
        try await createSymlink(path: WorkspacePath(validating: path), target: target)
    }

    func createHardLink(path: String, target: String) async throws {
        try await createHardLink(
            path: WorkspacePath(validating: path),
            target: WorkspacePath(validating: target)
        )
    }

    func readSymlink(path: String) async throws -> String {
        try await readSymlink(path: WorkspacePath(validating: path))
    }

    func setPermissions(path: String, permissions: Int) async throws {
        try await setPermissions(path: WorkspacePath(validating: path), permissions: permissions)
    }

    func resolveRealPath(path: String) async throws -> WorkspacePath {
        try await resolveRealPath(path: WorkspacePath(validating: path))
    }

    func exists(path: String) async -> Bool {
        guard let path = WorkspacePath(path) else {
            return false
        }
        return await exists(path: path)
    }

    func glob(pattern: String, currentDirectory: String) async throws -> [WorkspacePath] {
        try await glob(pattern: pattern, currentDirectory: WorkspacePath(validating: currentDirectory))
    }
}

public typealias ShellFilesystem = WorkspaceFilesystem
