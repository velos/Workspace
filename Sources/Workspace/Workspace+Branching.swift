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

    /// A path where the workspace and a branch changed the same entry in incompatible ways
    /// relative to their merge base.
    public struct MergeConflict: Sendable, Codable, Equatable {
        /// How the two sides disagree.
        public enum Kind: String, Sendable, Codable {
            /// Both sides modified the entry with different results.
            case bothModified
            /// One side modified the entry and the other deleted it.
            case modifiedAndDeleted
            /// Both sides created different entries at the same path.
            case bothCreated
        }

        /// The conflicting path.
        public var path: WorkspacePath
        /// The conflict classification.
        public var kind: Kind
        /// Diff from the base content to this workspace's content, when both sides are UTF-8 text.
        public var oursDiff: TextDiff?
        /// Diff from the base content to the branch's content, when both sides are UTF-8 text.
        public var theirsDiff: TextDiff?
    }

    /// The outcome of ``Workspace/mergeThreeWay(_:label:)``.
    public struct ThreeWayMergeResult: Sendable {
        /// The merge checkpoint, present when the merge applied cleanly.
        public let checkpoint: Checkpoint?
        /// The conflicts that prevented the merge; empty when `checkpoint` is present.
        public let conflicts: [MergeConflict]
        /// Whether the merge was applied to this workspace.
        public var applied: Bool { checkpoint != nil }
    }

    /// Merges a branch using per-path three-way resolution against the branch's base checkpoint.
    ///
    /// For every path, the side that changed relative to the base wins; identical changes on
    /// both sides merge cleanly. When both sides changed a path differently the merge applies
    /// nothing and returns the conflicts instead. Unlike ``merge(_:label:)``, this workspace may
    /// have advanced (checkpointed or not) since the branch was created.
    public func mergeThreeWay(_ other: Workspace, label: String? = nil) async throws -> ThreeWayMergeResult {
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()

        guard let baseCheckpointId = await other.mergeBaseCheckpointId() else {
            throw WorkspaceError.unsupported(
                "three-way merge requires a branch created from a checkpointed workspace"
            )
        }
        let baseCheckpoint = try checkpointOrThrow(id: baseCheckpointId)
        let baseSnapshot = try await loadSnapshotOrThrow(
            id: baseCheckpoint.snapshotId,
            workspaceId: baseCheckpoint.workspaceId
        )

        let oursSnapshot = try await captureSnapshot()
        let theirsSnapshot = try await other.captureSnapshot()
        let incomingHead = try await other.currentHeadCheckpointId()

        var base: [WorkspacePath: MergeNode] = [:]
        var ours: [WorkspacePath: MergeNode] = [:]
        var theirs: [WorkspacePath: MergeNode] = [:]
        Self.flattenMergeNodes(baseSnapshot.entry, into: &base)
        Self.flattenMergeNodes(oursSnapshot.entry, into: &ours)
        Self.flattenMergeNodes(theirsSnapshot.entry, into: &theirs)
        base.removeValue(forKey: .root)
        ours.removeValue(forKey: .root)
        theirs.removeValue(forKey: .root)

        var merged = ours
        var conflicts: [MergeConflict] = []
        let allPaths = Set(base.keys).union(ours.keys).union(theirs.keys).sorted()

        for path in allPaths {
            let baseNode = base[path]
            let oursNode = ours[path]
            let theirsNode = theirs[path]

            if theirsNode == baseNode || oursNode == theirsNode {
                continue // theirs unchanged, or both sides agree: keep ours.
            }
            if oursNode == baseNode {
                // Only theirs changed: take it.
                if let theirsNode {
                    merged[path] = theirsNode
                } else {
                    merged.removeValue(forKey: path)
                }
                continue
            }

            let kind: MergeConflict.Kind
            if baseNode == nil {
                kind = .bothCreated
            } else if oursNode == nil || theirsNode == nil {
                kind = .modifiedAndDeleted
            } else {
                kind = .bothModified
            }
            conflicts.append(
                MergeConflict(
                    path: path,
                    kind: kind,
                    oursDiff: Self.conflictDiff(from: baseNode, to: oursNode),
                    theirsDiff: Self.conflictDiff(from: baseNode, to: theirsNode)
                )
            )
        }

        guard conflicts.isEmpty else {
            return ThreeWayMergeResult(checkpoint: nil, conflicts: conflicts)
        }

        let rootPermissions: POSIXPermissions =
            if case let .directory(directory) = oursSnapshot.entry {
                directory.permissions
            } else {
                .defaultDirectory
            }
        let mergedSnapshot = Snapshot(
            rootPath: .root,
            entry: Self.buildEntryTree(from: merged, rootPermissions: rootPermissions)
        )

        try await untrackedRestore(mergedSnapshot)

        let delta = snapshotDelta(from: oursSnapshot.entry, to: mergedSnapshot.entry)
        if delta.hasChanges {
            try await appendMutation(
                kind: .mergeWorkspace,
                touchedPaths: Array(delta.touchedPaths).sorted(),
                fileChanges: delta.fileChanges,
                diff: delta.fileChanges.count == 1 ? delta.fileChanges[0].diff : nil
            )
        }

        let checkpoint = try await persistCheckpoint(
            snapshot: try await captureSnapshot(),
            label: label,
            parentCheckpointId: headCheckpointId,
            baseCheckpointId: self.baseCheckpointId,
            mergedFromWorkspaceId: other.workspaceId,
            mergedFromCheckpointId: incomingHead,
            rollbackSourceCheckpointId: nil,
            eventKind: .merged
        )
        return ThreeWayMergeResult(checkpoint: checkpoint, conflicts: [])
    }

    /// A comparable flat view of one snapshot entry, used for three-way resolution.
    struct MergeNode: Equatable {
        var kind: FileTree.Kind
        var permissions: POSIXPermissions
        var fileData: Data?
        var symlinkTarget: String?
    }

    static func flattenMergeNodes(_ entry: Snapshot.Entry, into nodes: inout [WorkspacePath: MergeNode]) {
        switch entry {
        case .missing:
            return
        case let .file(file):
            nodes[file.path] = MergeNode(kind: .file, permissions: file.permissions, fileData: file.data)
        case let .symlink(symlink):
            nodes[symlink.path] = MergeNode(
                kind: .symlink,
                permissions: symlink.permissions,
                symlinkTarget: symlink.target
            )
        case let .directory(directory):
            nodes[directory.path] = MergeNode(kind: .directory, permissions: directory.permissions)
            for child in directory.children {
                flattenMergeNodes(child, into: &nodes)
            }
        }
    }

    private static func conflictDiff(from base: MergeNode?, to side: MergeNode?) -> TextDiff? {
        let baseData = base.map { $0.fileData ?? Data() } ?? Data()
        let sideData = side.map { $0.fileData ?? Data() } ?? Data()
        guard let baseText = String(data: baseData, encoding: .utf8),
              let sideText = String(data: sideData, encoding: .utf8)
        else {
            return nil
        }
        let diff = TextDiff.lineBased(from: baseText, to: sideText)
        return diff.hunks.isEmpty ? nil : diff
    }

    /// Rebuilds a snapshot tree from a flat path-to-node map.
    static func buildEntryTree(
        from nodes: [WorkspacePath: MergeNode],
        rootPermissions: POSIXPermissions
    ) -> Snapshot.Entry {
        var childNames: [WorkspacePath: [String]] = [:]
        for path in nodes.keys {
            childNames[path.dirname, default: []].append(path.basename)
        }

        func subtree(at path: WorkspacePath, node: MergeNode?) -> Snapshot.Entry {
            let kind = node?.kind ?? .directory
            switch kind {
            case .file:
                return .file(
                    Snapshot.File(
                        path: path,
                        data: node?.fileData ?? Data(),
                        permissions: node?.permissions ?? POSIXPermissions(0o644)
                    )
                )
            case .symlink:
                return .symlink(
                    Snapshot.Symlink(
                        path: path,
                        target: node?.symlinkTarget ?? "",
                        permissions: node?.permissions ?? POSIXPermissions(0o777)
                    )
                )
            case .directory:
                let children = (childNames[path] ?? [])
                    .sorted()
                    .map { name -> Snapshot.Entry in
                        let childPath = path.appending(name)
                        return subtree(at: childPath, node: nodes[childPath])
                    }
                return .directory(
                    Snapshot.Directory(
                        path: path,
                        permissions: node?.permissions ?? POSIXPermissions(0o755),
                        children: children
                    )
                )
            }
        }

        return subtree(at: .root, node: MergeNode(kind: .directory, permissions: rootPermissions))
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
