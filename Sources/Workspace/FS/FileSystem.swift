import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors produced by workspace path and filesystem operations.
public enum WorkspaceError: Error, CustomStringConvertible, Sendable {
    /// The caller supplied a path that cannot be represented safely.
    case invalidPath(String)
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
    /// Persisted revision data for a checkpoint is missing.
    case revisionDataNotFound(UUID)
    /// A tracked workspace mutation could not be recorded.
    case mutationFailed(String)
    /// Persisted checkpoint or snapshot storage is damaged (for example, a missing content blob).
    case storageCorrupted(String)

    /// A human-readable description of the error.
    public var description: String {
        switch self {
        case let .invalidPath(path):
            if path.contains("\u{0}") {
                return "path contains null byte"
            }
            return "invalid path: \(path)"
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
        case let .revisionDataNotFound(id):
            return "workspace revision data not found: \(id.uuidString)"
        case let .mutationFailed(message):
            return message
        case let .storageCorrupted(message):
            return "workspace storage is corrupted: \(message)"
        }
    }
}

/// An operation failed and recovery also failed, either while restoring the
/// previous filesystem state or while retracting its mutation-history record.
public struct WorkspaceRollbackError: Error, CustomStringConvertible, Sendable {
    /// The operation or persistence error that triggered recovery.
    public let originalError: any Error
    /// The error encountered while restoring files or retracting history.
    public let rollbackError: any Error

    public var description: String {
        "\(originalError); restoring the previous state also failed: \(rollbackError)"
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
    /// Identity shared by aliases, when the backend supplies it. It must distinguish
    /// different entries across backend instances and agree for the same underlying entry.
    public var identity: FileIdentity?
    /// Number of hard links to this entry, when known. One rules out additional hard links;
    /// mounts may still expose the same entry at several virtual paths.
    public var linkCount: UInt64?

    /// Creates metadata for a filesystem entry.
    public init(
        path: WorkspacePath,
        kind: FileTree.Kind,
        size: UInt64,
        permissions: POSIXPermissions,
        modificationDate: Date?,
        identity: FileIdentity? = nil,
        linkCount: UInt64? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.identity = identity
        self.linkCount = linkCount
    }
}

/// Opaque identity of a filesystem entry, shared by aliases across backend instances.
/// Device and inode values must distinguish different entries across instances and remain
/// stable during an entry's lifetime; replacements receive a new identity. Independent
/// in-memory backends need distinct device tokens; disk backends can use st_dev and st_ino.
public struct FileIdentity: Hashable, Sendable, Codable {
    private let device: UInt64
    private let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
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

/// Optional features a filesystem implementation can advertise.
///
/// Callers can branch on capabilities instead of probing operations and catching
/// ``WorkspaceError/unsupported(_:)``.
public struct FileSystemFeatures: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Symbolic links can be created and read.
    public static let symlinks = FileSystemFeatures(rawValue: 1 << 0)
    /// Hard links can be created.
    public static let hardLinks = FileSystemFeatures(rawValue: 1 << 1)
    /// POSIX permissions can be read and mutated.
    public static let permissions = FileSystemFeatures(rawValue: 1 << 2)
    /// ``FileSystem/resolveRealPath(path:)`` resolves symlink chains.
    public static let realPathResolution = FileSystemFeatures(rawValue: 1 << 3)
    /// Non-appending writes follow the final symlink instead of replacing the link itself.
    /// Composing backends intersect this feature, so a mixed filesystem uses conservative
    /// byte accounting where the flag is absent. Appends follow existing final symlinks.
    public static let replacementFollowsFinalSymlink = FileSystemFeatures(rawValue: 1 << 4)
}

/// The low-level interface implemented by workspace storage backends.
public protocol FileSystem: AnyObject, Sendable {
    /// Returns metadata for the entry at `path`.
    func stat(path: WorkspacePath) async throws -> FileInfo
    /// Lists the direct children of the directory at `path`.
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry]
    /// Reads the file contents at `path`.
    func readFile(path: WorkspacePath) async throws -> Data
    /// Returns whether an entry exists at `path`, using lstat semantics: intermediate
    /// symlinks are followed, but the final symlink itself exists even when its target does not.
    func exists(path: WorkspacePath) async -> Bool
    /// Expands a glob pattern relative to `currentDirectory`.
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath]
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
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws
    /// Resolves the real path of `path`, following symlinks.
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath
    /// Returns the optional features this filesystem supports.
    func capabilities() async -> FileSystemFeatures
    /// Reads up to `length` bytes starting at `offset`. Passing `nil` reads to the end of the
    /// file; an offset at or past the end returns empty data.
    func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data
    /// Streams the file contents as chunks of at most `chunkSize` bytes.
    func readFileChunks(path: WorkspacePath, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error>
    /// Writes `data` to a new file, failing with `EEXIST` when an entry already exists at `path`.
    func createFile(path: WorkspacePath, data: Data) async throws
}

/// A filesystem that can push invalidations when its contents change outside Workspace APIs.
public protocol FileSystemChangeSource: FileSystem {
    /// Emits an unscoped invalidation. Workspace consumes `changeSignals()`, whose
    /// default implementation adapts this stream to `.rescan`.
    func changes() async throws -> AsyncStream<Void>
    /// Emits scoped invalidations using the `FileSystemChangeSignal` contract.
    func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal>
}

/// Opt-in guarantee that the stream covers every visible child. A composite must
/// re-evaluate this after topology changes and terminate a stream if coverage fails.
package protocol CompleteFileSystemChangeSource: FileSystemChangeSource {
    var changeSignalsAreComplete: Bool { get async }
}

extension FileSystem {
    package var changeSignalsAreComplete: Bool {
        get async { await (self as? any CompleteFileSystemChangeSource)?.changeSignalsAreComplete ?? false }
    }
}

#if os(macOS) || os(Linux)
extension LocalFileSystem: CompleteFileSystemChangeSource {
    package var changeSignalsAreComplete: Bool { true }
}
#endif

/// Invalidates paths in the change source's own filesystem namespace.
/// Include deleted or replaced ancestors so their former descendants are checked.
/// Use `.rescan` when paths are unknown, events were dropped, or coverage is uncertain.
public enum FileSystemChangeSignal: Sendable, Equatable {
    /// Invalidates the entire tree, including entries that no longer exist.
    case rescan
    /// Invalidates each path at its specified scope. Coalescing retains the strongest
    /// scope for a path; a shallow ancestor does not subsume descendant signals.
    case paths([WorkspacePath: Scope])

    public enum Scope: Int, Sendable, Comparable {
        /// Only this entry's contents or metadata changed. A removed or replaced
        /// directory also invalidates its former descendants.
        case entry
        /// This entry and its immediate directory listing may have changed. Existing
        /// child directories are not traversed; added or replaced subtrees are captured.
        case shallow
        /// Everything beneath this path is unknown, including former descendants.
        /// Use for directory creation, removal or rename, and incomplete subtree coverage.
        case recursive

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

extension FileSystemChangeSource {
    /// Compatibility for sources that only provide unscoped invalidations.
    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        let stream = try await changes()
        return AsyncStream { continuation in
            let task = Task {
                for await _ in stream where !Task.isCancelled { continuation.yield(.rescan) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Resolves links in the backend's namespace without requiring the target to exist.
/// Missing parent suffixes are retained for quota preflight without creating them.
package protocol PotentialPathResolvingFileSystem: FileSystem {
    func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath
}

extension FileSystem {
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

    /// The default implementation advertises no optional features.
    public func capabilities() async -> FileSystemFeatures {
        []
    }

    /// The default implementation reads the whole file and slices the requested range.
    /// Implementations backed by real files should override this with a seek-based read.
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        let data = try await readFile(path: path)
        guard offset < UInt64(data.count) else {
            return Data()
        }
        let start = data.index(data.startIndex, offsetBy: Int(offset))
        let end = length.map { data.index(start, offsetBy: $0, limitedBy: data.endIndex) ?? data.endIndex } ?? data.endIndex
        return Data(data[start..<end])
    }

    /// The default implementation reads the whole file once and yields it in chunks.
    /// Implementations backed by real files should override this with an incremental read.
    public func readFileChunks(
        path: WorkspacePath,
        chunkSize: Int
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard chunkSize > 0 else {
            throw WorkspaceError.unsupported("chunk size must be positive")
        }
        let data = try await readFile(path: path)
        return AsyncThrowingStream { continuation in
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                continuation.yield(Data(data[index..<end]))
                index = end
            }
            continuation.finish()
        }
    }

    /// The default implementation checks existence and then writes. Backends whose storage is
    /// shared with other writers should override this with an atomic exclusive create.
    public func createFile(path: WorkspacePath, data: Data) async throws {
        if await exists(path: path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
        }
        try await writeFile(path: path, data: data, append: false)
    }
}

typealias FileSystemCapabilities = FileSystemFeatures

/// Backend differences relevant to copy-on-write edit previews.
package struct FileSystemPreviewSemantics: Sendable {
    package var preservesOverwritePermissions: Bool
    package var followsDirectorySymlinks: Bool
    package var followsPermissionSymlinks: Bool
    package var createsWriteParents: Bool

    package init(preservesOverwritePermissions: Bool = false, followsDirectorySymlinks: Bool = false,
                followsPermissionSymlinks: Bool = false, createsWriteParents: Bool = false) {
        self.preservesOverwritePermissions = preservesOverwritePermissions
        self.followsDirectorySymlinks = followsDirectorySymlinks
        self.followsPermissionSymlinks = followsPermissionSymlinks
        self.createsWriteParents = createsWriteParents
    }
}

package protocol PreviewSemanticsFileSystem: FileSystem {
    func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics
}

extension FileSystem {
    package func previewBehavior(at path: WorkspacePath) async -> FileSystemPreviewSemantics {
        if let source = self as? any PreviewSemanticsFileSystem { return await source.previewSemantics(at: path) }
        return .init()
    }
}

/// Backends whose content changes always change mtime or identity, even within a clock tick.
/// Wrappers may forward this only when preserving those metadata guarantees.
package protocol ExactTimestampFileSystem: FileSystem {
    var hasExactContentTimestamps: Bool { get async }
}

extension FileSystem {
    package var supportsExactContentTimestamps: Bool {
        get async { await (self as? any ExactTimestampFileSystem)?.hasExactContentTimestamps ?? false }
    }
}
