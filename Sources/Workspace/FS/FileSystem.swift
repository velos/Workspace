import Foundation

/// Errors produced by workspace path and filesystem operations.
public enum WorkspaceError: Error, CustomStringConvertible, Sendable {
    /// The caller supplied a path that cannot be represented safely.
    case invalidPath(String)
    /// The filesystem has no backing root configured.
    case notConfigured
    /// Mutations are not allowed (for example, read-only access).
    case readOnly
    /// File content is not valid for the requested operation (for example, not UTF-8 text).
    case invalidEncoding(WorkspacePath)
    /// JSON decoding failed for a file.
    case decodingFailed(WorkspacePath, underlying: String)
    /// An authorization policy denied the operation.
    case accessDenied(operation: String, message: String?)
    /// The requested operation is not supported or cannot be completed in the current environment.
    case unsupported(String)
    /// The requested checkpoint does not exist for this workspace.
    case checkpointNotFound(UUID)
    /// The snapshot artifact for a checkpoint is missing.
    case snapshotNotFound(UUID)
    /// The parent workspace changed after a branch was created, so the branch cannot be merged.
    case mergeConflict(parentWorkspaceId: UUID, expectedBase: UUID?, actualHead: UUID?)
    /// A tracked workspace mutation could not be recorded.
    case mutationFailed(String)

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case let .invalidPath(path):
            if path.contains("\u{0}") {
                return "path contains null byte"
            }
            return "invalid path: \(path)"
        case .notConfigured:
            return "filesystem is not configured"
        case .readOnly:
            return "filesystem is read-only"
        case let .invalidEncoding(path):
            return "file is not valid UTF-8: \(path)"
        case let .decodingFailed(path, underlying):
            return "invalid JSON: \(path) (\(underlying))"
        case let .accessDenied(operation, message):
            return message ?? "workspace access denied: \(operation)"
        case let .unsupported(message):
            return message
        case let .checkpointNotFound(checkpointId):
            return "workspace checkpoint not found: \(checkpointId.uuidString)"
        case let .snapshotNotFound(snapshotId):
            return "workspace snapshot not found: \(snapshotId.uuidString)"
        case let .mergeConflict(parentWorkspaceId, expectedBase, actualHead):
            let expected = expectedBase?.uuidString ?? "nil"
            let actual = actualHead?.uuidString ?? "nil"
            return "cannot merge branch into workspace \(parentWorkspaceId.uuidString): expected base \(expected), current head is \(actual)"
        case let .mutationFailed(message):
            return message
        }
    }
}

/// Metadata describing a filesystem entry.
public struct FileInfo: Sendable, Codable {
    /// The normalized path for the entry.
    public var path: WorkspacePath
    /// The logical kind of the entry.
    public var kind: FileTree.Kind
    /// The size of the entry in bytes.
    public var size: UInt64
    /// The POSIX permissions for the entry.
    public var permissions: POSIXPermissions
    /// The last modification timestamp when available.
    public var modificationDate: Date?

    /// Creates metadata for a filesystem entry.
    public init(
        path: WorkspacePath,
        kind: FileTree.Kind,
        size: UInt64,
        permissions: POSIXPermissions,
        modificationDate: Date?
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
    }
}

/// A named child entry returned from a directory listing.
public struct DirectoryEntry: Sendable, Codable {
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

/// Read-only filesystem capabilities.
public protocol ReadableFileSystem: AnyObject, Sendable {
    /// Returns metadata for the entry at `path`.
    func stat(path: WorkspacePath) async throws -> FileInfo
    /// Lists the direct children of the directory at `path`.
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry]
    /// Reads the file contents at `path`.
    func readFile(path: WorkspacePath) async throws -> Data
    /// Returns whether an entry exists at `path`.
    func exists(path: WorkspacePath) async -> Bool
    /// Expands a glob pattern relative to `currentDirectory`.
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath]
}

/// Writable filesystem capabilities.
public protocol WritableFileSystem: ReadableFileSystem {
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
}

/// The common interface for workspace filesystem implementations.
///
/// Paths are expressed as ``WorkspacePath`` values so callers can work with virtual paths that may
/// be backed by memory, overlays, mounts, sandboxes, or real disk storage.
public protocol FileSystem: WritableFileSystem {
    /// Configures the filesystem to use `rootDirectory` as its backing root when applicable.
    func configure(rootDirectory: URL) async throws
    /// Creates a symbolic link at `path` pointing to `target`.
    func createSymlink(path: WorkspacePath, target: String) async throws
    /// Creates a hard link at `path` pointing to `target`.
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws
    /// Reads the target of the symbolic link at `path`.
    func readSymlink(path: WorkspacePath) async throws -> String
    /// Sets POSIX permissions on the entry at `path`.
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws
    /// Resolves the real path of `path`, following symlinks.
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath
}

extension FileSystem {
    /// The default implementation throws ``WorkspaceError/notConfigured``.
    public func configure(rootDirectory: URL) async throws {
        _ = rootDirectory
        throw WorkspaceError.notConfigured
    }

    /// The default implementation throws ``WorkspaceError/unsupported(_:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = path
        _ = target
        throw WorkspaceError.unsupported("symbolic links are not supported by this filesystem")
    }

    /// The default implementation throws ``WorkspaceError/unsupported(_:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        _ = path
        _ = target
        throw WorkspaceError.unsupported("hard links are not supported by this filesystem")
    }

    /// The default implementation throws ``WorkspaceError/unsupported(_:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        _ = path
        throw WorkspaceError.unsupported("symbolic links are not supported by this filesystem")
    }

    /// The default implementation throws ``WorkspaceError/unsupported(_:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        _ = path
        _ = permissions
        throw WorkspaceError.unsupported("setting permissions is not supported by this filesystem")
    }

    /// The default implementation throws ``WorkspaceError/unsupported(_:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        _ = path
        throw WorkspaceError.unsupported("real path resolution is not supported by this filesystem")
    }
}
