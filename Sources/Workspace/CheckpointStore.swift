import Foundation

/// Persistence for workspace checkpoints, snapshots, and mutation logs.
protocol CheckpointStore: AnyObject, Sendable {
    func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint]
    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    func appendMutation(_ mutation: MutationRecord) async throws
    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord]
}

/// An in-memory checkpoint store for tests and ephemeral sessions.
actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [History.Checkpoint]] = [:]
    private var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
    private var mutationsByWorkspace: [UUID: [MutationRecord]] = [:]

    func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws {
        checkpointsByWorkspace[checkpoint.workspaceId, default: []].append(checkpoint)
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint? {
        checkpointsByWorkspace[workspaceId]?.first { $0.id == id }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint] {
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

    func appendMutation(_ mutation: MutationRecord) async throws {
        mutationsByWorkspace[mutation.workspaceId, default: []].append(mutation)
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
    }
}

/// A JSON file-backed checkpoint store.
actor FileCheckpointStore: CheckpointStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws {
        try ensureWorkspaceDirectories(for: checkpoint.workspaceId)
        try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: checkpoint.workspaceId))
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint? {
        let url = checkpointURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try read(History.Checkpoint.self, from: url)
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint] {
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

    func appendMutation(_ mutation: MutationRecord) async throws {
        try ensureWorkspaceDirectories(for: mutation.workspaceId)
        let url = mutationsURL(workspaceId: mutation.workspaceId)
        var records = try loadMutations(from: url)
        records.append(mutation)
        try write(records.sorted(by: { $0.sequence < $1.sequence }), to: url)
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        try loadMutations(from: mutationsURL(workspaceId: workspaceId)).sorted(by: { $0.sequence < $1.sequence })
    }

    private func loadMutations(from url: URL) throws -> [MutationRecord] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try read([MutationRecord].self, from: url)
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
}
