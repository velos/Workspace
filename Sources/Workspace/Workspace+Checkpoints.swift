import Foundation

extension Workspace {
    /// Creates a checkpoint for the workspace's current filesystem state.
    public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        try await reconcileCheckpointsWithStore()
        let metadata = hasBegunTransaction ? try await MetadataIndex.capture(from: filesystem) : nil
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
        if let metadata { try? await seedTransactionBase(checkpoint, metadata: metadata) }
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
        let (comparison, pin) = try await checkpointComparison(checkpoint)
        defer { withExtendedLifetime(pin) {} }
        let directories = comparison.restoreScope()
        let before = try await comparison.sparseSnapshot(in: comparison.current, preserving: directories)
        let target = try await comparison.sparseSnapshot(in: comparison.checkpoint, preserving: directories)
        do {
            try await Snapshot.restore(target, to: filesystem, preservingDirectories: directories)
            var metadata = comparison.metadata
            let after = try await Snapshot.captureSparse(from: filesystem, template: target,
                                                         preserving: directories, metadata: &metadata,
                                                         previousChildren: comparison.current.children)
            let changes = changeSet(from: before, to: after)
            let recorded = recordingChanges(changes, from: before, to: after)
            let result = try await withMutationCheckpoint(operation: .rollback, changes: recorded) {
                try await store.publishRevision(
                    reusing: checkpoint.snapshotId, patch: after, preservingDirectories: directories,
                    metadata: metadata, draft: CheckpointDraft(workspaceID: workspaceId, label: label,
                        preferredParentID: headCheckpointId, origin: .rollback(from: checkpoint.id)))
            }
            checkpoints.append(result)
            checkpoints.sort(by: checkpointSort)
            headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
            if var observed = observedFilesystem {
                observed.reconcileRestoration(after.entry, preserving: directories, metadata: metadata)
                observedFilesystem = observed
            }
            emitWorkspaceEvent(.checkpoint(result))
            if !changes.isEmpty { emitWorkspaceEvent(.changes(changes)) }
            return result
        } catch {
            do { try await Snapshot.restore(before, to: filesystem, preservingDirectories: directories) }
            catch let rollbackError { throw WorkspaceRollbackError(originalError: error, rollbackError: rollbackError) }
            throw error
        }
    }

    func checkpointComparison(_ checkpoint: Checkpoint) async throws -> (RevisionComparison, TransactionRevisionPin) {
        let store = store
        let (revision, pin) = try await TransactionRevisionGate.shared.withLock {
            guard let revision = try await store.loadCapturedRevision(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceID) else {
                throw WorkspaceError.revisionDataNotFound(checkpoint.snapshotId)
            }
            return (revision, TransactionRevisionPin(checkpoint))
        }
        let content = TransactionRevisionContent(checkpoint: checkpoint, store: store)
        let comparison = try await RevisionComparison.capture(revision, from: filesystem,
            policy: checkpointCapture, load: { try await content.read($0) })
        return (comparison, pin)
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
