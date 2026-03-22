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

/// The common interface for workspace filesystem implementations.
///
/// Paths are expressed as ``WorkspacePath`` values so callers can work with virtual paths that may
/// be backed by memory, overlays, mounts, sandboxes, or real disk storage.
public protocol WorkspaceFilesystem: AnyObject, Sendable {
    /// Configures the filesystem to use `rootDirectory` as its backing root when applicable.
    func configure(rootDirectory: URL) throws

    /// Returns metadata for the entry at `path`.
    func stat(path: WorkspacePath) async throws -> FileInfo
    /// Lists the direct children of the directory at `path`.
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry]
    /// Reads the file contents at `path`.
    func readFile(path: WorkspacePath) async throws -> Data
    /// Writes `data` to `path`, optionally appending instead of replacing.
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws
    /// Creates a directory at `path`.
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws
    /// Removes the entry at `path`.
    func remove(path: WorkspacePath, recursive: Bool) async throws
    /// Moves or renames an entry.
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws
    /// Copies an entry.
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws
    /// Creates a symbolic link at `path` pointing to `target`.
    func createSymlink(path: WorkspacePath, target: String) async throws
    /// Creates a hard link at `path` pointing to `target`.
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws
    /// Reads the target of the symbolic link at `path`.
    func readSymlink(path: WorkspacePath) async throws -> String
    /// Sets POSIX permissions on the entry at `path`.
    func setPermissions(path: WorkspacePath, permissions: Int) async throws
    /// Resolves the real path of `path`, following symlinks.
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath

    /// Returns whether an entry exists at `path`.
    func exists(path: WorkspacePath) async -> Bool
    /// Expands a glob pattern relative to `currentDirectory`.
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath]
}

/// Convenience overloads that accept raw string paths.
public extension WorkspaceFilesystem {
    /// Convenience overload for ``WorkspaceFilesystem/stat(path:)``.
    func stat(path: String) async throws -> FileInfo {
        try await stat(path: WorkspacePath(validating: path))
    }

    /// Convenience overload for ``WorkspaceFilesystem/listDirectory(path:)``.
    func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await listDirectory(path: WorkspacePath(validating: path))
    }

    /// Convenience overload for ``WorkspaceFilesystem/readFile(path:)``.
    func readFile(path: String) async throws -> Data {
        try await readFile(path: WorkspacePath(validating: path))
    }

    /// Convenience overload for ``WorkspaceFilesystem/writeFile(path:data:append:)``.
    func writeFile(path: String, data: Data, append: Bool) async throws {
        try await writeFile(path: WorkspacePath(validating: path), data: data, append: append)
    }

    /// Convenience overload for ``WorkspaceFilesystem/createDirectory(path:recursive:)``.
    func createDirectory(path: String, recursive: Bool) async throws {
        try await createDirectory(path: WorkspacePath(validating: path), recursive: recursive)
    }

    /// Convenience overload for ``WorkspaceFilesystem/remove(path:recursive:)``.
    func remove(path: String, recursive: Bool) async throws {
        try await remove(path: WorkspacePath(validating: path), recursive: recursive)
    }

    /// Convenience overload for ``WorkspaceFilesystem/move(from:to:)``.
    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(
            from: WorkspacePath(validating: sourcePath),
            to: WorkspacePath(validating: destinationPath)
        )
    }

    /// Convenience overload for ``WorkspaceFilesystem/copy(from:to:recursive:)``.
    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try await copy(
            from: WorkspacePath(validating: sourcePath),
            to: WorkspacePath(validating: destinationPath),
            recursive: recursive
        )
    }

    /// Convenience overload for ``WorkspaceFilesystem/createSymlink(path:target:)``.
    func createSymlink(path: String, target: String) async throws {
        try await createSymlink(path: WorkspacePath(validating: path), target: target)
    }

    /// Convenience overload for ``WorkspaceFilesystem/createHardLink(path:target:)``.
    func createHardLink(path: String, target: String) async throws {
        try await createHardLink(
            path: WorkspacePath(validating: path),
            target: WorkspacePath(validating: target)
        )
    }

    /// Convenience overload for ``WorkspaceFilesystem/readSymlink(path:)``.
    func readSymlink(path: String) async throws -> String {
        try await readSymlink(path: WorkspacePath(validating: path))
    }

    /// Convenience overload for ``WorkspaceFilesystem/setPermissions(path:permissions:)``.
    func setPermissions(path: String, permissions: Int) async throws {
        try await setPermissions(path: WorkspacePath(validating: path), permissions: permissions)
    }

    /// Convenience overload for ``WorkspaceFilesystem/resolveRealPath(path:)``.
    func resolveRealPath(path: String) async throws -> WorkspacePath {
        try await resolveRealPath(path: WorkspacePath(validating: path))
    }

    /// Convenience overload for ``WorkspaceFilesystem/exists(path:)``.
    func exists(path: String) async -> Bool {
        guard let path = WorkspacePath(path) else {
            return false
        }
        return await exists(path: path)
    }

    /// Convenience overload for ``WorkspaceFilesystem/glob(pattern:currentDirectory:)``.
    func glob(pattern: String, currentDirectory: String) async throws -> [WorkspacePath] {
        try await glob(pattern: pattern, currentDirectory: WorkspacePath(validating: currentDirectory))
    }
}

/// Backward-compatible alias for the legacy protocol name.
public typealias ShellFilesystem = WorkspaceFilesystem
