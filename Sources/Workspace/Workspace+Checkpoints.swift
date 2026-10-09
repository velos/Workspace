import Foundation

extension Workspace {
    /// Creates a checkpoint for the workspace's current filesystem state.
    public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        try await reconcileCheckpointsWithStore()
        let checkpoint = try await store.captureRevision(
            from: filesystem,
            draft: CheckpointDraft(
                workspaceID: workspaceId,
                label: label,
                preferredParentID: headCheckpointId,
                origin: .manual
            )
        )
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        checkpoints.sort(by: checkpointSort)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        emitWorkspaceEvent(.checkpoint(checkpoint))
        return checkpoint
    }

    /// Restores the workspace to a prior checkpoint and records the rollback as a new checkpoint.
    ///
    /// The filesystem changes performed by the rollback are also recorded as a `rollback`
    /// mutation, so the mutation log stays a complete account of tree changes.
    func rollback(to checkpointId: UUID, label: String? = nil) async throws -> Checkpoint {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        try await reconcileCheckpointsWithStore()
        let checkpoint = try checkpointOrThrow(id: checkpointId)
        let targetSnapshot = try await loadSnapshotOrThrow(
            id: checkpoint.snapshotId,
            workspaceId: checkpoint.workspaceId
        )
        let previousSnapshot = try await Snapshot.capture(from: filesystem)
        do {
            try await Snapshot.restore(targetSnapshot, to: filesystem)
            let restoredSnapshot = try await Snapshot.capture(from: filesystem)
            let changes = changeSet(from: previousSnapshot, to: restoredSnapshot)
            let result = try await persistMutationCheckpoint(
                snapshot: restoredSnapshot,
                label: label,
                origin: .rollback(from: checkpoint.id),
                operation: .rollback,
                changes: recordingChanges(changes, from: previousSnapshot, to: restoredSnapshot)
            )
            noteWorkspaceSnapshot(restoredSnapshot)
            if !changes.isEmpty { emitWorkspaceEvent(.changes(changes)) }
            return result
        } catch {
            try await restoreAfterFailure([previousSnapshot], originalError: error)
        }
    }

    /// Returns one checkpoint owned by this workspace when present.
    public func checkpoint(id: UUID) async throws -> Checkpoint? {
        try await reconcileCheckpointsWithStore()
        return checkpoints.first(where: { $0.id == id })
    }

    /// Lists this workspace's checkpoints in stable creation order.
    public func checkpoints() async throws -> [Checkpoint] {
        try await reconcileCheckpointsWithStore()
        return checkpoints
    }

    /// Restores a checkpoint and records the restoration as a new checkpoint.
    public func restore(to checkpoint: Checkpoint, label: String? = nil) async throws -> Checkpoint {
        try await rollback(to: checkpoint.id, label: label)
    }
}
