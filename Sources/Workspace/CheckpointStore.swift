import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persistence for workspace checkpoints, snapshots, and mutation logs.
public protocol CheckpointStore: AnyObject, Sendable {
    func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint]
    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    func appendMutation(_ mutation: MutationRecord) async throws
    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord]
}

/// An in-memory checkpoint store for tests and ephemeral sessions.
public actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [History.Checkpoint]] = [:]
    private var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
    private var mutationsByWorkspace: [UUID: [MutationRecord]] = [:]

    public init() {}

    public func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws {
        var list = checkpointsByWorkspace[checkpoint.workspaceId] ?? []
        if let index = list.firstIndex(where: { $0.id == checkpoint.id }) {
            list[index] = checkpoint
        } else {
            list.append(checkpoint)
        }
        checkpointsByWorkspace[checkpoint.workspaceId] = list
    }

    public func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint? {
        checkpointsByWorkspace[workspaceId]?.first { $0.id == id }
    }

    public func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint] {
        (checkpointsByWorkspace[workspaceId] ?? []).sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    public func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {
        snapshotsByWorkspace[workspaceId, default: [:]][snapshot.id] = snapshot
    }

    public func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        snapshotsByWorkspace[workspaceId]?[id]
    }

    public func appendMutation(_ mutation: MutationRecord) async throws {
        mutationsByWorkspace[mutation.workspaceId, default: []].append(mutation)
    }

    public func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
    }
}

/// A JSON file-backed checkpoint store.
///
/// Mutations are appended to `mutations.json` under an advisory exclusive lock when supported
/// by the platform (`flock`), so concurrent processes using separate store instances against
/// the same root are less likely to corrupt that file. Checkpoint and snapshot writes remain
/// per-artifact atomic replaces; coordinating writers on network filesystems may still require
/// application-level serialization.
public actor FileCheckpointStore: CheckpointStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws {
        try ensureWorkspaceDirectories(for: checkpoint.workspaceId)
        try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: checkpoint.workspaceId))
    }

    public func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint? {
        let url = checkpointURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(History.Checkpoint.self, from: url)
    }

    public func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint] {
        let directoryURL = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try fileManager
            .contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .map { try read(History.Checkpoint.self, from: $0) }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    public func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {
        try ensureWorkspaceDirectories(for: workspaceId)
        try write(snapshot, to: snapshotURL(id: snapshot.id, workspaceId: workspaceId))
    }

    public func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(Snapshot.self, from: url)
    }

    public func appendMutation(_ mutation: MutationRecord) async throws {
        try ensureWorkspaceDirectories(for: mutation.workspaceId)
        let url = mutationsURL(workspaceId: mutation.workspaceId)
        try Self.withMutationsExclusiveLock(at: url) {
            var records = try loadMutations(from: url)
            records.append(mutation)
            try write(records.sorted(by: { $0.sequence < $1.sequence }), to: url)
        }
    }

    public func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        let url = mutationsURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try Self.withMutationsExclusiveLock(at: url) {
            try loadMutations(from: url).sorted(by: { $0.sequence < $1.sequence })
        }
    }

    private func loadMutations(from url: URL) throws -> [MutationRecord] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return []
        }
        return try decoder.decode([MutationRecord].self, from: data)
    }

    private func ensureWorkspaceDirectories(for workspaceId: UUID) throws {
        try fileManager.createDirectory(at: workspaceDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: checkpointsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
    }

    private func workspaceDirectoryURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    private func checkpointsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("checkpoints", isDirectory: true)
    }

    private func snapshotsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("snapshots", isDirectory: true)
    }

    private func checkpointURL(id: UUID, workspaceId: UUID) -> URL {
        checkpointsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func snapshotURL(id: UUID, workspaceId: UUID) -> URL {
        snapshotsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func mutationsURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.json", isDirectory: false)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private struct MutationsFileError: Error {
        var message: String
    }

#if canImport(Darwin) || canImport(Glibc)
    private static func withMutationsExclusiveLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        let path = url.path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw MutationsFileError(message: "could not open mutations file at \(path)")
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR {
                throw MutationsFileError(message: "could not acquire exclusive lock on mutations file at \(path)")
            }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
#else
    private static func withMutationsExclusiveLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        try body()
    }
#endif
}
