import Foundation

/// Errors produced by workspace path and filesystem operations.
public enum WorkspaceError: Error, CustomStringConvertible, Sendable {
    /// The caller supplied a path that cannot be represented safely.
    case invalidPath(String)
    /// The requested operation is not supported or cannot be completed in the current environment.
    case unsupported(String)

    /// A human-readable description of the error.
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

/// Backward-compatible alias for the legacy error name.
public typealias ShellError = WorkspaceError

/// Metadata describing a filesystem entry.
public struct FileInfo: Sendable {
    /// The normalized path for the entry.
    public var path: WorkspacePath
    /// Whether the entry is a directory.
    public var isDirectory: Bool
    /// Whether the entry is a symbolic link.
    public var isSymbolicLink: Bool
    /// The size of the entry in bytes.
    public var size: UInt64
    /// The POSIX permissions for the entry.
    public var permissions: Int
    /// The last modification timestamp when available.
    public var modificationDate: Date?

    /// Creates metadata for a filesystem entry.
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

    /// Convenience initializer that accepts a string path.
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

/// A named child entry returned from a directory listing.
public struct DirectoryEntry: Sendable {
    /// The child name relative to the listed directory.
    public var name: String
    /// The child's metadata.
    public var info: FileInfo

    /// Creates a directory entry.
    public init(name: String, info: FileInfo) {
        self.name = name
        self.info = info
    }
}
