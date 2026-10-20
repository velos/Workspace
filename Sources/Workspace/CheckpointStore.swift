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
protocol CheckpointStore: AnyObject, Sendable {
    func prepare(workspaceId: UUID) async throws
    func changes(workspaceId: UUID) async throws -> AsyncStream<Void>
    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint
    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint]
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex?
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
    func listMutations(workspaceId: UUID) async throws -> [Mutation] {
        try await listMutations(workspaceId: workspaceId, afterSequence: 0).records
    }
}

/// An in-memory checkpoint store for tests and ephemeral workspaces.
actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [Checkpoint]] = [:]
    private var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
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
        let mutationCursor = persistedMutationCursor(workspaceId: draft.workspaceID)
        let snapshot = try await Snapshot.capture(from: filesystem)
        return try persistRevision(snapshot, draft: draft, mutationCursor: mutationCursor)
    }

    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint {
        try persistRevision(snapshot, draft: draft, mutationCursor: persistedMutationCursor(workspaceId: draft.workspaceID))
    }

    private func persistedMutationCursor(workspaceId: UUID) -> Int {
        mutationHighWaterMarks[workspaceId] ?? 0
    }

    private func persistRevision(_ snapshot: Snapshot, draft: CheckpointDraft, mutationCursor: Int) throws -> Checkpoint {
        var list = checkpointsByWorkspace[draft.workspaceID] ?? []
        let parent = resolvedParent(for: draft, checkpoints: list)
        let parentSnapshot = parent.flatMap { snapshotsByWorkspace[draft.workspaceID]?[$0.snapshotId] }
        if let parent, parentSnapshot == nil {
            throw WorkspaceError.storageCorrupted("checkpoint \(parent.id) has no snapshot")
        }
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
            blobs[SHA256.hexDigest(of: file.data)] = UInt64(file.data.count)
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
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let compactEncoder: JSONEncoder

    private let checkpointCapture: Workspace.CheckpointCapturePolicy
    // Actor reentrancy must suspend contenders before they can conflict with this store's own fd.
    private var heldLocks: Set<PathName> = []
    private var lockWaiters: [PathName: [CheckedContinuation<Void, Never>]] = [:]

    private var listCheckpointsCache: [UUID: (cacheKey: String, checkpoints: [Checkpoint])] = [:]

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        checkpointCapture: Workspace.CheckpointCapturePolicy = .trustMetadata
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.checkpointCapture = checkpointCapture

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.compactEncoder = JSONEncoder()
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
            let parentSnapshot = try parent.map {
                guard let snapshot = try loadSnapshotUnlocked(id: $0.snapshotId, workspaceId: draft.workspaceID) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \($0.id) has no snapshot")
                }
                return snapshot
            }
            let checkpoint = Checkpoint.make(
                snapshot: snapshot,
                draft: draft,
                mutationCursor: mutationCursor,
                parent: parent,
                parentSnapshot: parentSnapshot
            )
            try writeSnapshotUnlocked(snapshot, workspaceId: draft.workspaceID)
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID))
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

    /// A persisted snapshot: the tree structure with file contents replaced by content hashes.
    /// The bytes themselves live in per-workspace `blobs/<sha256>` files, so identical content is
    /// stored once no matter how many snapshots reference it, and never base64-inflated.
    private struct SnapshotManifest: Codable, Sendable {
        struct Node: Codable, Sendable {
            enum Kind: String, Codable {
                case file, directory, symlink, missing
            }

            var kind: Kind
            var path: WorkspacePath
            var permissions: POSIXPermissions?
            var contentHash: String?
            var contentSize: UInt64? = nil
            var modificationDate: Date? = nil
            var symlinkTarget: String?
            var children: [Node]?
        }

        var version: Int
        var id: UUID
        var rootPath: WorkspacePath
        var root: Node
        // Older manifests and materialized snapshots have no trustworthy capture timestamp.
        var captureStartedAt: Date? = nil
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
            let captureStartedAt = Date()
            let snapshotID = UUID()
            let root = try await self.captureManifestNode(
                from: filesystem,
                at: .root,
                reusing: parentManifest?.root,
                previousCaptureStartedAt: parentManifest?.captureStartedAt,
                workspaceId: draft.workspaceID
            )
            let manifest = SnapshotManifest(
                version: 2, id: snapshotID, rootPath: .root, root: root, captureStartedAt: captureStartedAt
            )
            let beforeIndex = try parentManifest.map {
                RevisionIndex(
                    id: $0.id,
                    root: $0.rootPath,
                    entry: try self.revisionEntry(from: $0.root, workspaceId: draft.workspaceID)
                )
            } ?? RevisionIndex(
                id: UUID(),
                root: .root,
                entry: .missing(path: .root)
            )
            let afterIndex = RevisionIndex(
                id: snapshotID,
                root: .root,
                entry: try self.revisionEntry(from: root, workspaceId: draft.workspaceID)
            )
            let blobsRoot = self.blobsDirectoryURL(workspaceId: draft.workspaceID)
            let beforeRoot = parentManifest?.root
            let changes = try await ChangeSet.compare(
                before: beforeIndex,
                after: afterIndex,
                maxTextBytes: 1_000_000,
                loadBefore: { path in try Self.loadManifestFile(path, root: beforeRoot, blobsRoot: blobsRoot) },
                loadAfter: { path in try Self.loadManifestFile(path, root: root, blobsRoot: blobsRoot) }
            )
            let checkpoint = Checkpoint.make(
                snapshotID: snapshotID,
                draft: draft,
                mutationCursor: mutationCursor,
                parent: parent,
                summary: changes.summary
            )
            try self.write(manifest, to: self.snapshotURL(id: snapshotID, workspaceId: draft.workspaceID))
            try self.write(
                checkpoint,
                to: self.checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID)
            )
            self.listCheckpointsCache[draft.workspaceID] = nil
            return checkpoint
        }
    }

    private func writeSnapshotUnlocked(_ snapshot: Snapshot, workspaceId: UUID) throws {
        let root = try writeManifestNode(snapshot.entry, workspaceId: workspaceId)
        let manifest = SnapshotManifest(
            version: 2,
            id: snapshot.id,
            rootPath: snapshot.rootPath,
            root: root
        )
        try write(manifest, to: snapshotURL(id: snapshot.id, workspaceId: workspaceId))
    }

    private func loadManifestUnlocked(id: UUID, workspaceId: UUID) throws -> SnapshotManifest? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        guard manifest.id == id else {
            throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
        }
        return manifest
    }

    private func captureManifestNode(
        from filesystem: any FileSystem,
        at path: WorkspacePath,
        reusing previous: SnapshotManifest.Node?,
        previousCaptureStartedAt: Date?,
        workspaceId: UUID
    ) async throws -> SnapshotManifest.Node {
        // exists follows the final symlink on some backends, losing dangling
        // links and cycles. Capture the entry itself, just as Snapshot.capture does.
        guard let info = try await Snapshot.infoIfPresent(at: path, on: filesystem) else {
            return SnapshotManifest.Node(kind: .missing, path: path)
        }
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
               previous?.modificationDate != nil,
               previous?.modificationDate == info.modificationDate,
               let hash = previous?.contentHash,
               Self.isValidContentHash(hash),
               fileManager.fileExists(atPath: blobURL(hash: hash, workspaceId: workspaceId).path) {
                return SnapshotManifest.Node(
                    kind: .file,
                    path: path,
                    permissions: info.permissions,
                    contentHash: hash,
                    contentSize: info.size,
                    modificationDate: info.modificationDate
                )
            }
            let data = try await filesystem.readFile(path: path)
            let hash = SHA256.hexDigest(of: data)
            let blob = blobURL(hash: hash, workspaceId: workspaceId)
            if !fileManager.fileExists(atPath: blob.path) { try data.write(to: blob, options: .atomic) }
            return SnapshotManifest.Node(
                kind: .file,
                path: path,
                permissions: info.permissions,
                contentHash: hash,
                contentSize: UInt64(data.count),
                modificationDate: info.modificationDate
            )
        case .directory:
            var previousChildren: [PathName: SnapshotManifest.Node] = [:]
            for child in previous?.kind == .directory ? previous?.children ?? [] : [] {
                guard previousChildren.updateValue(child, forKey: PathName(child.path.name)) == nil else {
                    throw WorkspaceError.storageCorrupted(
                        "snapshot directory \(path) contains duplicate child \(child.path.name)"
                    )
                }
            }
            var children: [SnapshotManifest.Node] = []
            for entry in try await filesystem.listDirectory(path: path).sorted(by: { PathName($0.name) < PathName($1.name) }) {
                children.append(
                    try await captureManifestNode(
                        from: filesystem,
                        at: path.appending(entry.name),
                        reusing: previousChildren[PathName(entry.name)],
                        previousCaptureStartedAt: previousCaptureStartedAt,
                        workspaceId: workspaceId
                    )
                )
            }
            return SnapshotManifest.Node(
                kind: .directory,
                path: path,
                permissions: info.permissions,
                modificationDate: info.modificationDate,
                children: children
            )
        case .symlink:
            return SnapshotManifest.Node(
                kind: .symlink,
                path: path,
                permissions: info.permissions,
                modificationDate: info.modificationDate,
                symlinkTarget: try await filesystem.readSymlink(path: path)
            )
        }
    }

    private static func loadManifestFile(
        _ path: WorkspacePath,
        root: SnapshotManifest.Node?,
        blobsRoot: URL
    ) throws -> Data {
        guard let root, let node = manifestNodeStatic(at: path, in: root), node.kind == .file,
              let hash = node.contentHash, isValidContentHash(hash)
        else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        let url = blobsRoot.appendingPathComponent(hash, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(path)")
        }
        return try Data(contentsOf: url)
    }

    private static func manifestNodeStatic(
        at path: WorkspacePath,
        in node: SnapshotManifest.Node
    ) -> SnapshotManifest.Node? {
        if node.path == path { return node }
        for child in node.children ?? [] where path.isWithin(child.path) {
            return manifestNodeStatic(at: path, in: child)
        }
        return nil
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
            let url = snapshotURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
            guard manifest.id == id else {
                throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
            }
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
            let url = snapshotURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
            guard manifest.id == id else {
                throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
            }
            guard let node = manifestNode(at: path, in: manifest.root), node.kind == .file else { return nil }
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            let blob = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: blob.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(path)")
            }
            let handle = try FileHandle(forReadingFrom: blob)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard offset < size else { return Data() }
            try handle.seek(toOffset: offset)
            let count = min(UInt64(length ?? Int.max), size - offset)
            return try handle.read(upToCount: Int(count)) ?? Data()
        }
    }

    private func revisionEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID
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
                children: try (node.children ?? []).map { try revisionEntry(from: $0, workspaceId: workspaceId) }
            )
        case .symlink:
            return .symbolicLink(
                path: node.path,
                target: node.symlinkTarget ?? "",
                permissions: node.permissions ?? POSIXPermissions(0o777)
            )
        }
    }

    private func manifestNode(at path: WorkspacePath, in node: SnapshotManifest.Node) -> SnapshotManifest.Node? {
        if node.path == path { return node }
        for child in node.children ?? [] where path.isWithin(child.path) {
            return manifestNode(at: path, in: child)
        }
        return nil
    }

    private func writeManifestNode(
        _ entry: Snapshot.Entry,
        workspaceId: UUID
    ) throws -> SnapshotManifest.Node {
        switch entry {
        case let .missing(missing):
            return SnapshotManifest.Node(kind: .missing, path: missing.path)
        case let .file(file):
            let hash = SHA256.hexDigest(of: file.data)
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            if !fileManager.fileExists(atPath: url.path) {
                try file.data.write(to: url, options: .atomic)
            }
            return SnapshotManifest.Node(
                kind: .file,
                path: file.path,
                permissions: file.permissions,
                contentHash: hash,
                contentSize: UInt64(file.data.count)
            )
        case let .symlink(symlink):
            return SnapshotManifest.Node(
                kind: .symlink,
                path: symlink.path,
                permissions: symlink.permissions,
                symlinkTarget: symlink.target
            )
        case let .directory(directory):
            return SnapshotManifest.Node(
                kind: .directory,
                path: directory.path,
                permissions: directory.permissions,
                children: try directory.children.map {
                    try writeManifestNode($0, workspaceId: workspaceId)
                }
            )
        }
    }

    private func snapshotEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID
    ) throws -> Snapshot.Entry {
        switch node.kind {
        case .missing:
            return .missing(Snapshot.Missing(path: node.path))
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(node.path)")
            }
            return .file(
                Snapshot.File(
                    path: node.path,
                    data: try Data(contentsOf: url),
                    permissions: node.permissions ?? POSIXPermissions(0o644)
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
                    children: try (node.children ?? []).map {
                        try snapshotEntry(from: $0, workspaceId: workspaceId)
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
            try write(state, to: mutationSequenceURL(workspaceId: mutation.workspaceID))

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
            try write(state, to: mutationSequenceURL(workspaceId: workspaceId))
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
            try write(state, to: mutationSequenceURL(workspaceId: workspaceId))
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
        for checkpoint in retained {
            let manifestURL = snapshotURL(id: checkpoint.snapshotId, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) has no snapshot")
            }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.id == checkpoint.snapshotId else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) references a mismatched snapshot")
            }
            try collectContentHashes(from: manifest.root, into: &retainedBlobHashes)
        }

        var retainedBlobBytes: UInt64 = 0
        for hash in retainedBlobHashes {
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash)")
            }
            retainedBlobBytes += try fileSize(at: url)
        }
        let after = Workspace.StorageStatistics(
            checkpointCount: retained.count,
            snapshotCount: retainedSnapshotIDs.count,
            blobCount: retainedBlobHashes.count,
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

        for checkpoint in retained where rebasedIDs.contains(checkpoint.id) {
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: workspaceId))
        }
        for id in plan.removedCheckpointIDs {
            try removeIfPresent(checkpointURL(id: id, workspaceId: workspaceId))
        }
        for url in try artifactURLs(in: snapshotsDirectoryURL(workspaceId: workspaceId), pathExtension: "json") {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  retainedSnapshotIDs.contains(id)
            else {
                try fileManager.removeItem(at: url)
                continue
            }
        }
        for url in try blobURLs(workspaceId: workspaceId)
        where !retainedBlobHashes.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        listCheckpointsCache[workspaceId] = nil
        return StoreCompactionResult(report: report, checkpoints: retained)
    }

    private func loadAllCheckpointsUnlocked(workspaceId: UUID) throws -> [Checkpoint] {
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
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        guard manifest.id == id else {
            throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
        }
        return Snapshot(
            id: manifest.id,
            rootPath: manifest.rootPath,
            entry: try snapshotEntry(from: manifest.root, workspaceId: workspaceId)
        )
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
        for blob in blobs { blobBytes += try fileSize(at: blob) }
        return Workspace.StorageStatistics(
            checkpointCount: checkpoints.count,
            snapshotCount: snapshots.count,
            blobCount: blobs.count,
            blobBytes: blobBytes
        )
    }

    private func artifactURLs(in directory: URL, pathExtension: String) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
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
            options: [.skipsHiddenFiles]
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

    private func collectContentHashes(from node: SnapshotManifest.Node, into hashes: inout Set<String>) throws {
        switch node.kind {
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            hashes.insert(hash)
        case .directory:
            for child in node.children ?? [] { try collectContentHashes(from: child, into: &hashes) }
        case .missing, .symlink:
            break
        }
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
    private func persistedMutationCursor(workspaceId: UUID) async throws -> Int {
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

    private func ensureWorkspaceDirectories(for workspaceId: UUID) async throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try await withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            try ensureWorkspaceDirectoriesLocked(for: workspaceId)
        }
    }

    private func ensureWorkspaceDirectoriesLocked(for workspaceId: UUID) throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let existed = fileManager.fileExists(atPath: workspaceURL.path)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        if fileManager.fileExists(atPath: formatURL.path) {
            try validateWorkspaceFormatLocked(workspaceId)
        } else {
            if existed,
               !(try fileManager.contentsOfDirectory(at: workspaceURL, includingPropertiesForKeys: nil)).isEmpty
            {
                throw WorkspaceError.storageCorrupted("workspace store has no format version")
            }
            try encoder.encode(StoreFormat(version: StoreFormat.currentVersion)).write(to: formatURL, options: .atomic)
        }
        try fileManager.createDirectory(at: checkpointsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
    }

    private func validateWorkspaceFormatIfPresent(_ workspaceId: UUID) async throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: workspaceURL.path) else { return }
        try await withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            try validateWorkspaceFormatLocked(workspaceId)
        }
    }

    private func validateWorkspaceFormatLocked(_ workspaceId: UUID) throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        guard fileManager.fileExists(atPath: formatURL.path) else {
            throw WorkspaceError.storageCorrupted("workspace store has no format version")
        }
        let format = try decoder.decode(StoreFormat.self, from: Data(contentsOf: formatURL))
        guard format.version == StoreFormat.currentVersion else {
            throw WorkspaceError.storageCorrupted("unsupported store format version \(format.version)")
        }
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
    private func lifecycleLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("lifecycle.lock", isDirectory: false)
    }

    private func formatLockURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(".\(workspaceId.uuidString).format.lock", isDirectory: false)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private struct LockFileError: Error {
        var message: String
    }

    private struct StoreFormat: Codable {
        // Retained to read existing stores. Writers must preserve the sequence
        // high-water mark; older writers are incompatible (see README).
        static let currentVersion = 1
        var version: Int
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

    private func withExclusiveLock<R>(at url: URL, _ body: () async throws -> R) async throws -> R {
        try await withLock(at: url, mode: .exclusive, body)
    }

    private func withSharedLock<R>(at url: URL, _ body: () async throws -> R) async throws -> R {
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
