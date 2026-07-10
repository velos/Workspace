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
}

/// The low-level interface implemented by workspace storage backends.
public protocol FileSystem: AnyObject, Sendable {
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
