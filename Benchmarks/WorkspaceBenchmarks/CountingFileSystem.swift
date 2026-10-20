#if os(macOS) || os(Linux)
import Foundation
import Workspace

/// Counts calls at the decorator boundary, not syscalls performed within the backend.
/// In particular glob/copy/remove and checkpoint-store disk I/O are opaque here.
struct IOCounts: Codable, Equatable, Sendable {
    var calls: [String: Int64] = [:]
    var bytesRead: Int64 = 0
    var filesRead: Int64 = 0  // successful read invocations, including range/stream reads
    var directoryEntries: Int64 = 0
    var globMatches: Int64 = 0
}

/// A lock only protects counter updates; no lock is held across an await.
class CountingFileSystem: FileSystem, TraversingFileSystem, PotentialPathResolvingFileSystem, @unchecked Sendable {
    let base: any FileSystem
    private let lock = NSLock()
    private var counts = IOCounts()
    init(_ base: any FileSystem) { self.base = base }
    func reset() { lock.withLock { counts = IOCounts() } }
    func snapshot() -> IOCounts { lock.withLock { counts } }
    func call(_ name: String) { lock.withLock { counts.calls[name, default: 0] += 1 } }
    private func read(_ data: Data, file: Bool = true) {
        lock.withLock {
            counts.bytesRead += Int64(data.count)
            if file { counts.filesRead += 1 }
        }
    }
    nonisolated package var supportsScopedWalk: Bool { base.supportsScopedWalk }

    nonisolated(nonsending) package func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool,
                      visit: FileSystemWalkVisitor) async throws {
        call("walk")
        try await base.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories) { info, read, readLink in
            self.call("walkEntry")
            if info.path != path { self.lock.withLock { self.counts.directoryEntries += 1 } }
            // The callbacks remain scoped to this awaited visit; the temporary
            // conversion permits forwarding Swift's nested nonescaping parameters.
            try await withoutActuallyEscaping(read) { scopedRead in
                try await withoutActuallyEscaping(readLink) { scopedLink in
                    try await visit(info, { length in
                        self.call(length == nil ? "readFile" : "readRange")
                        let data = try await scopedRead(length)
                        self.read(data)
                        return data
                    }, {
                        self.call("readSymlink")
                        return try await scopedLink()
                    })
                }
            }
        }
    }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        call("stat")
        return try await base.stat(path: path)
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        call("listDirectory")
        let entries = try await base.listDirectory(path: path)
        lock.withLock { counts.directoryEntries += Int64(entries.count) }
        return entries
    }
    func readFile(path: WorkspacePath) async throws -> Data {
        call("readFile")
        let data = try await base.readFile(path: path)
        read(data)
        return data
    }
    func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        call("readRange")
        let data = try await base.readFile(path: path, offset: offset, length: length)
        read(data)
        return data
    }
    func readFileChunks(path: WorkspacePath, chunkSize: Int) async throws -> AsyncThrowingStream<
        Data, Error
    > {
        call("readChunks")
        let stream = try await base.readFileChunks(path: path, chunkSize: chunkSize)
        lock.withLock { counts.filesRead += 1 }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in stream {
                        self.read(data, file: false)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exists(path: WorkspacePath) async -> Bool {
        call("exists")
        return await base.exists(path: path)
    }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        call("glob")
        let paths = try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
        lock.withLock { counts.globMatches += Int64(paths.count) }
        return paths
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        call("writeFile")
        try await base.writeFile(path: path, data: data, append: append)
    }
    func createFile(path: WorkspacePath, data: Data) async throws {
        call("createFile")
        try await base.createFile(path: path, data: data)
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        call("createDirectory")
        try await base.createDirectory(path: path, recursive: recursive)
    }
    func remove(path: WorkspacePath, recursive: Bool) async throws {
        call("remove")
        try await base.remove(path: path, recursive: recursive)
    }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        call("move")
        try await base.move(from: sourcePath, to: destinationPath)
    }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        call("copy")
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }
    func createSymlink(path: WorkspacePath, target: String) async throws {
        call("createSymlink")
        try await base.createSymlink(path: path, target: target)
    }
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        call("createHardLink")
        try await base.createHardLink(path: path, target: target)
    }
    func readSymlink(path: WorkspacePath) async throws -> String {
        call("readSymlink")
        return try await base.readSymlink(path: path)
    }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        call("setPermissions")
        try await base.setPermissions(path: path, permissions: permissions)
    }
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        call("resolveRealPath")
        return try await base.resolveRealPath(path: path)
    }
    package func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath {
        call("resolvePotentialPath")
        guard let resolver = base as? any PotentialPathResolvingFileSystem else {
            throw WorkspaceError.unsupported("benchmark backend must support potential paths")
        }
        return try await resolver.resolvePotentialPath(path: path)
    }
    func capabilities() async -> FileSystemFeatures {
        call("capabilities")
        return await base.capabilities()
    }
}

/// Only Local advertises observation; all filesystem forwarding is inherited.
final class ObservedCountingFileSystem: CountingFileSystem, FileSystemChangeSource,
    @unchecked Sendable
{
    func changes() async throws -> AsyncStream<Void> {
        call("changes")
        guard let source = base as? any FileSystemChangeSource else {
            throw BenchmarkError.message("backend does not provide filesystem notifications")
        }
        return try await source.changes()
    }
}

#endif
