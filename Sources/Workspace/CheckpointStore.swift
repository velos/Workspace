import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persistence for workspace checkpoints, snapshots, and mutation logs.
///
/// The store is the **source of truth** for `Mutation.sequence` values. Callers may pass
/// any placeholder sequence; ``appendMutation(_:)`` returns the record with the next persisted
/// monotonic number for that workspace, serialized under the mutations lock.
protocol CheckpointStore: CheckpointRevisionStore, AnyObject, Sendable {
    func prepare(workspaceId: UUID) async throws
    func changes(workspaceId: UUID) async throws -> AsyncStream<Void>
    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint
    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint]
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    func resolveSnapshotFile(id: UUID, workspaceId: UUID, path: WorkspacePath) async throws -> (path: WorkspacePath, size: UInt64)
    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex?
    func snapshotEntry(id: UUID, workspaceId: UUID, path: WorkspacePath, includeChildren: Bool) async throws -> RevisionIndex.Entry?
    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data?
    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation
    func listMutations(workspaceId: UUID, afterSequence: Int) async throws -> MutationPage
    /// Retracts one failed operation's record without lowering the workspace's
    /// sequence high-water mark. Later appends must never reuse its sequence.
    func removeMutation(sequence: Int, workspaceId: UUID) async throws
    /// Removes mutation records with `sequence <= throughSequence`. The record carrying the
    /// highest sequence is always retained so later appends stay monotonic.
    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws
    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics
    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult
}

/// Records and invalidation metadata from the same locked read.
struct MutationPage: Sendable {
    var records: [Mutation]
    var retractionEpoch: Int
}

extension CheckpointStore {
    func resolveSnapshotFile(id: UUID, workspaceId: UUID, path: WorkspacePath) async throws -> (path: WorkspacePath, size: UInt64) {
        guard let index = try await loadRevisionIndex(id: id, workspaceId: workspaceId) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        return try index.readableFile(at: path)
    }

    func snapshotEntry(id: UUID, workspaceId: UUID, path: WorkspacePath, includeChildren: Bool) async throws -> RevisionIndex.Entry? {
        guard let index = try await loadRevisionIndex(id: id, workspaceId: workspaceId) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        return index.entry(at: path)
    }

    func listMutations(workspaceId: UUID) async throws -> [Mutation] {
        try await listMutations(workspaceId: workspaceId, afterSequence: 0).records
    }
}

/// An in-memory checkpoint store for tests and ephemeral workspaces.
actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [Checkpoint]] = [:]
    var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
    var captureMetadataBySnapshot = CaptureMetadataCache()
    private(set) var revisionIndexBuildCount = 0
    private var revisionIndexesByWorkspace: [UUID: [UUID: RevisionIndex]] = [:]
    private var mutationsByWorkspace: [UUID: [Mutation]] = [:]
    private var mutationHighWaterMarks: [UUID: Int] = [:]
    private var mutationRetractionEpochs: [UUID: Int] = [:]

    init() {}

    func prepare(workspaceId: UUID) async throws {}

    func changes(workspaceId: UUID) async throws -> AsyncStream<Void> {
        _ = workspaceId
        return AsyncStream { _ in }
    }

    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint {
        try await captureRevisionWithMetadata(from: filesystem, draft: draft)
    }

    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint {
        try persistRevision(snapshot, draft: draft, mutationCursor: persistedMutationCursor(workspaceId: draft.workspaceID))
    }

    func persistedMutationCursor(workspaceId: UUID) -> Int {
        mutationHighWaterMarks[workspaceId] ?? 0
    }

    func persistRevision(_ snapshot: Snapshot, draft: CheckpointDraft, mutationCursor: Int) throws -> Checkpoint {
        var list = checkpointsByWorkspace[draft.workspaceID] ?? []
        let parent = resolvedParent(for: draft, checkpoints: list)
        let parentSnapshot = parent.flatMap { snapshotsByWorkspace[draft.workspaceID]?[$0.snapshotId] }
        if let parent, parentSnapshot == nil {
            throw WorkspaceError.storageCorrupted("checkpoint \(parent.id) has no snapshot")
        }
        var snapshot = snapshot
        snapshot.entry = Self.carryContentIDs(snapshot.entry, reusing: parentSnapshot?.entry)
        let checkpoint = Checkpoint.make(
            snapshot: snapshot,
            draft: draft,
            mutationCursor: mutationCursor,
            parent: parent,
            parentSnapshot: parentSnapshot
        )
        snapshotsByWorkspace[draft.workspaceID, default: [:]][snapshot.id] = snapshot
        revisionIndexesByWorkspace[draft.workspaceID]?[snapshot.id] = nil
        list.append(checkpoint)
        checkpointsByWorkspace[draft.workspaceID] = list.sorted(by: Checkpoint.orderedBefore)
        return checkpoint
    }

    private static func carryContentIDs(_ entry: Snapshot.Entry, reusing previous: Snapshot.Entry?) -> Snapshot.Entry {
        switch entry {
        case var .file(file):
            if file.contentID == nil {
                if case let .file(old) = previous, old.data == file.data, let hash = old.contentID {
                    file.contentID = hash
                } else { file.contentID = SHA256.hexDigest(of: file.data) }
            }
            return .file(file)
        case var .directory(directory):
            let oldChildren: [WorkspacePath: Snapshot.Entry]
            if case let .directory(old) = previous {
                oldChildren = Dictionary(uniqueKeysWithValues: old.children.map { ($0.path, $0) })
            } else { oldChildren = [:] }
            directory.children = directory.children.map { carryContentIDs($0, reusing: oldChildren[$0.path]) }
            return .directory(directory)
        case .missing, .symlink: return entry
        }
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

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        snapshotsByWorkspace[workspaceId]?[id]
    }

    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex? {
        if let cached = revisionIndexesByWorkspace[workspaceId]?[id] { return cached }
        guard let snapshot = snapshotsByWorkspace[workspaceId]?[id] else { return nil }
        let index = RevisionIndex(snapshot: snapshot)
        revisionIndexBuildCount += 1
        revisionIndexesByWorkspace[workspaceId, default: [:]][id] = index
        return index
    }

    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data? {
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        guard let snapshot = snapshotsByWorkspace[workspaceId]?[id],
              let entry = Workspace.snapshotEntry(at: path, in: snapshot.entry),
              case let .file(file) = entry
        else { return nil }
        guard offset < UInt64(file.data.count) else { return Data() }
        let start = file.data.index(file.data.startIndex, offsetBy: Int(offset))
        let count = min(length ?? file.data.count, file.data.count - Int(offset))
        let end = file.data.index(start, offsetBy: count)
        return Data(file.data[start..<end])
    }

    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation {
        var list = mutationsByWorkspace[mutation.workspaceID, default: []]
        let next = (mutationHighWaterMarks[mutation.workspaceID] ?? 0) + 1
        var record = mutation
        record.sequence = next
        mutationHighWaterMarks[mutation.workspaceID] = next
        list.append(record)
        mutationsByWorkspace[mutation.workspaceID] = list
        return record
    }

    func removeMutation(sequence: Int, workspaceId: UUID) async throws {
        mutationsByWorkspace[workspaceId]?.removeAll { $0.sequence == sequence }
        mutationRetractionEpochs[workspaceId, default: 0] += 1
    }

    func listMutations(workspaceId: UUID, afterSequence: Int) async throws -> MutationPage {
        MutationPage(
            records: (mutationsByWorkspace[workspaceId] ?? []).filter { $0.sequence > afterSequence }.sorted { $0.sequence < $1.sequence },
            retractionEpoch: mutationRetractionEpochs[workspaceId] ?? 0
        )
    }

    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws {
        let records = (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
        guard let last = records.last else {
            return
        }
        var kept = records.filter { $0.sequence > throughSequence }
        if kept.isEmpty {
            kept = [last]
        }
        if kept.count != records.count { mutationRetractionEpochs[workspaceId, default: 0] += 1 }
        mutationsByWorkspace[workspaceId] = kept
    }

    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics {
        statistics(
            checkpoints: checkpointsByWorkspace[workspaceId] ?? [],
            snapshots: snapshotsByWorkspace[workspaceId] ?? [:]
        )
    }

    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult {
        let currentCheckpoints = checkpointsByWorkspace[workspaceId] ?? []
        let currentSnapshots = snapshotsByWorkspace[workspaceId] ?? [:]
        let before = statistics(checkpoints: currentCheckpoints, snapshots: currentSnapshots)
        let plan = try CheckpointRetentionPlanner.plan(checkpoints: currentCheckpoints, retaining: retention)
        let retained = try CheckpointRetentionPlanner.materialize(plan) { snapshotID in
            currentSnapshots[snapshotID]
        }

        let retainedSnapshotIDs = Set(retained.map(\.snapshotId))
        let retainedSnapshots = currentSnapshots.filter { retainedSnapshotIDs.contains($0.key) }
        let after = statistics(checkpoints: retained, snapshots: retainedSnapshots)
        let report = Workspace.CompactionReport(
            dryRun: dryRun,
            before: before,
            after: after,
            removedCheckpointIDs: plan.removedCheckpointIDs,
            rebasedCheckpointIDs: plan.rebasedCheckpointIDs
        )

        if !dryRun {
            checkpointsByWorkspace[workspaceId] = retained
            snapshotsByWorkspace[workspaceId] = retainedSnapshots
            revisionIndexesByWorkspace[workspaceId] = revisionIndexesByWorkspace[workspaceId]?.filter {
                retainedSnapshotIDs.contains($0.key)
            }
        }
        if !dryRun {
            let live = Set(snapshotsByWorkspace.values.flatMap { $0.keys })
            captureMetadataBySnapshot.retain(live)
        }
        return StoreCompactionResult(report: report, checkpoints: retained)
    }

    private func resolvedParent(for draft: CheckpointDraft, checkpoints: [Checkpoint]) -> Checkpoint? {
        if let preferred = draft.preferredParentID,
           let parent = checkpoints.first(where: { $0.id == preferred }) {
            return parent
        }
        guard draft.preferredParentID != nil,
              let headID = Checkpoint.lineageHeadID(in: checkpoints)
        else { return nil }
        return checkpoints.first(where: { $0.id == headID })
    }

    private func statistics(
        checkpoints: [Checkpoint],
        snapshots: [UUID: Snapshot]
    ) -> Workspace.StorageStatistics {
        var blobs: [String: UInt64] = [:]
        for snapshot in snapshots.values {
            collectBlobStatistics(snapshot.entry, into: &blobs)
        }
        return Workspace.StorageStatistics(
            checkpointCount: checkpoints.count,
            snapshotCount: snapshots.count,
            blobCount: blobs.count,
            blobBytes: blobs.values.reduce(0, +)
        )
    }

    private func collectBlobStatistics(_ entry: Snapshot.Entry, into blobs: inout [String: UInt64]) {
        switch entry {
        case let .file(file):
            blobs[file.contentID ?? SHA256.hexDigest(of: file.data)] = UInt64(file.data.count)
        case let .directory(directory):
            for child in directory.children { collectBlobStatistics(child, into: &blobs) }
        case .missing, .symlink:
            break
        }
    }
}

/// A JSON file-backed checkpoint store.
///
/// Mutations are stored as one JSON line per record in `mutations.jsonl` (append-friendly under
/// the lock). Appends derive the next sequence from the log's final record instead of re-reading
/// the whole log, so appends stay cheap as histories grow. A partial trailing line left by a
/// crashed append is skipped when reading and truncated before the next append. Writes are
/// synchronized through a persistent sidecar lockfile (`mutations.lock`) with an advisory
/// exclusive lock when the platform supports it (`flock`), so concurrent ``FileCheckpointStore``
/// instances in the same process and across cooperating processes do not lose appends. A separate
/// lifecycle lock serializes checkpoint commits, revision reads, and compaction; rebased metadata
/// is written before unreachable artifacts are removed, keeping interrupted compaction recoverable.
/// In-process async gates serialize reentrant callers before OS locking; contended OS locks wait
/// off the cooperative executor so a suspended capture can resume and release its lock.
/// Coordinating writers on network filesystems that do not honor `flock` may still require
/// application-level serialization.
actor FileCheckpointStore: CheckpointStore {
    private let rootDirectory: URL
    let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let compactEncoder: JSONEncoder

    private let checkpointCapture: Workspace.CheckpointCapturePolicy
    // Actor reentrancy must suspend contenders before they can conflict with this store's own fd.
    private var heldLocks: Set<PathName> = []
    private var lockWaiters: [PathName: [CheckedContinuation<Void, Never>]] = [:]

    var listCheckpointsCache: [UUID: (cacheKey: String, checkpoints: [Checkpoint])] = [:]

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        checkpointCapture: Workspace.CheckpointCapturePolicy = .trustMetadata,
        cacheByteLimit: Int = FileCheckpointStore.defaultCacheByteLimit
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.checkpointCapture = checkpointCapture
        let budget = max(0, cacheByteLimit)
        let catalogBudget = budget / 4
        self.treeCache = CostLRU(limit: budget - catalogBudget)
        self.packCatalog = CostLRU(limit: catalogBudget)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.compactEncoder = JSONEncoder()
        self.compactEncoder.outputFormatting = [.sortedKeys]
    }

    func prepare(workspaceId: UUID) async throws {
        try await ensureWorkspaceDirectories(for: workspaceId)
    }

    func changes(workspaceId: UUID) async throws -> AsyncStream<Void> {
        try await ensureWorkspaceDirectories(for: workspaceId)
        return try DirectoryChangeStream.observe(checkpointsDirectoryURL(workspaceId: workspaceId))
    }

    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint {
        try await ensureWorkspaceDirectories(for: draft.workspaceID)
        return try await withExclusiveLock(at: lifecycleLockURL(workspaceId: draft.workspaceID)) {
            // The snapshot was captured by the caller before acquiring the lifecycle lock.
            let mutationCursor = try await persistedMutationCursor(workspaceId: draft.workspaceID)
            let checkpoints = try loadAllCheckpointsUnlocked(workspaceId: draft.workspaceID)
            let parent = resolvedParent(for: draft, checkpoints: checkpoints)
            let parentManifest = try parent.map {
                guard let manifest = try loadManifestUnlocked(id: $0.snapshotId, workspaceId: draft.workspaceID) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \($0.id) has no snapshot")
                }
                return manifest
            }
            let parentSnapshot = try parentManifest.map {
                Snapshot(id: $0.id, rootPath: $0.rootPath,
                         entry: try snapshotEntry(from: $0.root, workspaceId: draft.workspaceID))
            }
            let checkpoint = Checkpoint.make(
                snapshot: snapshot,
                draft: draft,
                mutationCursor: mutationCursor,
                parent: parent,
                parentSnapshot: parentSnapshot
            )
            try writeSnapshotUnlocked(snapshot, workspaceId: draft.workspaceID, reusing: parentManifest?.root)
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID), durability: .publication)
            listCheckpointsCache[draft.workspaceID] = nil
            return checkpoint
        }
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            let url = checkpointURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let checkpoint = try read(Checkpoint.self, from: url)
            guard checkpoint.id == id, checkpoint.workspaceID == workspaceId else {
                throw WorkspaceError.storageCorrupted("checkpoint metadata does not match its storage path")
            }
            return checkpoint
        }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        let directoryURL = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            listCheckpointsCache[workspaceId] = nil
            return []
        }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            if let key = try checkpointsDirectoryCacheKey(at: directoryURL),
               let entry = listCheckpointsCache[workspaceId], entry.cacheKey == key {
                return entry.checkpoints
            }

            let result = try loadAllCheckpointsUnlocked(workspaceId: workspaceId)
            if let key = try checkpointsDirectoryCacheKey(at: directoryURL) {
                listCheckpointsCache[workspaceId] = (key, result)
            }
            return result
        }
    }

    /// Schemas 1/2 inline the recursive tree and reference loose blobs. Schema 3
    /// stores a small root, content-addressed directory references, and optional pack ranges.
    /// The outer store format is version 2, fencing writers that only understand inline trees.
    struct SnapshotManifest: Codable, Sendable {
        struct Node: Codable, Sendable, Equatable {
            enum Kind: String, Codable {
                case file, directory, symlink, missing
            }

            var kind: Kind
            var path: WorkspacePath
            var permissions: POSIXPermissions?
            var contentHash: String?
            var contentSize: UInt64? = nil
            var modificationDate: Date? = nil
            var identity: FileIdentity? = nil
            var symlinkTarget: String?
            var children: [Node]?
            var treeHash: String? = nil
            var packed: PackedBlob? = nil

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.kind == rhs.kind && lhs.path == rhs.path &&
                lhs.permissions == rhs.permissions && lhs.contentHash == rhs.contentHash &&
                lhs.contentSize == rhs.contentSize && lhs.modificationDate == rhs.modificationDate &&
                FileIdentity.matchesForMetadataReuse(lhs.identity, rhs.identity) &&
                lhs.symlinkTarget.map(PathName.init) == rhs.symlinkTarget.map(PathName.init) &&
                lhs.children == rhs.children && lhs.treeHash == rhs.treeHash && lhs.packed == rhs.packed
            }
        }

        var version: Int
        var id: UUID
        var rootPath: WorkspacePath
        var root: Node
        // Older manifests and materialized snapshots have no trustworthy capture timestamp.
        var captureStartedAt: Date? = nil
        var exactContentTimestamps: Bool? = nil

        private enum CodingKeys: String, CodingKey {
            case version, id, rootPath, root, treeRoot, captureStartedAt, exactContentTimestamps
        }

        init(version: Int, id: UUID, rootPath: WorkspacePath, root: Node, captureStartedAt: Date? = nil, exactContentTimestamps: Bool? = nil) {
            self.version = version
            self.id = id
            self.rootPath = rootPath
            self.root = root
            self.captureStartedAt = captureStartedAt
            self.exactContentTimestamps = exactContentTimestamps
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            id = try values.decode(UUID.self, forKey: .id)
            rootPath = try values.decode(WorkspacePath.self, forKey: .rootPath)
            root = try values.decode(Node.self, forKey: version >= 3 ? .treeRoot : .root)
            captureStartedAt = try values.decodeIfPresent(Date.self, forKey: .captureStartedAt)
            exactContentTimestamps = try values.decodeIfPresent(Bool.self, forKey: .exactContentTimestamps)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(id, forKey: .id)
            try values.encode(rootPath, forKey: .rootPath)
            // Deliberately omit v1's required root key: even an already-admitted
            // legacy operation must fail decoding before it can sweep live blobs.
            try values.encode(root, forKey: version >= 3 ? .treeRoot : .root)
            try values.encodeIfPresent(captureStartedAt, forKey: .captureStartedAt)
            try values.encodeIfPresent(exactContentTimestamps, forKey: .exactContentTimestamps)
        }
    }

    /// Names are validated before entering the cache; no absolute paths are persisted.
    private struct TreeEntry: Codable, Sendable, Equatable {
        var name: String
        var kind: SnapshotManifest.Node.Kind
        var permissions: POSIXPermissions?
        var contentHash: String?
        var contentSize: UInt64?
        var modificationDate: Date?
        var identity: FileIdentity?
        var symlinkTarget: String?
        var treeHash: String?
        var packed: PackedBlob?

        init(_ node: SnapshotManifest.Node, name: String? = nil) throws {
            self.init(metadataOf: node, name: name ?? node.path.name)
            try Self.validate(self.name)
        }

        /// Prior leaf metadata can also represent a file at the snapshot root.
        /// This initializer is never used to publish or cache directory entries.
        init(metadataOf node: SnapshotManifest.Node, name: String) {
            self.name = name
            kind = node.kind
            permissions = node.permissions
            contentHash = node.contentHash
            contentSize = node.contentSize
            modificationDate = node.modificationDate
            identity = node.identity
            symlinkTarget = node.symlinkTarget
            treeHash = node.treeHash
            packed = node.packed
        }

        static func validate(_ name: String) throws {
            guard !name.isEmpty, !name.utf8.elementsEqual(".".utf8), !name.utf8.elementsEqual("..".utf8),
                  !name.utf8.contains(47), !name.utf8.contains(0) else {
                throw WorkspaceError.storageCorrupted("invalid tree entry name")
            }
        }

        func node(in parent: WorkspacePath) -> SnapshotManifest.Node {
            node(at: parent.appending(name))
        }

        func node(at path: WorkspacePath) -> SnapshotManifest.Node {
            .init(kind: kind, path: path, permissions: permissions,
                  contentHash: contentHash, contentSize: contentSize, modificationDate: modificationDate, identity: identity,
                  symlinkTarget: symlinkTarget, treeHash: treeHash, packed: packed)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.kind == rhs.kind &&
                lhs.permissions == rhs.permissions && lhs.contentHash == rhs.contentHash &&
                lhs.contentSize == rhs.contentSize && lhs.modificationDate == rhs.modificationDate &&
                FileIdentity.matchesForMetadataReuse(lhs.identity, rhs.identity) &&
                lhs.symlinkTarget.map(PathName.init) == rhs.symlinkTarget.map(PathName.init) &&
                lhs.treeHash == rhs.treeHash && lhs.packed == rhs.packed
        }

        /// Trees are validated and sorted by exact name bytes before being cached.
        static func index(of name: String, in entries: [Self]) -> Int? {
            var low = 0, high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if entries[mid].name.utf8.lexicographicallyPrecedes(name.utf8) { low = mid + 1 }
                else { high = mid }
            }
            return low < entries.count && entries[low].name.utf8.elementsEqual(name.utf8) ? low : nil
        }

        var estimatedBytes: Int {
            // String buffers, array storage, optional fields and allocator overhead.
            var stringBytes = name.utf8.count
            stringBytes += contentHash?.utf8.count ?? 0
            stringBytes += treeHash?.utf8.count ?? 0
            stringBytes += symlinkTarget?.utf8.count ?? 0
            stringBytes += packed?.pack.utf8.count ?? 0
            return 256 + 2 * stringBytes
        }
    }

    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint {
        try await ensureWorkspaceDirectories(for: draft.workspaceID)
        return try await withExclusiveLock(at: lifecycleLockURL(workspaceId: draft.workspaceID)) {
            let mutationCursor = try await self.persistedMutationCursor(workspaceId: draft.workspaceID)
            let checkpoints = try self.loadAllCheckpointsUnlocked(workspaceId: draft.workspaceID)
            let parent = self.resolvedParent(for: draft, checkpoints: checkpoints)
            let parentManifest: SnapshotManifest?
            if let parent {
                guard let manifest = try self.loadManifestUnlocked(
                    id: parent.snapshotId,
                    workspaceId: draft.workspaceID
                ) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \(parent.id) has no snapshot")
                }
                parentManifest = manifest
            } else {
                parentManifest = nil
            }
            try self.requireCurrentFormatUnlocked(workspaceId: draft.workspaceID)
            let batch = try self.makeBlobBatch(workspaceId: draft.workspaceID)
            defer { batch.close() }
            batch.summarizeInsertions = parentManifest == nil
            let captureStartedAt = Date()
            let snapshotID = UUID()
            let root = try await self.captureManifest(
                from: filesystem,
                reusing: parentManifest?.root,
                previousCaptureStartedAt: parentManifest?.captureStartedAt,
                workspaceId: draft.workspaceID,
                batch: batch
            )
            try self.finish(batch, workspaceId: draft.workspaceID)
            let manifest = SnapshotManifest(
                version: 3, id: snapshotID, rootPath: .root, root: root, captureStartedAt: captureStartedAt,
                exactContentTimestamps: await filesystem.supportsExactContentTimestamps
            )
            let summary: ChangeSet.Summary
            if let parentManifest {
                summary = try await self.compareNodes(parentManifest.root, root, workspaceId: draft.workspaceID, capturing: true).summary
            } else {
                summary = try self.creationSummary(root, workspaceId: draft.workspaceID, insertedLines: batch.insertedLines, capturing: true)
            }
            let checkpoint = Checkpoint.make(
                snapshotID: snapshotID,
                draft: draft,
                mutationCursor: mutationCursor,
                parent: parent,
                summary: summary
            )
            try Task.checkCancellation()
            try self.write(manifest, to: self.snapshotURL(id: snapshotID, workspaceId: draft.workspaceID), durability: .publication)
            try self.write(
                checkpoint,
                to: self.checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID), durability: .publication
            )
            self.listCheckpointsCache[draft.workspaceID] = nil
            return checkpoint
        }
    }

    private func writeSnapshotUnlocked(_ snapshot: Snapshot, workspaceId: UUID, reusing previous: SnapshotManifest.Node?) throws {
        try requireCurrentFormatUnlocked(workspaceId: workspaceId)
        let batch = try makeBlobBatch(workspaceId: workspaceId)
        defer { batch.close() }
        let root = try writeManifestNode(snapshot.entry, workspaceId: workspaceId, batch: batch, reusing: previous)
        try finish(batch, workspaceId: workspaceId)
        let manifest = SnapshotManifest(
            version: 3,
            id: snapshot.id,
            rootPath: snapshot.rootPath,
            root: root
        )
        try write(manifest, to: snapshotURL(id: snapshot.id, workspaceId: workspaceId), durability: .publication)
    }

    func loadManifestUnlocked(id: UUID, workspaceId: UUID) throws -> SnapshotManifest? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        guard (1...3).contains(manifest.version), manifest.id == id else {
            throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
        }
        return manifest
    }

    /// A frame keeps cached name-only entries intact. Only a requested old child
    /// becomes a Node; legacy recursive manifests retain their embedded children.
    private struct CaptureDirectory {
        var path: WorkspacePath
        var name: String
        var childOffset: Int
        var previous: SnapshotManifest.Node?
        var previousEntries: [TreeEntry]
        var legacyChildren: [SnapshotManifest.Node]?
        var children: [TreeEntry] = []

        func previousEntry(named name: String) -> TreeEntry? {
            guard let index = TreeEntry.index(of: name, in: previousEntries) else { return nil }
            return previousEntries[index]
        }

        func previousNode(named name: String, at path: WorkspacePath) -> SnapshotManifest.Node? {
            guard let index = TreeEntry.index(of: name, in: previousEntries) else { return nil }
            return legacyChildren?[index] ?? previousEntries[index].node(at: path)
        }
    }

    private func captureManifest(
        from filesystem: any FileSystem,
        reusing previous: SnapshotManifest.Node?,
        previousCaptureStartedAt: Date?,
        workspaceId: UUID,
        batch: BlobBatch
    ) async throws -> SnapshotManifest.Node {
        guard filesystem.supportsScopedWalk else {
            return try await captureManifestNode(from: filesystem, at: .root, reusing: previous,
                previousCaptureStartedAt: previousCaptureStartedAt, workspaceId: workspaceId, batch: batch)
        }
        var stack: [CaptureDirectory] = []
        var root = SnapshotManifest.Node(kind: .missing, path: .root)
        try await filesystem.walk(skippingVanishedEntries: true) { info, read, readLink in
            try Task.checkCancellation()
            let path = info.path
            let node: SnapshotManifest.Node
            let name: String
            if info.kind == .directory, stack.last?.path == path {
                // A nonempty directory closes after its descendants. Its name and
                // parent are already known; there is no path lookup on this branch.
                let directory = stack.removeLast()
                name = directory.name
                node = try self.finishCaptureDirectory(info, directory: directory, workspaceId: workspaceId)
            } else if path.isRoot {
                name = "/"
                if info.kind == .directory {
                    node = try self.finishCaptureDirectory(info,
                        directory: self.captureDirectory(reusing: previous, at: path, name: name, workspaceId: workspaceId),
                        workspaceId: workspaceId)
                } else {
                    node = try await self.captureLeaf(info, reusing: previous.map { TreeEntry(metadataOf: $0, name: "/") },
                        previousCaptureStartedAt: previousCaptureStartedAt, workspaceId: workspaceId,
                        batch: batch, read: read, readLink: readLink)
                }
            } else {
                if stack.isEmpty {
                    stack.append(try self.captureDirectory(reusing: previous, at: .root, name: "/", workspaceId: workspaceId))
                }
                // Postorder first reaches a new directory through a descendant.
                // Parse only the suffix below the current frame; ordinary siblings
                // need just their stored name, without hashing/constructing parents.
                guard path != stack.last!.path, path.isWithin(stack.last!.path) else {
                    // A walker that breaks depth-first postorder would otherwise build wrong trees.
                    throw WorkspaceError.storageCorrupted("capture walk visited \(path) outside \(stack.last!.path)")
                }
                var suffix = path.string.utf8.dropFirst(stack.last!.childOffset)
                while let slash = suffix.firstIndex(of: 47) {
                    let component = String(decoding: suffix[..<slash], as: UTF8.self)
                    try TreeEntry.validate(component)
                    let parent = stack.last!
                    let directoryPath = parent.path.appending(component)
                    let old = parent.previousNode(named: component, at: directoryPath)
                    stack.append(try self.captureDirectory(reusing: old, at: directoryPath, name: component, workspaceId: workspaceId))
                    suffix = suffix[suffix.index(after: slash)...]
                }
                name = String(decoding: suffix, as: UTF8.self)
                try TreeEntry.validate(name)
                if info.kind == .directory {
                    let old = stack.last!.previousNode(named: name, at: path)
                    node = try self.finishCaptureDirectory(info,
                        directory: self.captureDirectory(reusing: old, at: path, name: name, workspaceId: workspaceId),
                        workspaceId: workspaceId)
                } else {
                    node = try await self.captureLeaf(info, reusing: stack.last!.previousEntry(named: name),
                        previousCaptureStartedAt: previousCaptureStartedAt, workspaceId: workspaceId,
                        batch: batch, read: read, readLink: readLink)
                }
            }
            if path.isRoot { root = node }
            else { stack[stack.count - 1].children.append(try TreeEntry(node, name: name)) }
        }
        return root
    }

    private func captureDirectory(
        reusing previous: SnapshotManifest.Node?, at path: WorkspacePath, name: String, workspaceId: UUID
    ) throws -> CaptureDirectory {
        let entries: [TreeEntry]
        let legacy: [SnapshotManifest.Node]?
        if let previous, previous.kind == .directory {
            if let hash = previous.treeHash {
                entries = try treeEntries(hash: hash, workspaceId: workspaceId, capturing: true)
                legacy = nil
            } else {
                legacy = (previous.children ?? []).sorted { PathName($0.path.name) < PathName($1.path.name) }
                entries = try legacy!.map { try TreeEntry($0) }
                for index in entries.indices.dropFirst() {
                    guard PathName(entries[index - 1].name) < PathName(entries[index].name) else {
                        throw WorkspaceError.storageCorrupted("snapshot directory \(path) contains duplicate child \(entries[index].name)")
                    }
                }
            }
        } else { entries = []; legacy = nil }
        return CaptureDirectory(path: path, name: name, childOffset: path.isRoot ? 1 : path.string.utf8.count + 1,
                                previous: previous, previousEntries: entries, legacyChildren: legacy)
    }

    private func finishCaptureDirectory(
        _ info: FileInfo, directory: CaptureDirectory, workspaceId: UUID
    ) throws -> SnapshotManifest.Node {
        let entries = directory.children.sorted { PathName($0.name) < PathName($1.name) }
        if let previous = directory.previous, previous.kind == .directory, previous.treeHash != nil,
           directory.previousEntries == entries {
            var reused = previous
            reused.permissions = info.permissions
            reused.modificationDate = info.modificationDate
            reused.identity = info.identity
            return reused
        }
        return try persistDirectory(SnapshotManifest.Node(
            kind: .directory, path: info.path, permissions: info.permissions, modificationDate: info.modificationDate, identity: info.identity
        ), entries: entries, workspaceId: workspaceId, capturing: true)
    }

    private func captureManifestNode(
        from filesystem: any FileSystem,
        at path: WorkspacePath,
        reusing previous: SnapshotManifest.Node?,
        previousCaptureStartedAt: Date?,
        workspaceId: UUID,
        batch: BlobBatch
    ) async throws -> SnapshotManifest.Node {
        try Task.checkCancellation()
        guard let info = try await Snapshot.infoIfPresent(at: path, on: filesystem) else {
            return SnapshotManifest.Node(kind: .missing, path: path)
        }
        if info.kind == .directory {
            var directory = try captureDirectory(reusing: previous, at: path, name: path.name, workspaceId: workspaceId)
            for entry in try await filesystem.listDirectory(path: path).sorted(by: { PathName(walkSortKey($0)) < PathName(walkSortKey($1)) }) {
                try TreeEntry.validate(entry.name)
                let childPath = path.appending(entry.name)
                let child = try await captureManifestNode(from: filesystem, at: childPath,
                    reusing: directory.previousNode(named: entry.name, at: childPath),
                    previousCaptureStartedAt: previousCaptureStartedAt, workspaceId: workspaceId, batch: batch)
                // A listed child can vanish before its own lstat. Skip it on both
                // routes, while content read failures after metadata still propagate.
                if child.kind != .missing { directory.children.append(try TreeEntry(child, name: entry.name)) }
            }
            return try finishCaptureDirectory(info, directory: directory, workspaceId: workspaceId)
        }
        return try await captureLeaf(info, reusing: previous.map { TreeEntry(metadataOf: $0, name: path.name) }, previousCaptureStartedAt: previousCaptureStartedAt,
            workspaceId: workspaceId, batch: batch,
            read: { _ in try await filesystem.readFile(path: path) },
            readLink: { try await filesystem.readSymlink(path: path) })
    }

    private func captureLeaf(
        _ info: FileInfo,
        reusing previous: TreeEntry?,
        previousCaptureStartedAt: Date?,
        workspaceId: UUID,
        batch: BlobBatch,
        read: @Sendable (Int?) async throws -> Data,
        readLink: @Sendable () async throws -> String
    ) async throws -> SnapshotManifest.Node {
        let path = info.path
        switch info.kind {
        case .file:
            // Conservatively cover second-resolution and two-second-resolution timestamps.
            // Equality alone is unsafe when an entry was captured in its timestamp's tick.
            if checkpointCapture == .trustMetadata,
               let previousCaptureStartedAt,
               let modificationDate = info.modificationDate,
               modificationDate.addingTimeInterval(2) < previousCaptureStartedAt,
               previous?.kind == .file,
               previous?.contentSize == info.size,
               (previous?.identity == nil || info.identity == nil
                    || FileIdentity.matchesForMetadataReuse(previous?.identity, info.identity)),
               previous?.modificationDate != nil,
               previous?.modificationDate == info.modificationDate,
               let hash = previous?.contentHash,
               Self.isValidContentHash(hash),
               let previous,
               blobExists(previous.node(at: path), workspaceId: workspaceId, batch: batch) {
                return SnapshotManifest.Node(
                    kind: .file,
                    path: path,
                    permissions: info.permissions,
                    contentHash: hash,
                    contentSize: info.size,
                    modificationDate: info.modificationDate, identity: info.identity,
                    packed: previous.packed
                )
            }
            let data = try await read(nil)
            let hash = SHA256.hexDigest(of: data)
            if batch.summarizeInsertions, data.count <= 1_000_000,
               !data.withUnsafeBytes({ $0.contains(0) }), let text = String(data: data, encoding: .utf8) {
                batch.insertedLines[path] = TextDiff.lineBased(from: "", to: text).statistics.additions
            }
            let packed = try batch.store(data, hash: hash)
            return SnapshotManifest.Node(
                kind: .file,
                path: path,
                permissions: info.permissions,
                contentHash: hash,
                contentSize: UInt64(data.count),
                modificationDate: info.modificationDate, identity: info.identity,
                packed: packed
            )
        case .symlink:
            return SnapshotManifest.Node(
                kind: .symlink,
                path: path,
                permissions: info.permissions,
                modificationDate: info.modificationDate, identity: info.identity,
                symlinkTarget: try await readLink()
            )
        case .directory:
            preconditionFailure("directories must be captured postorder")
        }
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try loadSnapshotUnlocked(id: id, workspaceId: workspaceId)
        }
    }

    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else { return nil }
            return RevisionIndex(
                id: manifest.id,
                root: manifest.rootPath,
                entry: try revisionEntry(from: manifest.root, workspaceId: workspaceId)
            )
        }
    }

    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId),
                  let node = try manifestNode(at: path, in: manifest.root, workspaceId: workspaceId), node.kind == .file
            else { return nil }
            return try readBlob(node, workspaceId: workspaceId, offset: offset, length: length)
        }
    }

    func revisionEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID,
        depth: Int? = nil,
        capturing: Bool = false
    ) throws -> RevisionIndex.Entry {
        switch node.kind {
        case .missing:
            return .missing(path: node.path)
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            return .file(
                path: node.path,
                size: node.contentSize ?? 0,
                permissions: node.permissions ?? .defaultFile,
                contentID: hash
            )
        case .directory:
            return .directory(
                path: node.path,
                permissions: node.permissions ?? .defaultDirectory,
                children: depth == 0 ? [] : try children(of: node, workspaceId: workspaceId, capturing: capturing).map {
                    try revisionEntry(from: $0, workspaceId: workspaceId, depth: depth.map { $0 - 1 }, capturing: capturing)
                }
            )
        case .symlink:
            return .symbolicLink(
                path: node.path,
                target: node.symlinkTarget ?? "",
                permissions: node.permissions ?? POSIXPermissions(0o777)
            )
        }
    }

    private func manifestNode(at path: WorkspacePath, in root: SnapshotManifest.Node, workspaceId: UUID) throws -> SnapshotManifest.Node? {
        let components = path.components
        guard path.isWithin(root.path) else { return nil }
        let prefix = root.path.components
        var node = root
        for component in components.dropFirst(prefix.count) {
            let name = PathName(component)
            guard node.kind == .directory else { return nil }
            if let hash = node.treeHash {
                let entries = try treeEntries(hash: hash, workspaceId: workspaceId)
                guard let index = TreeEntry.index(of: component, in: entries) else { return nil }
                node = entries[index].node(in: node.path)
            } else {
                // Legacy manifests already contain absolute child nodes.
                guard let child = node.children?.first(where: { PathName($0.path.name) == name }) else { return nil }
                node = child
            }
        }
        return node
    }

    func writeManifestNode(
        _ entry: Snapshot.Entry,
        workspaceId: UUID,
        batch: BlobBatch,
        reusing previous: SnapshotManifest.Node?
    ) throws -> SnapshotManifest.Node {
        switch entry {
        case let .missing(missing):
            return SnapshotManifest.Node(kind: .missing, path: missing.path)
        case let .file(file):
            let hash = file.contentID ?? SHA256.hexDigest(of: file.data)
            if let previous, previous.kind == .file, previous.path == file.path,
               previous.contentHash == hash, previous.contentSize == UInt64(file.data.count) {
                var reused = previous
                reused.permissions = file.permissions
                return reused
            }
            let packed = try batch.store(file.data, hash: hash)
            return SnapshotManifest.Node(
                kind: .file,
                path: file.path,
                permissions: file.permissions,
                contentHash: hash,
                contentSize: UInt64(file.data.count),
                packed: packed
            )
        case let .symlink(symlink):
            if let previous, previous.kind == .symlink, previous.path == symlink.path,
               previous.symlinkTarget.map(PathName.init) == PathName(symlink.target) {
                var reused = previous
                reused.permissions = symlink.permissions
                return reused
            }
            return SnapshotManifest.Node(kind: .symlink, path: symlink.path,
                                         permissions: symlink.permissions, symlinkTarget: symlink.target)
        case let .directory(directory):
            let old = try previous.map { try children(of: $0, workspaceId: workspaceId) } ?? []
            let byPath = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
            let entries = try directory.children.map {
                try writeManifestNode($0, workspaceId: workspaceId, batch: batch, reusing: byPath[$0.path])
            }.sorted { PathName($0.path.name) < PathName($1.path.name) }
            if let previous, previous.kind == .directory, previous.treeHash != nil, old == entries {
                var reused = previous
                reused.permissions = directory.permissions
                return reused
            }
            return try persistDirectory(SnapshotManifest.Node(
                kind: .directory, path: directory.path, permissions: directory.permissions, children: entries
            ), workspaceId: workspaceId)
        }
    }

    private func snapshotEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID,
        cache: SnapshotBlobCache = SnapshotBlobCache()
    ) throws -> Snapshot.Entry {
        switch node.kind {
        case .missing:
            return .missing(Snapshot.Missing(path: node.path))
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            return .file(
                Snapshot.File(
                    path: node.path,
                    data: try materializedBlob(node, workspaceId: workspaceId, cache: cache),
                    permissions: node.permissions ?? POSIXPermissions(0o644),
                    contentID: hash
                )
            )
        case .symlink:
            return .symlink(
                Snapshot.Symlink(
                    path: node.path,
                    target: node.symlinkTarget ?? "",
                    permissions: node.permissions ?? POSIXPermissions(0o777)
                )
            )
        case .directory:
            return .directory(
                Snapshot.Directory(
                    path: node.path,
                    permissions: node.permissions ?? POSIXPermissions(0o755),
                    children: try children(of: node, workspaceId: workspaceId).map {
                        try snapshotEntry(from: $0, workspaceId: workspaceId, cache: cache)
                    }
                )
            )
        }
    }

    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation {
        try await ensureWorkspaceDirectories(for: mutation.workspaceID)
        let jsonl = mutationsJsonlURL(workspaceId: mutation.workspaceID)
        let lockURL = mutationsLockURL(workspaceId: mutation.workspaceID)
        return try await withExclusiveLock(at: lockURL) {
            var state = try mutationSequenceState(workspaceId: mutation.workspaceID)
            guard state.highWaterMark < Int.max else {
                throw WorkspaceError.storageCorrupted("mutation sequence exhausted")
            }
            var record = mutation
            state.highWaterMark += 1
            record.sequence = state.highWaterMark
            // Reserve before publishing. Failed appends and retractions cannot reuse an ID.
            try write(state, to: mutationSequenceURL(workspaceId: mutation.workspaceID), durability: .atomic)

            if fileManager.fileExists(atPath: jsonl.path) {
                try appendJSONLLine(encode: record, to: jsonl)
            } else {
                try writeAllMutationsAsJSONL([record], to: jsonl)
            }
            return record
        }
    }

    func removeMutation(sequence: Int, workspaceId: UUID) async throws {
        try await ensureWorkspaceDirectories(for: workspaceId)
        try await withExclusiveLock(at: mutationsLockURL(workspaceId: workspaceId)) {
            let url = mutationsJsonlURL(workspaceId: workspaceId)
            var state = try mutationSequenceState(workspaceId: workspaceId)
            let records = fileManager.fileExists(atPath: url.path) ? try loadMutationsFromJSONL(at: url) : []
            try state.bumpRetractionEpoch()
            // Publish invalidation before rewriting. A failed rewrite only causes a harmless reload.
            try write(state, to: mutationSequenceURL(workspaceId: workspaceId), durability: .atomic)
            try writeAllMutationsAsJSONL(records.filter { $0.sequence != sequence }, to: url)
        }
    }

    func listMutations(workspaceId: UUID, afterSequence: Int) async throws -> MutationPage {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            return MutationPage(records: [], retractionEpoch: 0)
        }
        return try await withExclusiveLock(at: mutationsLockURL(workspaceId: workspaceId)) {
            let jsonl = mutationsJsonlURL(workspaceId: workspaceId)
            let state = try readMutationSequenceState(workspaceId: workspaceId)
            let records = fileManager.fileExists(atPath: jsonl.path)
                ? try loadMutationsFromJSONL(at: jsonl, afterSequence: afterSequence).sorted { $0.sequence < $1.sequence }
                : []
            return MutationPage(records: records, retractionEpoch: state.retractionEpoch)
        }
    }

    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        let jsonl = mutationsJsonlURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: jsonl.path) else {
            return
        }
        let lockURL = mutationsLockURL(workspaceId: workspaceId)
        try await withExclusiveLock(at: lockURL) {
            var state = try mutationSequenceState(workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: jsonl.path) else { return }
            let records = try loadMutationsFromJSONL(at: jsonl)
                .sorted { $0.sequence < $1.sequence }
            guard let last = records.last else {
                return
            }
            var kept = records.filter { $0.sequence > throughSequence }
            if kept.isEmpty {
                kept = [last]
            }
            guard kept.count != records.count else {
                return
            }
            try state.bumpRetractionEpoch()
            try write(state, to: mutationSequenceURL(workspaceId: workspaceId), durability: .atomic)
            try writeAllMutationsAsJSONL(kept, to: jsonl)
        }
    }

    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            return .empty
        }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try physicalStatisticsUnlocked(workspaceId: workspaceId)
        }
    }

    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            let plan = try CheckpointRetentionPlanner.plan(checkpoints: [], retaining: retention)
            return StoreCompactionResult(
                report: Workspace.CompactionReport(
                    dryRun: dryRun,
                    before: .empty,
                    after: .empty,
                    removedCheckpointIDs: plan.removedCheckpointIDs,
                    rebasedCheckpointIDs: plan.rebasedCheckpointIDs
                ),
                checkpoints: []
            )
        }
        return try await withExclusiveLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try compactUnlocked(workspaceId: workspaceId, retaining: retention, dryRun: dryRun)
        }
    }

    private func compactUnlocked(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) throws -> StoreCompactionResult {
        let current = try loadAllCheckpointsUnlocked(workspaceId: workspaceId)
        let before = try physicalStatisticsUnlocked(workspaceId: workspaceId)
        let plan = try CheckpointRetentionPlanner.plan(checkpoints: current, retaining: retention)
        let rebasedIDs = Set(plan.rebasedCheckpointIDs)
        let retained = try CheckpointRetentionPlanner.materialize(plan) { snapshotID in
            try loadSnapshotUnlocked(id: snapshotID, workspaceId: workspaceId)
        }

        let retainedSnapshotIDs = Set(retained.map(\.snapshotId))
        var retainedBlobHashes: Set<String> = []
        var retainedTrees: Set<String> = []
        var retainedPacks: Set<String> = []
        var livePacked: [String: PackedBlob] = [:]
        for checkpoint in retained {
            let manifestURL = snapshotURL(id: checkpoint.snapshotId, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) has no snapshot")
            }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.id == checkpoint.snapshotId else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) references a mismatched snapshot")
            }
            try collectArtifacts(from: manifest.root, workspaceId: workspaceId, blobs: &retainedBlobHashes,
                                 trees: &retainedTrees, packs: &retainedPacks, livePacked: &livePacked)
        }

        var retainedBlobBytes: UInt64 = 0
        for hash in retainedBlobHashes {
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash)")
            }
            retainedBlobBytes += try fileSize(at: url)
        }
        retainedBlobBytes += livePacked.values.reduce(0) { $0 + $1.size }
        let after = Workspace.StorageStatistics(
            checkpointCount: retained.count,
            snapshotCount: retainedSnapshotIDs.count,
            blobCount: retainedBlobHashes.count + livePacked.count,
            blobBytes: retainedBlobBytes
        )
        let report = Workspace.CompactionReport(
            dryRun: dryRun,
            before: before,
            after: after,
            removedCheckpointIDs: plan.removedCheckpointIDs,
            rebasedCheckpointIDs: plan.rebasedCheckpointIDs
        )

        guard !dryRun else { return StoreCompactionResult(report: report, checkpoints: retained) }

        // Rewrite partial packs before changing any references. Then atomically replace
        // retained snapshot roots; a crash at any point leaves old and/or new packs live.
        let relocated = try repackLiveBlobs(livePacked, workspaceId: workspaceId)
        if !relocated.isEmpty {
            retainedTrees.removeAll()
            retainedPacks.removeAll()
            for id in retainedSnapshotIDs {
                guard var manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else {
                    throw WorkspaceError.storageCorrupted("missing retained snapshot")
                }
                let root = try relocating(manifest.root, blobs: relocated, workspaceId: workspaceId)
                if root != manifest.root {
                    manifest.root = root
                    manifest.version = 3
                    try write(manifest, to: snapshotURL(id: id, workspaceId: workspaceId), durability: .publication)
                }
                try collectArtifacts(from: manifest.root, workspaceId: workspaceId, blobs: &retainedBlobHashes,
                                     trees: &retainedTrees, packs: &retainedPacks, livePacked: &livePacked)
            }
        }
        for checkpoint in retained where rebasedIDs.contains(checkpoint.id) {
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: workspaceId), durability: .publication)
        }
        for id in plan.removedCheckpointIDs {
            try removeIfPresent(checkpointURL(id: id, workspaceId: workspaceId))
        }
        try Self.syncDirectory(checkpointsDirectoryURL(workspaceId: workspaceId))
        for url in try artifactURLs(in: snapshotsDirectoryURL(workspaceId: workspaceId), pathExtension: "json") {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  retainedSnapshotIDs.contains(id)
            else {
                try fileManager.removeItem(at: url)
                continue
            }
        }
        try Self.syncDirectory(snapshotsDirectoryURL(workspaceId: workspaceId))
        // Invalidate other writers' catalogs durably before deleting any old pack.
        if fileManager.fileExists(atPath: packsDirectoryURL(workspaceId: workspaceId).path) {
            try advancePackGeneration(workspaceId: workspaceId)
        }
        for (directory, retainedNames) in [
            (treesDirectoryURL(workspaceId: workspaceId), retainedTrees),
            (packsDirectoryURL(workspaceId: workspaceId), Set(retainedPacks.flatMap { [$0 + ".pack", $0 + ".json"] }))
        ] {
            if fileManager.fileExists(atPath: directory.path) {
                for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where !retainedNames.contains(url.lastPathComponent) {
                    try fileManager.removeItem(at: url)
                }
                try Self.syncDirectory(directory)
            }
        }
        treeCache.removeAll()
        packCatalog.removeAll()
        packCatalogKey = nil
        for url in try blobURLs(workspaceId: workspaceId)
        where !retainedBlobHashes.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        for directory in [
            workspaceDirectoryURL(workspaceId: workspaceId), checkpointsDirectoryURL(workspaceId: workspaceId),
            snapshotsDirectoryURL(workspaceId: workspaceId), blobsDirectoryURL(workspaceId: workspaceId)
        ] {
            for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".pending-") {
                try fileManager.removeItem(at: url)
            }
        }
        try Self.syncDirectory(blobsDirectoryURL(workspaceId: workspaceId))
        listCheckpointsCache[workspaceId] = nil
        return StoreCompactionResult(report: report, checkpoints: retained)
    }

    func loadAllCheckpointsUnlocked(workspaceId: UUID) throws -> [Checkpoint] {
        let directory = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try artifactURLs(in: directory, pathExtension: "json").map { url in
            let checkpoint = try read(Checkpoint.self, from: url)
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == checkpoint.id,
                  checkpoint.workspaceID == workspaceId
            else {
                throw WorkspaceError.storageCorrupted("checkpoint metadata does not match its storage path")
            }
            return checkpoint
        }.sorted(by: Checkpoint.orderedBefore)
    }

    private func loadSnapshotUnlocked(id: UUID, workspaceId: UUID) throws -> Snapshot? {
        guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else { return nil }
        return Snapshot(
            id: manifest.id,
            rootPath: manifest.rootPath,
            entry: try snapshotEntry(from: manifest.root, workspaceId: workspaceId)
        )
    }

    func resolvedParent(for draft: CheckpointDraft, checkpoints: [Checkpoint]) -> Checkpoint? {
        if let preferred = draft.preferredParentID,
           let parent = checkpoints.first(where: { $0.id == preferred }) {
            return parent
        }
        guard draft.preferredParentID != nil,
              let headID = Checkpoint.lineageHeadID(in: checkpoints)
        else { return nil }
        return checkpoints.first(where: { $0.id == headID })
    }

    private func physicalStatisticsUnlocked(workspaceId: UUID) throws -> Workspace.StorageStatistics {
        let checkpoints = try artifactURLs(
            in: checkpointsDirectoryURL(workspaceId: workspaceId),
            pathExtension: "json"
        )
        let snapshots = try artifactURLs(
            in: snapshotsDirectoryURL(workspaceId: workspaceId),
            pathExtension: "json"
        )
        let blobs = try blobURLs(workspaceId: workspaceId)
        var blobBytes: UInt64 = 0
        var packedCount = 0
        for blob in blobs { blobBytes += try fileSize(at: blob) }
        for url in try artifactURLs(in: packsDirectoryURL(workspaceId: workspaceId), pathExtension: "pack", includeHidden: true) {
            let usage = try packStatistics(url.deletingPathExtension().lastPathComponent, workspaceId: workspaceId)
            blobBytes += usage.bytes
            packedCount += usage.count
        }
        return Workspace.StorageStatistics(
            checkpointCount: checkpoints.count,
            snapshotCount: snapshots.count,
            blobCount: blobs.count + packedCount,
            blobBytes: blobBytes
        )
    }

    private func artifactURLs(in directory: URL, pathExtension: String, includeHidden: Bool = false) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        ).filter { $0.pathExtension == pathExtension }.map { url in
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw WorkspaceError.storageCorrupted("unexpected artifact: \(url.lastPathComponent)")
            }
            return url
        }.sorted { PathName($0.lastPathComponent) < PathName($1.lastPathComponent) }
    }

    private func blobURLs(workspaceId: UUID) throws -> [URL] {
        let directory = blobsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).map { url in
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw WorkspaceError.storageCorrupted("unexpected entry in blob store: \(url.lastPathComponent)")
            }
            return url
        }.sorted { PathName($0.lastPathComponent) < PathName($1.lastPathComponent) }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let value = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.uint64Value ?? 0
    }

    private func packStatistics(_ pack: String, workspaceId: UUID) throws -> (count: Int, bytes: UInt64) {
        let directory = packsDirectoryURL(workspaceId: workspaceId)
        let index = try? read([String: PackedBlob].self, from: directory.appendingPathComponent(pack + ".json"))
        return (index?.count ?? 1, try fileSize(at: directory.appendingPathComponent(pack + ".pack")))
    }

    private func collectArtifacts(from node: SnapshotManifest.Node, workspaceId: UUID,
                                  blobs: inout Set<String>, trees: inout Set<String>, packs: inout Set<String>,
                                  livePacked: inout [String: PackedBlob]) throws {
        switch node.kind {
        case .file:
            let location = try blobLocation(node, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: location.url.path),
                  try fileSize(at: location.url) >= location.offset + location.size else {
                throw WorkspaceError.storageCorrupted("missing or truncated blob for \(node.path)")
            }
            if let packed = node.packed, let hash = node.contentHash {
                packs.insert(packed.pack)
                livePacked[hash] = packed
            } else if let hash = node.contentHash {
                blobs.insert(hash)
            }
        case .directory:
            if let hash = node.treeHash, !trees.insert(hash).inserted { return }
            for child in try children(of: node, workspaceId: workspaceId) {
                try collectArtifacts(from: child, workspaceId: workspaceId, blobs: &blobs, trees: &trees, packs: &packs, livePacked: &livePacked)
            }
        case .missing, .symlink: break
        }
    }

    private func repackLiveBlobs(_ live: [String: PackedBlob], workspaceId: UUID) throws -> [String: PackedBlob] {
        let groups = Dictionary(grouping: live.keys, by: { live[$0]!.pack })
        // A previous compaction may have stopped halfway through root replacement.
        // Canonicalize every live hash, even when its chosen pack needs no rewriting.
        var relocated = live
        let directory = packsDirectoryURL(workspaceId: workspaceId)
        for (pack, hashes) in groups {
            let oldIndex = try? read([String: PackedBlob].self, from: directory.appendingPathComponent(pack + ".json"))
            if let oldIndex, oldIndex.count == hashes.count,
               hashes.allSatisfy({ oldIndex[$0] == live[$0] }),
               try fileSize(at: directory.appendingPathComponent(pack + ".pack")) == hashes.reduce(UInt64(0), { $0 + live[$1]!.size }) {
                continue
            }
            let id = UUID().uuidString
            var bytes = Data()
            var index: [String: PackedBlob] = [:]
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(pack + ".pack"))
            defer { try? handle.close() }
            for hash in hashes.sorted() {
                let old = live[hash]!
                guard old.size <= UInt64(Int.max) else { throw WorkspaceError.storageCorrupted("oversized packed blob") }
                try handle.seek(toOffset: old.offset)
                let content = try handle.read(upToCount: Int(old.size)) ?? Data()
                guard content.count == Int(old.size), SHA256.hexDigest(of: content) == hash else {
                    throw WorkspaceError.storageCorrupted("invalid packed content during compaction")
                }
                let replacement = PackedBlob(pack: id, offset: UInt64(bytes.count), size: old.size)
                index[hash] = replacement
                relocated[hash] = replacement
                bytes.append(content)
            }
            try Self.durableWrite(bytes, to: directory.appendingPathComponent(id + ".pack"))
            try Self.durableWrite(compactEncoder.encode(index), to: directory.appendingPathComponent(id + ".json"))
        }
        return relocated
    }

    private func relocating(_ node: SnapshotManifest.Node, blobs: [String: PackedBlob], workspaceId: UUID) throws -> SnapshotManifest.Node {
        var result = node
        if node.kind == .file, let hash = node.contentHash, node.packed != nil, let replacement = blobs[hash] {
            result.packed = replacement
        } else if node.kind == .directory {
            let old = try children(of: node, workspaceId: workspaceId)
            let new = try old.map { try relocating($0, blobs: blobs, workspaceId: workspaceId) }
            if old != new {
                result.children = new
                result = try persistDirectory(result, workspaceId: workspaceId, syncParent: true)
            }
        }
        return result
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func loadMutationsFromJSONL(at url: URL, afterSequence: Int = 0) throws -> [Mutation] {
        if afterSequence > 0 {
            return try loadMutationSuffix(at: url, afterSequence: afterSequence)
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        var out: [Mutation] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            do {
                out.append(try decoder.decode(Mutation.self, from: Data(line)))
            } catch {
                // A crashed append leaves a strict prefix of `<json>\n`: an undecodable final
                // line with no trailing newline. Tolerate exactly that torn tail; anything else
                // is real corruption and must surface.
                if index == lines.count - 1, !endsWithNewline, Self.isIncompleteMutationRecord(Data(line)) {
                    continue
                }
                throw error
            }
        }
        return out
    }

    /// A closed object with invalid UTF-8 or an invalid Mutation schema is corruption, even
    /// without its final LF. Track string escapes so a brace inside a truncated string does
    /// not look like the end of the record.
    private static func isIncompleteMutationRecord(_ data: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard data.first(where: { !whitespace.contains($0) }) == UInt8(ascii: "{") else { return false }
        var delimiters: [UInt8] = []
        var inString = false
        var escaped = false
        var closed = false
        for byte in data {
            if closed {
                if whitespace.contains(byte) { continue }
                return false
            }
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                delimiters.append(byte)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                let opening = byte == UInt8(ascii: "}") ? UInt8(ascii: "{") : UInt8(ascii: "[")
                guard delimiters.popLast() == opening else { return false }
                closed = delimiters.isEmpty
            default:
                break
            }
        }
        return !delimiters.isEmpty
    }

    /// Scan back only as far as the requested sequence. Appends and pruning preserve sequence
    /// order, so repeated history queries decode new records rather than the entire log.
    private func loadMutationSuffix(at url: URL, afterSequence: Int) throws -> [Mutation] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var cursor = try handle.seekToEnd()
        guard cursor > 0 else { return [] }
        try handle.seek(toOffset: cursor - 1)
        let endsWithNewline = try handle.read(upToCount: 1) == Data([UInt8(ascii: "\n")])
        var pending = Data()
        var isFinalRecord = true
        var records: [Mutation] = []

        func consume(_ line: Data) throws -> Bool {
            defer { isFinalRecord = false }
            guard !line.isEmpty else { return true }
            let record: Mutation
            do {
                record = try decoder.decode(Mutation.self, from: line)
            } catch {
                if isFinalRecord, !endsWithNewline, Self.isIncompleteMutationRecord(line) { return true }
                throw error
            }
            guard record.sequence > afterSequence else { return false }
            records.append(record)
            return true
        }

        while cursor > 0 {
            let start = cursor > 65536 ? cursor - 65536 : 0
            try handle.seek(toOffset: start)
            var chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            chunk.append(pending)
            let lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            for line in lines.dropFirst().reversed() {
                if try !consume(Data(line)) { return records.reversed() }
            }
            pending = Data(lines.first ?? Data.SubSequence())
            cursor = start
        }
        _ = try consume(pending)
        return records.reversed()
    }

    /// Call while holding the lifecycle lock. The cursor is authoritative even when the
    /// Workspace that requested the checkpoint has not refreshed its mutation cache.
    func persistedMutationCursor(workspaceId: UUID) async throws -> Int {
        try await withExclusiveLock(at: mutationsLockURL(workspaceId: workspaceId)) {
            try mutationSequenceState(workspaceId: workspaceId).highWaterMark
        }
    }

    /// Truncates a partial trailing line left behind by a crashed append so subsequent appends
    /// do not glue new records onto the torn fragment. A torn append never contains a newline
    /// (it is a strict prefix of `<json>\n`), so everything after the final newline — or the
    /// whole file when none exists — is the final record. A complete record missing only its LF
    /// is preserved by adding that LF. Must be called under the mutations lock.
    private func repairTornTail(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        let lastByte = try handle.read(upToCount: 1)
        guard lastByte != Data("\n".utf8) else { return }
        let newlineOffset = try Self.lastNewlineOffset(in: handle, before: size - 1)
        let start = newlineOffset.map { $0 + 1 } ?? 0
        try handle.seek(toOffset: start)
        let tail = try handle.read(upToCount: Int(size - start)) ?? Data()
        do {
            _ = try decoder.decode(Mutation.self, from: tail)
        } catch {
            guard Self.isIncompleteMutationRecord(tail) else { throw error }
            try handle.truncate(atOffset: start)
            return
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
    }

    /// Returns the sequence of the final record without loading the whole log. Appends are
    /// strictly monotonic and full rewrites are sorted by sequence, so the last line always
    /// carries the maximum. Falls back to a full scan for unusual tails such as blank trailing
    /// lines. Must be called under the mutations lock, after ``repairTornTail(at:)``.
    private func lastPersistedSequence(at url: URL) throws -> Int {
        if let line = try lastLine(at: url),
           let record = try? decoder.decode(Mutation.self, from: line) {
            return record.sequence
        }
        return try loadMutationsFromJSONL(at: url).map(\.sequence).max() ?? 0
    }

    private func lastLine(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
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

    private func writeAllMutationsAsJSONL(_ records: [Mutation], to url: URL) throws {
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

    private func appendJSONLLine(encode record: Mutation, to url: URL) throws {
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

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func ensureWorkspaceDirectories(for workspaceId: UUID) async throws {
        try ensureDirectory(rootDirectory)
        try await withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            let version = try ensureWorkspaceDirectoriesLocked(for: workspaceId)
            if version == 1 {
                try await withExclusiveLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
                    try await withExclusiveLock(at: mutationsLockURL(workspaceId: workspaceId)) {
                        try upgradeFormatUnlocked(workspaceId: workspaceId)
                    }
                }
            }
        }
    }

    private func ensureWorkspaceDirectoriesLocked(for workspaceId: UUID) throws -> Int {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let existed = fileManager.fileExists(atPath: workspaceURL.path)
        try ensureDirectory(workspaceURL)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        let version: Int
        if fileManager.fileExists(atPath: formatURL.path) {
            version = try validateWorkspaceFormatLocked(workspaceId)
        } else {
            if existed,
               !(try fileManager.contentsOfDirectory(at: workspaceURL, includingPropertiesForKeys: nil)).isEmpty
            {
                throw WorkspaceError.storageCorrupted("workspace store has no format version")
            }
            try Self.durableWrite(encoder.encode(StoreFormat(version: StoreFormat.currentVersion)), to: formatURL)
            version = StoreFormat.currentVersion
        }
        let newObjects = !fileManager.fileExists(atPath: treesDirectoryURL(workspaceId: workspaceId).path)
        try ensureDirectory(checkpointsDirectoryURL(workspaceId: workspaceId))
        try ensureDirectory(snapshotsDirectoryURL(workspaceId: workspaceId))
        try ensureDirectory(blobsDirectoryURL(workspaceId: workspaceId))
        try ensureDirectory(treesDirectoryURL(workspaceId: workspaceId))
        try ensureDirectory(packsDirectoryURL(workspaceId: workspaceId))
        if !existed || newObjects {
            try Self.syncDirectory(workspaceURL)
            try Self.syncDirectory(rootDirectory)
            try Self.syncDirectory(rootDirectory.deletingLastPathComponent())
        }
        return version
    }

    func validateWorkspaceFormatIfPresent(_ workspaceId: UUID) async throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: workspaceURL.path) else { return }
        try await withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            _ = try validateWorkspaceFormatLocked(workspaceId)
        }
    }

    private func validateWorkspaceFormatLocked(_ workspaceId: UUID) throws -> Int {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        guard fileManager.fileExists(atPath: formatURL.path) else {
            throw WorkspaceError.storageCorrupted("workspace store has no format version")
        }
        let format = try decoder.decode(StoreFormat.self, from: Data(contentsOf: formatURL))
        guard (1...StoreFormat.currentVersion).contains(format.version) else {
            throw WorkspaceError.storageCorrupted("unsupported store format version \(format.version)")
        }
        return format.version
    }

    func workspaceDirectoryURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    private func checkpointsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("checkpoints", isDirectory: true)
    }

    private func snapshotsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("snapshots", isDirectory: true)
    }

    func checkpointURL(id: UUID, workspaceId: UUID) -> URL {
        checkpointsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    func snapshotURL(id: UUID, workspaceId: UUID) -> URL {
        snapshotsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func blobsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("blobs", isDirectory: true)
    }

    private func blobURL(hash: String, workspaceId: UUID) -> URL {
        blobsDirectoryURL(workspaceId: workspaceId).appendingPathComponent(hash, isDirectory: false)
    }

    private func mutationSequenceURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.sequence.json")
    }

    private struct MutationSequenceState: Codable {
        var highWaterMark: Int = 0
        var retractionEpoch: Int = 0

        mutating func bumpRetractionEpoch() throws {
            guard retractionEpoch < Int.max else {
                throw WorkspaceError.storageCorrupted("mutation retraction epoch exhausted")
            }
            retractionEpoch += 1
        }
    }

    /// Reads legacy bare-Int sidecars as epoch zero. Must hold the mutations lock.
    private func readMutationSequenceState(workspaceId: UUID) throws -> MutationSequenceState {
        let url = mutationSequenceURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return MutationSequenceState() }
        let data = try Data(contentsOf: url)
        let state: MutationSequenceState
        if let legacy = try? decoder.decode(Int.self, from: data) {
            state = MutationSequenceState(highWaterMark: legacy)
        } else {
            state = try decoder.decode(MutationSequenceState.self, from: data)
        }
        guard state.highWaterMark >= 0, state.retractionEpoch >= 0 else {
            throw WorkspaceError.storageCorrupted("negative mutation sequence or retraction epoch")
        }
        return state
    }

    /// One authoritative cursor for reservation, retraction, pruning, and checkpoint capture.
    /// Must hold the mutations lock; repair the tail before comparing the log with the sidecar.
    private func mutationSequenceState(workspaceId: UUID) throws -> MutationSequenceState {
        var state = try readMutationSequenceState(workspaceId: workspaceId)
        let log = mutationsJsonlURL(workspaceId: workspaceId)
        if fileManager.fileExists(atPath: log.path) {
            try repairTornTail(at: log)
            state.highWaterMark = max(state.highWaterMark, try lastPersistedSequence(at: log))
        }
        return state
    }

    private func mutationsJsonlURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.jsonl", isDirectory: false)
    }

    /// A persistent sidecar lockfile used to serialize mutation-log access.
    ///
    /// The mutations log is append-only; we still take the lock on a **stable** sidecar so the lock
    /// is not taken on a file that is unlinked/renamed by atomic write helpers in other
    /// subsystems. Mutations are written to `mutations.jsonl`.
    private func mutationsLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.lock", isDirectory: false)
    }

    /// Serializes checkpoint, manifest, and blob lifecycle operations across store instances.
    func lifecycleLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("lifecycle.lock", isDirectory: false)
    }

    private func formatLockURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(".\(workspaceId.uuidString).format.lock", isDirectory: false)
    }

    enum WriteDurability { case atomic, publication }

    func write<T: Encodable>(
        _ value: T, to url: URL, durability: WriteDurability
    ) throws {
        let data = try encoder.encode(value)
        switch durability {
        case .publication: try Self.durableWrite(data, to: url, publication: true)
        case .atomic: try data.write(to: url, options: .atomic)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private struct LockFileError: Error {
        var message: String
    }

    private struct StoreFormat: Codable {
        // Existing v1 manifests and sequence sidecars remain readable. The v2 writer
        // fence is published before new directory objects or packs (see README).
        static let currentVersion = 2
        var version: Int
    }

    // One combined estimated-decoded budget per store, split between nodes and write catalog.
    static let defaultCacheByteLimit = 32 * 1024 * 1024
    private var treeCache: CostLRU<String, [TreeEntry]>
    private var packCatalog: CostLRU<String, PackedBlob>
    private var packCatalogWorkspace: UUID?
    private var packCatalogKey: String?

    struct PackedBlob: Codable, Sendable, Equatable {
        var pack: String
        var offset: UInt64
        var size: UInt64

        var estimatedCatalogBytes: Int { 256 + 2 * (64 + pack.utf8.count) }
    }

    /// One writer, owned by one lifecycle-locked operation. Packs are capped at 16 MiB
    /// (except a single large blob), with a 1 MiB write buffer. The first 32 unique
    /// blobs stay loose so tiny checkpoints don't require pack/index overhead.
    final class BlobBatch {
        let loose: URL
        let packs: URL
        var known: CostLRU<String, PackedBlob>
        let fileManager: FileManager
        let encoder: JSONEncoder
        var seenLoose: Set<String> = []
        var verifiedSizes: [URL: UInt64] = [:]
        var verifiedPackSizes: [String: UInt64] = [:]
        var insertedLines: [WorkspacePath: Int] = [:]
        var summarizeInsertions = false
        var wrotePacks = false
        var count = 0
        var packID = UUID().uuidString
        var handle: FileHandle?
        var offset: UInt64 = 0
        var buffer = Data()
        var index: [String: PackedBlob] = [:]

        init(loose: URL, packs: URL, known: CostLRU<String, PackedBlob>, fileManager: FileManager, encoder: JSONEncoder) {
            self.loose = loose
            self.packs = packs
            self.known = known
            self.fileManager = fileManager
            self.encoder = encoder
        }

        func store(_ data: Data, hash: String) throws -> PackedBlob? {
            if let location = known.value(for: hash) { return location }
            if seenLoose.contains(hash) { return nil }
            let url = loose.appendingPathComponent(hash)
            if fileManager.fileExists(atPath: url.path) {
                seenLoose.insert(hash)
                return nil
            }
            count += 1
            if count <= 32 {
                try FileCheckpointStore.durableWrite(data, to: url)
                seenLoose.insert(hash)
                return nil
            }
            if offset > 0, offset + UInt64(data.count) > 16 * 1024 * 1024 { try finishPack() }
            if handle == nil {
                let url = packs.appendingPathComponent(packID + ".pack")
                guard fileManager.createFile(atPath: url.path, contents: nil) else {
                    throw WorkspaceError.storageCorrupted("cannot create blob pack")
                }
                handle = try FileHandle(forWritingTo: url)
            }
            let location = PackedBlob(pack: packID, offset: offset, size: UInt64(data.count))
            if data.count >= 1024 * 1024 {
                // Do not duplicate a large captured file in the pack buffer.
                try flush()
                try handle?.write(contentsOf: data)
            } else {
                buffer.append(data)
                if buffer.count >= 1024 * 1024 { try flush() }
            }
            offset += UInt64(data.count)
            index[hash] = location
            known.insert(location, for: hash, cost: location.estimatedCatalogBytes)
            return location
        }

        func flush() throws {
            if !buffer.isEmpty {
                try handle?.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        func finishPack() throws {
            guard let handle else { return }
            try flush()
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            try FileCheckpointStore.syncDirectory(packs)
            try FileCheckpointStore.durableWrite(encoder.encode(index), to: packs.appendingPathComponent(packID + ".json"))
            wrotePacks = true
            packID = UUID().uuidString
            offset = 0
            index.removeAll(keepingCapacity: true)
        }

        func close() { try? handle?.close(); handle = nil }
        deinit { close() }
    }

    private func treesDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("trees", isDirectory: true)
    }

    private func packsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("packs", isDirectory: true)
    }

    /// Constant-size invalidation avoids enumerating historical packs on every
    /// checkpoint. A durable random generation also avoids directory-mtime ABA.
    private func packGeneration(workspaceId: UUID) throws -> String? {
        let url = workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("packs.generation")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let value = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard UUID(uuidString: value) != nil else { throw WorkspaceError.storageCorrupted("invalid pack catalog generation") }
        return value
    }

    private func advancePackGeneration(workspaceId: UUID) throws {
        let url = workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("packs.generation")
        try Self.durableWrite(Data(UUID().uuidString.utf8), to: url)
    }

    func makeBlobBatch(workspaceId: UUID) throws -> BlobBatch {
        let packs = packsDirectoryURL(workspaceId: workspaceId)
        let key = try packGeneration(workspaceId: workspaceId)
        var known = packCatalog
        if packCatalogWorkspace != workspaceId || packCatalogKey != key {
            known.removeAll()
            for url in try artifactURLs(in: packs, pathExtension: "json") {
                let entries = try read([String: PackedBlob].self, from: url)
                for (hash, location) in entries {
                    guard Self.isValidContentHash(hash), UUID(uuidString: location.pack) != nil,
                          location.pack == url.deletingPathExtension().lastPathComponent,
                          fileManager.fileExists(atPath: packs.appendingPathComponent(location.pack + ".pack").path)
                    else { continue } // Interrupted, unreferenced packs are swept by compaction.
                    known.insert(location, for: hash, cost: location.estimatedCatalogBytes)
                }
            }
            packCatalog = known
            packCatalogWorkspace = workspaceId
            packCatalogKey = key
        }
        let loose = blobsDirectoryURL(workspaceId: workspaceId)
        return BlobBatch(loose: loose, packs: packs, known: known, fileManager: fileManager, encoder: compactEncoder)
    }

    func finish(_ batch: BlobBatch, workspaceId: UUID) throws {
        try batch.finishPack()
        if batch.wrotePacks { try advancePackGeneration(workspaceId: workspaceId) }
        packCatalog = batch.known
        packCatalogWorkspace = workspaceId
        packCatalogKey = try packGeneration(workspaceId: workspaceId)
        try Self.syncDirectory(treesDirectoryURL(workspaceId: workspaceId))
    }

    private func cacheTree(_ entries: [TreeEntry], hash: String, workspaceId: UUID, capturing: Bool = false) {
        let key = workspaceId.uuidString + hash
        let cost = 256 + key.utf8.count * 2 + entries.reduce(0) { $0 + $1.estimatedBytes }
        treeCache.insert(entries, for: key, cost: cost, evicting: capturing ? .mostRecent : .leastRecent)
    }

    func children(of node: SnapshotManifest.Node, workspaceId: UUID, capturing: Bool = false) throws -> [SnapshotManifest.Node] {
        guard node.kind == .directory else { return [] }
        guard let hash = node.treeHash else { return (node.children ?? []).sorted { PathName($0.path.name) < PathName($1.path.name) } }
        return try treeEntries(hash: hash, workspaceId: workspaceId, capturing: capturing).map { $0.node(in: node.path) }
    }

    private func treeEntries(hash: String, workspaceId: UUID, capturing: Bool = false) throws -> [TreeEntry] {
        guard Self.isValidContentHash(hash) else { throw WorkspaceError.storageCorrupted("invalid tree hash") }
        let url = treesDirectoryURL(workspaceId: workspaceId).appendingPathComponent(hash)
        guard fileManager.fileExists(atPath: url.path) else { throw WorkspaceError.storageCorrupted("missing tree \(hash)") }
        let entries: [TreeEntry]
        if let cached = treeCache.value(for: workspaceId.uuidString + hash) {
            entries = cached
        } else {
            let bytes = try Data(contentsOf: url)
            guard SHA256.hexDigest(of: bytes) == hash else { throw WorkspaceError.storageCorrupted("tree hash mismatch") }
            entries = try decoder.decode([TreeEntry].self, from: bytes)
            var previous: PathName?
            for entry in entries {
                try TreeEntry.validate(entry.name)
                guard previous.map({ $0 < PathName(entry.name) }) ?? true else {
                    throw WorkspaceError.storageCorrupted("unsorted or duplicate tree child")
                }
                previous = PathName(entry.name)
            }
            cacheTree(entries, hash: hash, workspaceId: workspaceId, capturing: capturing)
        }
        return entries
    }

    func persistDirectory(
        _ node: SnapshotManifest.Node, workspaceId: UUID, syncParent: Bool = false
    ) throws -> SnapshotManifest.Node {
        let entries = try (node.children ?? []).sorted {
            PathName($0.path.name) < PathName($1.path.name)
        }.map { try TreeEntry($0) }
        return try persistDirectory(node, entries: entries, workspaceId: workspaceId, syncParent: syncParent)
    }

    private func persistDirectory(
        _ node: SnapshotManifest.Node, entries: [TreeEntry], workspaceId: UUID,
        syncParent: Bool = false, capturing: Bool = false
    ) throws -> SnapshotManifest.Node {
        let bytes = try compactEncoder.encode(entries)
        let hash = SHA256.hexDigest(of: bytes)
        let url = treesDirectoryURL(workspaceId: workspaceId).appendingPathComponent(hash)
        if !fileManager.fileExists(atPath: url.path) {
            try Self.durableWrite(bytes, to: url, syncParent: syncParent)
        }
        cacheTree(entries, hash: hash, workspaceId: workspaceId, capturing: capturing)
        var reference = node
        reference.children = nil
        reference.treeHash = hash
        return reference
    }

    private func blobLocation(_ node: SnapshotManifest.Node, workspaceId: UUID) throws -> (url: URL, offset: UInt64, size: UInt64) {
        guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
            throw WorkspaceError.storageCorrupted("invalid blob hash for \(node.path)")
        }
        if let packed = node.packed {
            guard UUID(uuidString: packed.pack) != nil, packed.size == node.contentSize,
                  packed.offset <= UInt64.max - packed.size else {
                throw WorkspaceError.storageCorrupted("invalid packed blob range")
            }
            return (packsDirectoryURL(workspaceId: workspaceId).appendingPathComponent(packed.pack + ".pack"), packed.offset, packed.size)
        }
        let url = blobURL(hash: hash, workspaceId: workspaceId)
        return (url, 0, try node.contentSize ?? fileSize(at: url))
    }

    private func blobExists(_ node: SnapshotManifest.Node, workspaceId: UUID, batch: BlobBatch) -> Bool {
        if let packed = node.packed, let size = batch.verifiedPackSizes[packed.pack] {
            return packed.offset <= size && packed.size <= size - packed.offset
        }
        guard let location = try? blobLocation(node, workspaceId: workspaceId) else { return false }
        if let size = batch.verifiedSizes[location.url] { return location.offset <= size && location.size <= size - location.offset }
        guard let size = try? fileSize(at: location.url) else { return false }
        batch.verifiedSizes[location.url] = size
        if let packed = node.packed { batch.verifiedPackSizes[packed.pack] = size }
        return location.offset <= size && location.size <= size - location.offset
    }

    /// Materialization walks most files in a pack together. Map at most four packs
    /// per load, then copy only each selected range into its Snapshot.File. No mapped
    /// pack escapes the lifecycle-locked load or pins deleted packs after compaction.
    private final class SnapshotBlobCache {
        var packs: [String: Data] = [:]
        var order: [String] = []
    }

    private func materializedBlob(_ node: SnapshotManifest.Node, workspaceId: UUID, cache: SnapshotBlobCache) throws -> Data {
        let bytes: Data
        let offset: UInt64
        let size: UInt64
        if let packed = node.packed {
            guard packed.size == node.contentSize else { throw WorkspaceError.storageCorrupted("invalid packed blob size") }
            if let cached = cache.packs[packed.pack] {
                bytes = cached
            } else {
                let location = try blobLocation(node, workspaceId: workspaceId)
                do { bytes = try Data(contentsOf: location.url, options: .mappedIfSafe) }
                catch {
                    if Snapshot.isMissingEntry(error) { throw WorkspaceError.storageCorrupted("missing content blob for \(node.path)") }
                    throw error
                }
                if cache.order.count == 4 { cache.packs.removeValue(forKey: cache.order.removeFirst()) }
                cache.packs[packed.pack] = bytes
                cache.order.append(packed.pack)
            }
            offset = packed.offset
            size = packed.size
        } else {
            let location = try blobLocation(node, workspaceId: workspaceId)
            do { bytes = try Data(contentsOf: location.url) }
            catch {
                if Snapshot.isMissingEntry(error) { throw WorkspaceError.storageCorrupted("missing content blob for \(node.path)") }
                throw error
            }
            offset = 0
            size = location.size
            if size == UInt64(bytes.count) { return bytes }
        }
        guard offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset else {
            throw WorkspaceError.storageCorrupted("truncated content blob for \(node.path)")
        }
        return bytes.subdata(in: Int(offset)..<Int(offset + size))
    }

    private func readBlob(_ node: SnapshotManifest.Node, workspaceId: UUID, offset: UInt64 = 0, length: Int? = nil) throws -> Data {
        let location = try blobLocation(node, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: location.url.path) else {
            throw WorkspaceError.storageCorrupted("missing content blob for \(node.path)")
        }
        let handle = try FileHandle(forReadingFrom: location.url)
        defer { try? handle.close() }
        let physicalSize = try handle.seekToEnd()
        guard location.offset <= physicalSize, location.size <= physicalSize - location.offset else {
            throw WorkspaceError.storageCorrupted("truncated content blob for \(node.path)")
        }
        guard offset < location.size else { return Data() }
        try handle.seek(toOffset: location.offset + offset)
        let count = min(UInt64(length ?? Int.max), location.size - offset)
        let bytes = try handle.read(upToCount: Int(count)) ?? Data()
        guard bytes.count == Int(count) else { throw WorkspaceError.storageCorrupted("short blob read") }
        return bytes
    }

    func resolveSnapshotFile(id: UUID, workspaceId: UUID, path: WorkspacePath) async throws -> (path: WorkspacePath, size: UInt64) {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else {
                throw WorkspaceError.revisionDataNotFound(id)
            }
            return try RevisionIndex.resolveReadableFile(at: path) { current in
                guard let node = try manifestNode(at: current, in: manifest.root, workspaceId: workspaceId) else { return nil }
                if node.kind == .file {
                    return .file(path: current, size: try blobLocation(node, workspaceId: workspaceId).size,
                                 permissions: node.permissions ?? .defaultFile, contentID: node.contentHash ?? "")
                }
                return try revisionEntry(from: node, workspaceId: workspaceId, depth: 0)
            }
        }
    }

    /// Shallow metadata: a list decodes its directory, never grandchildren.
    func snapshotEntry(id: UUID, workspaceId: UUID, path: WorkspacePath, includeChildren: Bool) async throws -> RevisionIndex.Entry? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else {
                throw WorkspaceError.revisionDataNotFound(id)
            }
            guard let node = try manifestNode(at: path, in: manifest.root, workspaceId: workspaceId) else { return nil }
            return try revisionEntry(from: node, workspaceId: workspaceId, depth: includeChildren ? 1 : 0)
        }
    }

    private func creationSummary(_ root: SnapshotManifest.Node, workspaceId: UUID, insertedLines: [WorkspacePath: Int], capturing: Bool = false) throws -> ChangeSet.Summary {
        var paths: [WorkspacePath] = []
        var files = 0
        func visit(_ node: SnapshotManifest.Node) throws {
            if node.kind == .missing { return }
            paths.append(node.path)
            if node.kind == .file { files += 1 }
            for child in try children(of: node, workspaceId: workspaceId, capturing: capturing) { try visit(child) }
        }
        try visit(root)
        let additions = insertedLines.values.reduce(0, +)
        return .init(changedPathCount: paths.count, touchedPaths: paths, hasTextChanges: additions > 0,
                     statistics: .init(changedPathCount: paths.count, changedFileCount: files, additions: additions, deletions: 0))
    }

    func compareNodes(_ old: SnapshotManifest.Node, _ new: SnapshotManifest.Node, workspaceId: UUID, capturing: Bool = false) async throws -> ChangeSet {
        if old == new { return ChangeSet(changes: []) }
        if old.kind == .directory, new.kind == .directory {
            var changes: [FileChange] = (old.permissions ?? .defaultDirectory) == (new.permissions ?? .defaultDirectory) ? [] : [.init(path: new.path, kind: .directory, effect: .modified)]
            var omissions: [TextDiffOmission] = []
            if old.treeHash != nil, old.treeHash == new.treeHash { return ChangeSet(changes: changes) }
            let before = Dictionary(uniqueKeysWithValues: try children(of: old, workspaceId: workspaceId, capturing: capturing).map { (PathName($0.path.name), $0) })
            let after = Dictionary(uniqueKeysWithValues: try children(of: new, workspaceId: workspaceId, capturing: capturing).map { (PathName($0.path.name), $0) })
            for key in Set(before.keys).union(after.keys).sorted() {
                let name = key.string
                let result = try await compareNodes(
                    before[key] ?? .init(kind: .missing, path: old.path.appending(name)),
                    after[key] ?? .init(kind: .missing, path: new.path.appending(name)), workspaceId: workspaceId, capturing: capturing)
                changes += result.changes
                omissions += result.textDiffOmissions
            }
            return ChangeSet(changes: changes, textDiffOmissions: omissions)
        }
        // Newly created/deleted trees need their complete summaries; normal incremental
        // changes reach this path only for changed leaves.
        let before = RevisionIndex(id: UUID(), root: old.path, entry: try revisionEntry(from: old, workspaceId: workspaceId, capturing: capturing))
        let after = RevisionIndex(id: UUID(), root: new.path, entry: try revisionEntry(from: new, workspaceId: workspaceId, capturing: capturing))
        return try await ChangeSet.compare(before: before, after: after, maxTextBytes: 1_000_000,
            loadBefore: { path in try await self.readNodeFile(path, root: old, workspaceId: workspaceId) },
            loadAfter: { path in try await self.readNodeFile(path, root: new, workspaceId: workspaceId) })
    }

    private func readNodeFile(_ path: WorkspacePath, root: SnapshotManifest.Node, workspaceId: UUID) throws -> Data {
        guard let node = try manifestNode(at: path, in: root, workspaceId: workspaceId) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return try readBlob(node, workspaceId: workspaceId)
    }

    func requireCurrentFormatUnlocked(workspaceId: UUID) throws {
        let url = workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("format.json")
        guard try read(StoreFormat.self, from: url).version == StoreFormat.currentVersion else {
            throw WorkspaceError.storageCorrupted("store format changed after preparation")
        }
    }

    /// v1 manifests remain readable. Publish the writer fence before any v2 objects.
    /// Migration runs under format -> lifecycle -> mutation locks, in that order.
    private func upgradeFormatUnlocked(workspaceId: UUID) throws {
        let url = workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("format.json")
        let format = try read(StoreFormat.self, from: url)
        guard (1...StoreFormat.currentVersion).contains(format.version) else {
            throw WorkspaceError.storageCorrupted("unsupported store format version \(format.version)")
        }
        if format.version < StoreFormat.currentVersion {
            try Self.durableWrite(encoder.encode(StoreFormat(version: StoreFormat.currentVersion)), to: url)
        }
    }

    private nonisolated static func durableWrite(
        _ data: Data, to url: URL, syncParent: Bool = true, publication: Bool = false
    ) throws {
#if canImport(Darwin) || canImport(Glibc)
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString + "-" + url.lastPathComponent)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
#if canImport(Darwin)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
#else
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
#endif
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if syncParent { try syncDirectory(directory) }
#if canImport(Darwin)
        if publication {
            // Flush the drive cache after both file and directory metadata are synced.
            while fcntl(fd, F_FULLFSYNC) != 0 {
                if errno == EINTR { continue }
                // Some network/FUSE volumes do not support this request. Keep
                // the file and directory fsync guarantees already established.
                break
            }
        }
#endif
#else
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
#endif
    }

    private nonisolated static func syncDirectory(_ url: URL) throws {
#if canImport(Darwin) || canImport(Glibc)
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
#endif
    }

    private func acquireGate(for path: String) async {
        let path = PathName(path)
        if heldLocks.insert(path).inserted { return }
        await withCheckedContinuation { lockWaiters[path, default: []].append($0) }
    }

    private func releaseGate(for path: String) {
        let path = PathName(path)
        guard var waiters = lockWaiters[path], !waiters.isEmpty else {
            heldLocks.remove(path)
            return
        }
        let next = waiters.removeFirst()
        lockWaiters[path] = waiters.isEmpty ? nil : waiters
        next.resume()
    }

    private enum LockMode: Sendable { case shared, exclusive }

    func withExclusiveLock<R>(at url: URL, _ body: () async throws -> R) async throws -> R {
        try await withLock(at: url, mode: .exclusive, body)
    }

    func withSharedLock<R>(at url: URL, _ body: () async throws -> R) async throws -> R {
        try await withLock(at: url, mode: .shared, body)
    }

    private func withLock<R>(at url: URL, mode: LockMode, _ body: () async throws -> R) async throws -> R {
        let path = url.path
        await acquireGate(for: path)
        defer { releaseGate(for: path) }
#if canImport(Darwin) || canImport(Glibc)
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw LockFileError(message: "could not open lock file at \(path)") }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        let operation = mode == .exclusive ? LOCK_EX : LOCK_SH
        while flock(fd, operation | LOCK_NB) != 0 {
            let error = errno
            if error == EINTR { continue }
            guard error == EWOULDBLOCK else {
                throw LockFileError(message: "could not acquire lock at \(path)")
            }
            try await Self.waitForOSLock(fd, operation: operation, path: path)
            break
        }
#endif
        return try await body()
    }

#if canImport(Darwin) || canImport(Glibc)
    // flock may wait for another store or process. Never park a cooperative executor thread.
    private nonisolated static func waitForOSLock(_ fd: Int32, operation: Int32, path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                while flock(fd, operation) != 0 {
                    if errno != EINTR {
                        continuation.resume(throwing: LockFileError(message: "could not acquire lock at \(path)"))
                        return
                    }
                }
                continuation.resume()
            }
        }
    }
#endif
}
