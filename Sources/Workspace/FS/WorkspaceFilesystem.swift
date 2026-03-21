import Foundation

public protocol WorkspaceFilesystem: AnyObject, Sendable {
    func configure(rootDirectory: URL) throws

    func stat(path: String) async throws -> FileInfo
    func listDirectory(path: String) async throws -> [DirectoryEntry]
    func readFile(path: String) async throws -> Data
    func writeFile(path: String, data: Data, append: Bool) async throws
    func createDirectory(path: String, recursive: Bool) async throws
    func remove(path: String, recursive: Bool) async throws
    func move(from sourcePath: String, to destinationPath: String) async throws
    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws
    func createSymlink(path: String, target: String) async throws
    func createHardLink(path: String, target: String) async throws
    func readSymlink(path: String) async throws -> String
    func setPermissions(path: String, permissions: Int) async throws
    func resolveRealPath(path: String) async throws -> String

    func exists(path: String) async -> Bool
    func glob(pattern: String, currentDirectory: String) async throws -> [String]
}

public typealias ShellFilesystem = WorkspaceFilesystem
