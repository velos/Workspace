import Foundation

public struct FileSystemLimits: Sendable, Codable, Equatable {
    public var maxTotalBytes: UInt64?
    public var maxEntryCount: Int?
    public var maxWriteBytes: Int?

    public init(maxTotalBytes: UInt64? = nil, maxEntryCount: Int? = nil, maxWriteBytes: Int? = nil) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntryCount = maxEntryCount
        self.maxWriteBytes = maxWriteBytes
    }
}

public enum FileSystemLimitError: Error, Sendable, Equatable, CustomStringConvertible {
    case totalBytes(attempted: UInt64, limit: UInt64)
    case entryCount(attempted: Int, limit: Int)
    case writeBytes(attempted: Int, limit: Int)

    public var description: String {
        switch self {
        case let .totalBytes(attempted, limit): "total byte limit exceeded: \(attempted) > \(limit)"
        case let .entryCount(attempted, limit): "entry count limit exceeded: \(attempted) > \(limit)"
        case let .writeBytes(attempted, limit): "write byte limit exceeded: \(attempted) > \(limit)"
        }
    }
}

/// A serializing filesystem decorator that rejects mutations exceeding projected limits.
public actor LimitedFileSystem: FileSystem {
    private let base: any FileSystem
    public let limits: FileSystemLimits

    public init(base: any FileSystem, limits: FileSystemLimits) {
        self.base = base
        self.limits = limits
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }
    public func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        try await base.readFile(path: path, offset: offset, length: length)
    }
    public func readFileChunks(path: WorkspacePath, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.readFileChunks(path: path, chunkSize: chunkSize)
    }
    public func capabilities() async -> FileSystemFeatures { await base.capabilities() }
    public func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }
    public func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    public func createFile(path: WorkspacePath, data: Data) async throws {
        try checkWrite(data.count)
        try await preflight { try await $0.createFile(path: path, data: data) }
        try await base.createFile(path: path, data: data)
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try checkWrite(data.count)
        try await preflight { try await $0.writeFile(path: path, data: data, append: append) }
        try await base.writeFile(path: path, data: data, append: append)
    }

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await preflight { try await $0.createDirectory(path: path, recursive: recursive) }
        try await base.createDirectory(path: path, recursive: recursive)
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await preflight { try await $0.remove(path: path, recursive: recursive) }
        try await base.remove(path: path, recursive: recursive)
    }

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await preflight { try await $0.move(from: sourcePath, to: destinationPath) }
        try await base.move(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await preflight {
            try await $0.copy(from: sourcePath, to: destinationPath, recursive: recursive)
        }
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await preflight { try await $0.createSymlink(path: path, target: target) }
        try await base.createSymlink(path: path, target: target)
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await preflight { try await $0.createHardLink(path: path, target: target) }
        try await base.createHardLink(path: path, target: target)
    }

    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    private func checkWrite(_ count: Int) throws {
        if let limit = limits.maxWriteBytes, count > limit {
            throw FileSystemLimitError.writeBytes(attempted: count, limit: limit)
        }
    }

    private func preflight(_ mutation: @Sendable (InMemoryFileSystem) async throws -> Void) async throws {
        let before = try await Snapshot.capture(from: base)
        let scratch = InMemoryFileSystem()
        try await Snapshot.restore(before, to: scratch)
        try await mutation(scratch)
        let projected = try await Snapshot.capture(from: scratch)
        let usage = Self.usage(projected.entry, isRoot: true)
        if let limit = limits.maxTotalBytes, usage.bytes > limit {
            throw FileSystemLimitError.totalBytes(attempted: usage.bytes, limit: limit)
        }
        if let limit = limits.maxEntryCount, usage.entries > limit {
            throw FileSystemLimitError.entryCount(attempted: usage.entries, limit: limit)
        }
    }

    private static func usage(_ entry: Snapshot.Entry, isRoot: Bool) -> (bytes: UInt64, entries: Int) {
        switch entry {
        case .missing:
            return (0, 0)
        case let .file(file):
            return (UInt64(file.data.count), isRoot ? 0 : 1)
        case .symlink:
            return (0, isRoot ? 0 : 1)
        case let .directory(directory):
            return directory.children.reduce((bytes: 0, entries: isRoot ? 0 : 1)) { result, child in
                let childUsage = usage(child, isRoot: false)
                return (result.bytes + childUsage.bytes, result.entries + childUsage.entries)
            }
        }
    }
}
