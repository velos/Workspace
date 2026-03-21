import Foundation

public enum WorkspaceError: Error, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .invalidPath(path):
            if path.contains("\u{0}") {
                return "path contains null byte"
            }
            return "invalid path: \(path)"
        case let .unsupported(message):
            return message
        }
    }
}

public typealias ShellError = WorkspaceError

public struct FileInfo: Sendable {
    public var path: WorkspacePath
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: UInt64
    public var permissions: Int
    public var modificationDate: Date?

    public init(
        path: WorkspacePath,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }

    public init(
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?
    ) {
        self.init(
            path: WorkspacePath(normalizing: path),
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate
        )
    }
}

public struct DirectoryEntry: Sendable {
    public var name: String
    public var info: FileInfo

    public init(name: String, info: FileInfo) {
        self.name = name
        self.info = info
    }
}
