import Foundation

extension Workspace {
    /// Creates a checkpoint for the workspace's current filesystem state.
    public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        let snapshot = try await captureSnapshot()
        return try await persistCheckpoint(
            snapshot: snapshot,
            label: label,
            parentCheckpointId: headCheckpointId,
            baseCheckpointId: baseCheckpointId,
            rollbackSourceCheckpointId: nil,
            eventKind: .created
        )
    }

    /// Restores the workspace to a prior checkpoint and records the rollback as a new checkpoint.
    public func rollback(to checkpointId: UUID, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        let checkpoint = try checkpointOrThrow(id: checkpointId)
        let targetSnapshot = try await loadSnapshotOrThrow(id: checkpoint.snapshotId)
        try await untrackedRestore(targetSnapshot)
        let restoredSnapshot = try await captureSnapshot()
        return try await persistCheckpoint(
            snapshot: restoredSnapshot,
            label: label,
            parentCheckpointId: headCheckpointId,
            baseCheckpointId: baseCheckpointId,
            rollbackSourceCheckpointId: checkpoint.id,
            eventKind: .rolledBack
        )
    }

    /// Lists checkpoints owned by this workspace.
    public func listCheckpoints() async throws -> [Checkpoint] {
        try await ensureLoaded()
        return checkpoints
    }

    /// Returns one checkpoint owned by this workspace when present.
    public func checkpoint(id: UUID) async throws -> Checkpoint? {
        try await ensureLoaded()
        return checkpoints.first(where: { $0.id == id })
    }

    /// Loads the snapshot artifact persisted alongside `checkpoint`.
    public func snapshot(for checkpoint: Checkpoint) async throws -> Snapshot {
        try await ensureLoaded()
        return try await loadSnapshotOrThrow(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceId)
    }

    /// Watches for checkpoint events, including checkpoints created by other workspace instances
    /// with the same `workspaceId` and shared store.
    public func watchCheckpointEvents() async throws -> AsyncStream<CheckpointEvent> {
        try await ensureLoaded()

        let watcherId = UUID()
        let deliveredIds = Set(checkpoints.map(\.id))
        var continuation: AsyncStream<CheckpointEvent>.Continuation?
        let stream = AsyncStream<CheckpointEvent> {
            continuation = $0
        }

        guard let continuation else {
            return stream
        }

        checkpointWatchers[watcherId] = CheckpointWatcher(
            deliveredCheckpointIds: deliveredIds,
            continuation: continuation
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeCheckpointWatcher(id: watcherId)
            }
        }
        ensureCheckpointPolling()
        return stream
    }
}
