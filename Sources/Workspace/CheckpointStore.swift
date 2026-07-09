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
/// the lock). Appends derive the next sequence from the log's final record instead of re-reading
/// the whole log, so appends stay cheap as histories grow. A partial trailing line left by a
/// crashed append is skipped when reading and truncated before the next append. A legacy
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
            let lastSequence: Int
            if fileManager.fileExists(atPath: jsonl.path) {
                if fileManager.fileExists(atPath: legacy.path) {
                    try? fileManager.removeItem(at: legacy)
                }
                try repairTornTail(at: jsonl)
                lastSequence = try lastPersistedSequence(at: jsonl)
            } else {
                // First write, or a legacy `mutations.json` array awaiting migration.
                lastSequence = try loadAllMutations(jsonl: jsonl, legacy: legacy).map(\.sequence).max() ?? 0
            }
            var record = mutation
            record.sequence = lastSequence + 1

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
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        var out: [MutationRecord] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            do {
                out.append(try decoder.decode(MutationRecord.self, from: Data(String(line).utf8)))
            } catch {
                // A crashed append leaves a strict prefix of `<json>\n`: an undecodable final
                // line with no trailing newline. Tolerate exactly that torn tail; anything else
                // is real corruption and must surface.
                if index == lines.count - 1, !endsWithNewline {
                    continue
                }
                throw error
            }
        }
        return out
    }

    /// Truncates a partial trailing line left behind by a crashed append so subsequent appends
    /// do not glue new records onto the torn fragment. A torn append never contains a newline
    /// (it is a strict prefix of `<json>\n`), so everything after the final newline — or the
    /// whole file when none exists — is the torn region. Must be called under the mutations lock.
    private func repairTornTail(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        let lastByte = try handle.read(upToCount: 1)
        guard lastByte != Data("\n".utf8) else { return }
        let newlineOffset = try Self.lastNewlineOffset(in: handle, before: size - 1)
        try handle.truncate(atOffset: newlineOffset.map { $0 + 1 } ?? 0)
    }

    /// Returns the sequence of the final record without loading the whole log. Appends are
    /// strictly monotonic and full rewrites are sorted by sequence, so the last line always
    /// carries the maximum. Falls back to a full scan for unusual tails such as blank trailing
    /// lines. Must be called under the mutations lock, after ``repairTornTail(at:)``.
    private func lastPersistedSequence(at url: URL) throws -> Int {
        if let line = try lastLine(at: url),
           let record = try? decoder.decode(MutationRecord.self, from: line) {
            return record.sequence
        }
        return try loadMutationsFromJSONL(at: url).map(\.sequence).max() ?? 0
    }

    private func lastLine(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReading: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 1 else { return nil }
        // The file ends with `\n` after tail repair; the last line spans the byte after the
        // previous newline through the byte before the trailing newline.
        let lineEnd = size - 1
        let newlineOffset = try Self.lastNewlineOffset(in: handle, before: lineEnd)
        let lineStart = newlineOffset.map { $0 + 1 } ?? 0
        guard lineEnd > lineStart else { return nil }
        try handle.seek(toOffset: lineStart)
        let line = try handle.read(upToCount: Int(lineEnd - lineStart)) ?? Data()
        return line.isEmpty ? nil : line
    }

    /// Scans backwards in chunks for the offset of the last `\n` strictly before `end`.
    private static func lastNewlineOffset(in handle: FileHandle, before end: UInt64) throws -> UInt64? {
        let chunkSize: UInt64 = 65536
        var cursor = end
        while cursor > 0 {
            let chunkStart = cursor > chunkSize ? cursor - chunkSize : 0
            try handle.seek(toOffset: chunkStart)
            let chunk = try handle.read(upToCount: Int(cursor - chunkStart)) ?? Data()
            if let index = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                return chunkStart + UInt64(chunk.distance(from: chunk.startIndex, to: index))
            }
            cursor = chunkStart
        }
        return nil
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
