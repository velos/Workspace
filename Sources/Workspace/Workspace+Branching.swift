import Foundation

extension Workspace {
    /// Creates an isolated branch workspace from the current filesystem state.
    ///
    /// Branches share only the checkpoint store with their parent. Filesystem state, watchers, and mutation
    /// sequences are isolated to the returned workspace.
    public func branch(label: String? = nil) async throws -> Workspace {
        try await ensureLoaded()

        let baseCheckpointId = headCheckpointId
        let snapshot = try await captureSnapshot()
        let branchFilesystem = InMemoryFilesystem()
        try await Snapshot.restore(snapshot, to: branchFilesystem)

        let branch = Workspace(
            workspaceId: UUID(),
            filesystem: branchFilesystem,
            store: store,
            baseCheckpointId: baseCheckpointId
        )
        _ = try await branch.seedBranchCheckpoint(
            snapshot: snapshot,
            label: label,
            baseCheckpointId: baseCheckpointId
        )
        return branch
    }

    /// Merges another workspace into this workspace when this workspace still points at the other's base.
    public func merge(_ other: Workspace, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()

        let expectedBase = await other.mergeBaseCheckpointId()
        guard headCheckpointId == expectedBase else {
            throw WorkspaceError.mergeConflict(
                parentWorkspaceId: workspaceId,
                expectedBase: expectedBase,
                actualHead: headCheckpointId
            )
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

    func currentHeadCheckpointId() async throws -> UUID? {
        try await ensureLoaded()
        return headCheckpointId
    }
}
