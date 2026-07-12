import Foundation

extension Workspace {
    /// Which checkpoints remain after storage compaction.
    public enum Retention: Sendable, Codable, Equatable {
        /// Keep every checkpoint while still sweeping orphaned snapshots and blobs.
        case all
        /// Keep the newest `count` checkpoints plus optionally labeled and explicitly selected checkpoints.
        case latest(
            Int,
            preservingLabeled: Bool = true,
            preserving: Set<UUID> = []
        )
    }

    /// Physical checkpoint-store usage. Blob bytes exclude manifests and checkpoint metadata.
    public struct StorageStatistics: Sendable, Codable, Equatable {
        public var checkpointCount: Int
        public var snapshotCount: Int
        public var blobCount: Int
        public var blobBytes: UInt64

        public init(checkpointCount: Int, snapshotCount: Int, blobCount: Int, blobBytes: UInt64) {
            self.checkpointCount = checkpointCount
            self.snapshotCount = snapshotCount
            self.blobCount = blobCount
            self.blobBytes = blobBytes
        }

        static let empty = StorageStatistics(checkpointCount: 0, snapshotCount: 0, blobCount: 0, blobBytes: 0)
    }

    /// The applied or projected result of compacting checkpoint storage.
    public struct CompactionReport: Sendable, Codable, Equatable {
        public var dryRun: Bool
        public var before: StorageStatistics
        public var after: StorageStatistics
        public var removedCheckpointIDs: [UUID]
        public var rebasedCheckpointIDs: [UUID]

        public var removedCheckpointCount: Int { removedCheckpointIDs.count }
        public var removedSnapshotCount: Int { max(0, before.snapshotCount - after.snapshotCount) }
        public var removedBlobCount: Int { max(0, before.blobCount - after.blobCount) }
        public var reclaimedBytes: UInt64 { before.blobBytes >= after.blobBytes ? before.blobBytes - after.blobBytes : 0 }

        public init(
            dryRun: Bool,
            before: StorageStatistics,
            after: StorageStatistics,
            removedCheckpointIDs: [UUID],
            rebasedCheckpointIDs: [UUID]
        ) {
            self.dryRun = dryRun
            self.before = before
            self.after = after
            self.removedCheckpointIDs = removedCheckpointIDs
            self.rebasedCheckpointIDs = rebasedCheckpointIDs
        }
    }

    /// Returns current physical checkpoint-store usage.
    public func storageStatistics() async throws -> StorageStatistics {
        try await store.storageStatistics(workspaceId: workspaceId)
    }

    /// Prunes checkpoints, rebases retained lineage, and sweeps unreachable snapshots and blobs.
    ///
    /// A dry run performs the same validation and returns projected statistics without changing storage.
    public func compact(retaining retention: Retention, dryRun: Bool = false) async throws -> CompactionReport {
        try await ensureLoaded()
        let result = try await store.compact(workspaceId: workspaceId, retaining: retention, dryRun: dryRun)
        if !dryRun {
            checkpoints = result.checkpoints
            headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        }
        return result.report
    }
}

struct StoreCompactionResult: Sendable {
    var report: Workspace.CompactionReport
    var checkpoints: [Checkpoint]
}

struct CheckpointRetentionPlan: Sendable {
    var checkpoints: [Checkpoint]
    var removedCheckpointIDs: [UUID]
    var rebasedCheckpointIDs: [UUID]
}

enum CheckpointRetentionPlanner {
    static func plan(
        checkpoints: [Checkpoint],
        retaining retention: Workspace.Retention
    ) throws -> CheckpointRetentionPlan {
        let ordered = checkpoints.sorted(by: Checkpoint.orderedBefore)
        var byID: [UUID: Checkpoint] = [:]
        for checkpoint in ordered {
            guard byID.updateValue(checkpoint, forKey: checkpoint.id) == nil else {
                throw WorkspaceError.storageCorrupted("duplicate checkpoint id \(checkpoint.id)")
            }
        }
        try validateAcyclicLineage(checkpoints: ordered, checkpointsByID: byID)
        var retainedIDs: Set<UUID>

        switch retention {
        case .all:
            retainedIDs = Set(byID.keys)
        case let .latest(count, preservingLabeled, explicitlyPreserved):
            guard count > 0 else {
                throw WorkspaceError.unsupported("checkpoint retention count must be positive")
            }
            for id in explicitlyPreserved.sorted(by: { $0.uuidString < $1.uuidString }) where byID[id] == nil {
                throw WorkspaceError.checkpointNotFound(id)
            }
            retainedIDs = Set(ordered.suffix(count).map(\.id))
            retainedIDs.formUnion(explicitlyPreserved)
            if preservingLabeled {
                retainedIDs.formUnion(ordered.lazy.filter { $0.label != nil }.map(\.id))
            }
        }

        // A retained rollback or transaction keeps its explicitly referenced provenance checkpoint.
        var changed = true
        while changed {
            changed = false
            for id in Array(retainedIDs) {
                guard let checkpoint = byID[id], let provenanceID = checkpoint.provenanceCheckpointID,
                      byID[provenanceID] != nil
                else { continue }
                if retainedIDs.insert(provenanceID).inserted { changed = true }
            }
        }

        var retained: [Checkpoint] = []
        var rebasedIDs: [UUID] = []
        for checkpoint in ordered where retainedIDs.contains(checkpoint.id) {
            var copy = checkpoint
            let parentID = nearestRetainedParent(
                of: checkpoint,
                retainedIDs: retainedIDs,
                checkpointsByID: byID
            )
            if parentID != checkpoint.parentID {
                copy.parentID = parentID
                rebasedIDs.append(copy.id)
            }
            retained.append(copy)
        }

        return CheckpointRetentionPlan(
            checkpoints: retained,
            removedCheckpointIDs: ordered.filter { !retainedIDs.contains($0.id) }.map(\.id),
            rebasedCheckpointIDs: rebasedIDs
        )
    }

    static func materialize(
        _ plan: CheckpointRetentionPlan,
        loadSnapshot: (UUID) throws -> Snapshot?
    ) throws -> [Checkpoint] {
        let rebasedIDs = Set(plan.rebasedCheckpointIDs)
        var retained = plan.checkpoints
        var retainedByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })

        for index in retained.indices {
            let checkpoint = retained[index]
            guard let snapshot = try loadSnapshot(checkpoint.snapshotId) else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) has no snapshot")
            }
            guard rebasedIDs.contains(checkpoint.id) else { continue }
            let parent = checkpoint.parentID.flatMap { retainedByID[$0] }
            let parentSnapshot = try parent.map {
                guard let snapshot = try loadSnapshot($0.snapshotId) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \($0.id) has no snapshot")
                }
                return snapshot
            }
            let rebased = checkpoint.rebased(to: parent, snapshot: snapshot, parentSnapshot: parentSnapshot)
            retained[index] = rebased
            retainedByID[rebased.id] = rebased
        }
        return retained
    }

    private static func nearestRetainedParent(
        of checkpoint: Checkpoint,
        retainedIDs: Set<UUID>,
        checkpointsByID: [UUID: Checkpoint]
    ) -> UUID? {
        var candidate = checkpoint.parentID
        var visited: Set<UUID> = []
        while let id = candidate, visited.insert(id).inserted {
            if retainedIDs.contains(id) { return id }
            candidate = checkpointsByID[id]?.parentID
        }
        return nil
    }

    private static func validateAcyclicLineage(
        checkpoints: [Checkpoint],
        checkpointsByID: [UUID: Checkpoint]
    ) throws {
        for checkpoint in checkpoints {
            var candidate: UUID? = checkpoint.id
            var visited: Set<UUID> = []
            while let id = candidate, let current = checkpointsByID[id] {
                guard visited.insert(id).inserted else {
                    throw WorkspaceError.storageCorrupted("checkpoint lineage contains a cycle at \(id)")
                }
                candidate = current.parentID
            }
        }
    }
}
