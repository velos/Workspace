import Foundation

extension Workspace {
    /// Creates a checkpoint for the workspace's current filesystem state.
    public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()
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
    ///
    /// The filesystem changes performed by the rollback are also recorded as a `rollback`
    /// mutation, so the mutation log stays a complete account of tree changes.
    public func rollback(to checkpointId: UUID, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()
        let checkpoint = try checkpointOrThrow(id: checkpointId)
        let targetSnapshot = try await loadSnapshotOrThrow(
            id: checkpoint.snapshotId,
            workspaceId: checkpoint.workspaceId
        )
        let previousSnapshot = try await captureSnapshot()
        try await untrackedRestore(targetSnapshot)
        let restoredSnapshot = try await captureSnapshot()

        let delta = snapshotDelta(from: previousSnapshot.entry, to: restoredSnapshot.entry)
        if delta.hasChanges {
            try await appendMutation(
                kind: .rollback,
                touchedPaths: Array(delta.touchedPaths).sorted(),
                fileChanges: delta.fileChanges,
                diff: delta.fileChanges.count == 1 ? delta.fileChanges[0].diff : nil
            )
        }

        return try await persistCheckpoint(
            snapshot: restoredSnapshot,
            label: label,
            parentCheckpointId: headCheckpointId,
            baseCheckpointId: baseCheckpointId,
            rollbackSourceCheckpointId: checkpoint.id,
            eventKind: .rolledBack
        )
    }

    /// Removes tracked mutation records with `sequence <= sequence` from the store, always
    /// retaining the newest record so future sequence numbers stay monotonic. Long-running
    /// workspaces can use this to keep the mutation log bounded.
    public func pruneMutationHistory(throughSequence sequence: Int) async throws {
        try await ensureLoaded()
        try await store.pruneMutationRecords(workspaceId: workspaceId, throughSequence: sequence)
        mutations = try await store.listMutationRecords(workspaceId: workspaceId)
        nextMutationSequence = (mutations.map(\.sequence).max() ?? 0) + 1
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
    /// with the same `workspaceId` and shared store. Polling uses ``Workspace/checkpointEventPollInterval``
    /// (500 ms by default) while the stream is active; lower it in tests to reduce wait time.
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
