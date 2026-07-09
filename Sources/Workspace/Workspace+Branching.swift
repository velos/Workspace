import Foundation

extension Workspace {
    /// Creates an isolated branch workspace from the current filesystem state.
    ///
    /// Branches share only the checkpoint store with their parent. Filesystem state, watchers, and mutation
    /// sequences are isolated to the returned workspace.
    /// - Parameters:
    ///   - label: Optional label for the branch's seed checkpoint.
    ///   - filesystem: Filesystem the branch will use; defaults to a new `InMemoryFilesystem` when
    ///     you omit this value.
    public func branch(
        label: String? = nil,
        filesystem: (any FileSystem)? = nil
    ) async throws -> Workspace {
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()

        let baseCheckpointId = headCheckpointId
        let snapshot = try await captureSnapshot()
        let branchFilesystem = filesystem ?? InMemoryFilesystem()
        try await Snapshot.restore(snapshot, to: branchFilesystem)

        let branch = Workspace(
            workspaceId: UUID(),
            filesystem: branchFilesystem,
            store: store,
            baseCheckpointId: baseCheckpointId,
            baseMutationCursor: latestMutationSequence(),
            tracking: tracking
        )
        _ = try await branch.seedBranchCheckpoint(
            snapshot: snapshot,
            label: label,
            baseCheckpointId: baseCheckpointId
        )
        return branch
    }

    /// Merges another workspace into this workspace when this workspace still points at the other's base.
    ///
    /// The merge is refused when this workspace's checkpoint head moved past the branch's base
    /// (``WorkspaceError/mergeConflict(parentWorkspaceId:expectedBase:actualHead:)``) or when this
    /// workspace has tracked mutations that no checkpoint captures
    /// (``WorkspaceError/mergeUncheckpointedChanges(parentWorkspaceId:baseMutationCursor:currentMutationCursor:)``),
    /// since restoring the branch snapshot would silently discard those edits.
    public func merge(_ other: Workspace, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()
        try await other.reconcileCheckpointsWithStore()

        let expectedBase = await other.mergeBaseCheckpointId()
        guard headCheckpointId == expectedBase else {
            throw WorkspaceError.mergeConflict(
                parentWorkspaceId: workspaceId,
                expectedBase: expectedBase,
                actualHead: headCheckpointId
            )
        }

        // The head comparison only sees checkpoints. Tracked writes made after the branch was
        // created leave the head untouched, so restoring the branch snapshot would silently
        // discard them; refuse the merge instead.
        if let expectedCursor = await other.mergeBaseMutationCursor() {
            let currentCursor = latestMutationSequence()
            guard currentCursor <= expectedCursor else {
                throw WorkspaceError.mergeUncheckpointedChanges(
                    parentWorkspaceId: workspaceId,
                    baseMutationCursor: expectedCursor,
                    currentMutationCursor: currentCursor
                )
            }
        }

        let previousSnapshot = try await captureSnapshot()
        let incomingSnapshot = try await other.captureSnapshot()
        let incomingHead = try await other.currentHeadCheckpointId()
        let delta = snapshotDelta(from: previousSnapshot.entry, to: incomingSnapshot.entry)

        try await untrackedRestore(incomingSnapshot)

        if delta.hasChanges {
            try await appendMutation(
                kind: .mergeWorkspace,
                touchedPaths: Array(delta.touchedPaths).sorted(),
                fileChanges: delta.fileChanges,
                diff: delta.fileChanges.count == 1 ? delta.fileChanges[0].diff : nil
            )
        }

        let mergedSnapshot = try await captureSnapshot()
        return try await persistCheckpoint(
            snapshot: mergedSnapshot,
            label: label,
            parentCheckpointId: headCheckpointId,
            baseCheckpointId: baseCheckpointId,
            mergedFromWorkspaceId: other.workspaceId,
            mergedFromCheckpointId: incomingHead,
            rollbackSourceCheckpointId: nil,
            eventKind: .merged
        )
    }

    func seedBranchCheckpoint(
        snapshot: Snapshot,
        label: String?,
        baseCheckpointId: UUID?
    ) async throws -> Checkpoint {
        try await ensureLoaded()
        return try await persistCheckpoint(
            snapshot: snapshot,
            label: label,
            parentCheckpointId: nil,
            baseCheckpointId: baseCheckpointId,
            eventKind: .created,
            comparisonSnapshot: snapshot
        )
    }

    func mergeBaseCheckpointId() -> UUID? {
        baseCheckpointId
    }

    func mergeBaseMutationCursor() -> Int? {
        baseMutationCursor
    }

    func currentHeadCheckpointId() async throws -> UUID? {
        try await ensureLoaded()
        return headCheckpointId
    }
}
