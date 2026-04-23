import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persistence for workspace checkpoints, snapshots, and mutation logs.
///
/// The store is the **source of truth** for `MutationRecord.sequence` values. Callers may pass
/// any placeholder sequence; ``appendMutation(_:)`` returns the record with the next persisted
/// monotonic number for that workspace, serialized under the mutations lock.
protocol CheckpointStore: AnyObject, Sendable {
    func saveCheckpoint(_ checkpoint: Checkpoint) async throws
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint]
    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    @discardableResult
    func appendMutation(_ mutation: MutationRecord) async throws -> MutationRecord
    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord]
}

/// An in-memory checkpoint store for tests and ephemeral workspaces.
actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [Checkpoint]] = [:]
    private var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
    private var mutationsByWorkspace: [UUID: [MutationRecord]] = [:]

    init() {}

    func saveCheckpoint(_ checkpoint: Checkpoint) async throws {
        var list = checkpointsByWorkspace[checkpoint.workspaceId] ?? []
        if let index = list.firstIndex(where: { $0.id == checkpoint.id }) {
            list[index] = checkpoint
        } else {
            list.append(checkpoint)
        }
        checkpointsByWorkspace[checkpoint.workspaceId] = list
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        checkpointsByWorkspace[workspaceId]?.first { $0.id == id }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        (checkpointsByWorkspace[workspaceId] ?? []).sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {
        snapshotsByWorkspace[workspaceId, default: [:]][snapshot.id] = snapshot
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        snapshotsByWorkspace[workspaceId]?[id]
    }

    @discardableResult
    func appendMutation(_ mutation: MutationRecord) async throws -> MutationRecord {
        var list = mutationsByWorkspace[mutation.workspaceId, default: []]
        let next = (list.map(\.sequence).max() ?? 0) + 1
        var record = mutation
        record.sequence = next
        list.append(record)
        mutationsByWorkspace[mutation.workspaceId] = list
        return record
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
    }
}

/// A JSON file-backed checkpoint store.
///
/// Mutations are stored as one JSON line per record in `mutations.jsonl` (append-friendly under
/// the lock) so each append rewrites a tiny tail instead of the entire log. A legacy
/// `mutations.json` array is migrated to JSONL on the next read or append. Writes are
/// synchronized through a persistent sidecar lockfile (`mutations.lock`) with an advisory
/// exclusive lock when the platform supports it (`flock`), so concurrent ``FileCheckpointStore``
/// instances in the same process and across cooperating processes do not lose appends. Checkpoint
/// and snapshot writes are per-artifact atomic replaces. Coordinating writers on network
/// filesystems that do not honor `flock` may still require application-level serialization.
actor FileCheckpointStore: CheckpointStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let compactEncoder: JSONEncoder

    private var listCheckpointsCache: [UUID: (cacheKey: String, checkpoints: [Checkpoint])] = [:]

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.compactEncoder = JSONEncoder()
    }

    func saveCheckpoint(_ checkpoint: Checkpoint) async throws {
        listCheckpointsCache[checkpoint.workspaceId] = nil
        try ensureWorkspaceDirectories(for: checkpoint.workspaceId)
        try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: checkpoint.workspaceId))
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        let url = checkpointURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(Checkpoint.self, from: url)
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        let directoryURL = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            listCheckpointsCache[workspaceId] = nil
            return []
        }
        if let key = try checkpointsDirectoryCacheKey(at: directoryURL),
           let entry = listCheckpointsCache[workspaceId], entry.cacheKey == key {
            return entry.checkpoints
        }

        let result = try fileManager
            .contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "json" }
            .map { try read(Checkpoint.self, from: $0) }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
        if let key = try checkpointsDirectoryCacheKey(at: directoryURL) {
            listCheckpointsCache[workspaceId] = (key, result)
        }
        return result
    }

    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {
        try ensureWorkspaceDirectories(for: workspaceId)
        try write(snapshot, to: snapshotURL(id: snapshot.id, workspaceId: workspaceId))
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(Snapshot.self, from: url)
    }

    @discardableResult
    func appendMutation(_ mutation: MutationRecord) async throws -> MutationRecord {
        try ensureWorkspaceDirectories(for: mutation.workspaceId)
        let jsonl = mutationsJsonlURL(workspaceId: mutation.workspaceId)
        let legacy = legacyMutationsArrayURL(workspaceId: mutation.workspaceId)
        let lockURL = mutationsLockURL(workspaceId: mutation.workspaceId)
        return try Self.withMutationsExclusiveLock(at: lockURL) {
            let existing = try loadAllMutations(jsonl: jsonl, legacy: legacy)
            let next = (existing.map(\.sequence).max() ?? 0) + 1
            var record = mutation
            record.sequence = next

            if fileManager.fileExists(atPath: jsonl.path) {
                try appendJSONLLine(encode: record, to: jsonl)
            } else {
                try writeAllMutationsAsJSONL([record], to: jsonl)
            }
            return record
        }
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        let jsonl = mutationsJsonlURL(workspaceId: workspaceId)
        let legacy = legacyMutationsArrayURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: jsonl.path) || fileManager.fileExists(atPath: legacy.path) else {
            return []
        }
        let lockURL = mutationsLockURL(workspaceId: workspaceId)
        return try Self.withMutationsExclusiveLock(at: lockURL) {
            try loadAllMutations(jsonl: jsonl, legacy: legacy)
                .sorted { $0.sequence < $1.sequence }
        }
    }

    private func loadAllMutations(jsonl: URL, legacy: URL) throws -> [MutationRecord] {
        if fileManager.fileExists(atPath: jsonl.path) {
            if fileManager.fileExists(atPath: legacy.path) {
                try? fileManager.removeItem(at: legacy)
            }
            return try loadMutationsFromJSONL(at: jsonl)
        }
        if fileManager.fileExists(atPath: legacy.path) {
            let data = try Data(contentsOf: legacy)
            if data.isEmpty { return [] }
            let records = try decoder.decode([MutationRecord].self, from: data)
            if !records.isEmpty {
                try fileManager.removeItem(at: legacy)
                try writeAllMutationsAsJSONL(records, to: jsonl)
            }
            return records
        }
        return []
    }

    private func loadMutationsFromJSONL(at url: URL) throws -> [MutationRecord] {
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        let text = String(data: data, encoding: .utf8) ?? ""
        var out: [MutationRecord] = []
        out.reserveCapacity(64)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.isEmpty { continue }
            out.append(try decoder.decode(MutationRecord.self, from: Data(String(line).utf8)))
        }
        return out
    }

    private func writeAllMutationsAsJSONL(_ records: [MutationRecord], to url: URL) throws {
        if records.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        var data = Data()
        for record in records.sorted(by: { $0.sequence < $1.sequence }) {
            var line = try compactEncoder.encode(record)
            line.append(Data("\n".utf8))
            data.append(line)
        }
        try data.write(to: url, options: .atomic)
    }

    private func appendJSONLLine(encode record: MutationRecord, to url: URL) throws {
        var line = try compactEncoder.encode(record)
        line.append(Data("\n".utf8))
        if fileManager.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    private func checkpointsDirectoryCacheKey(at url: URL) throws -> String? {
        let files = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let count = files.filter { $0.pathExtension == "json" }.count
        let mtime = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return "\(mtime?.timeIntervalSince1970 ?? 0)-\(count)"
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

    private func mutationsJsonlURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.jsonl", isDirectory: false)
    }

    private func legacyMutationsArrayURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.json", isDirectory: false)
    }

    /// A persistent sidecar lockfile used by ``withMutationsExclusiveLock(at:_:)``.
    ///
    /// The mutations log is append-only; we still take the lock on a **stable** sidecar so the lock
    /// is not taken on a file that is unlinked/renamed by atomic write helpers in other
    /// subsystems. Mutations are written to `mutations.jsonl` (or created there after migrating
    /// from a legacy `mutations.json` array on first access).
    private func mutationsLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.lock", isDirectory: false)
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
