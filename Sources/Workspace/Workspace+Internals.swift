import Foundation

extension Workspace {
    struct SnapshotDelta {
        var touchedPaths: Set<WorkspacePath> = []
        var fileChanges: [FileEdit.FileChange] = []

        var hasChanges: Bool {
            !touchedPaths.isEmpty || !fileChanges.isEmpty
        }
    }

    func ensureLoaded() async throws {
        if didLoadStoreState {
            return
        }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task<Void, Error> {
            try await self.loadStoreState()
        }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    func loadStoreState() async throws {
        checkpoints = try await store.listCheckpoints(workspaceId: workspaceId)
        mutations = try await store.listMutationRecords(workspaceId: workspaceId)
        nextMutationSequence = (mutations.map(\.sequence).max() ?? 0) + 1
        headCheckpointId = Self.lineageHeadId(in: checkpoints)
        didLoadStoreState = true
    }

    /// Merges in-memory checkpoint state with the shared store, then recomputes the head from the
    /// parent chain (leaves) instead of wall-clock order alone, so a remote checkpoint does not
    /// silently reorder lineage when `createdAt` is skewed.
    func reconcileCheckpointsWithStore() async throws {
        try await ensureLoaded()
        let fromStore = try await store.listCheckpoints(workspaceId: workspaceId)
        checkpoints = fromStore.sorted(by: checkpointSort)
        headCheckpointId = Self.lineageHeadId(in: checkpoints)
    }

    /// Picks the current checkpoint "tip": checkpoints whose ids never appear as
    /// ``Checkpoint/parentCheckpointId`` (DAG leaves). If the graph is forked, the leaf with the
    /// latest `(createdAt, id)` is used.
    static func lineageHeadId(in checkpoints: [Checkpoint]) -> UUID? {
        guard !checkpoints.isEmpty else {
            return nil
        }
        let parentReferences = Set(checkpoints.compactMap(\.parentCheckpointId))
        let tips = checkpoints.filter { !parentReferences.contains($0.id) }
        if tips.isEmpty {
            return checkpoints.max(by: orderCheckpoints)?.id
        }
        if tips.count == 1 {
            return tips[0].id
        }
        return tips.max(by: orderCheckpoints)?.id
    }

    private static func orderCheckpoints(_ lhs: Checkpoint, _ rhs: Checkpoint) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    func checkpointOrThrow(id: UUID) throws -> Checkpoint {
        guard let checkpoint = checkpoints.first(where: { $0.id == id }) else {
            throw WorkspaceError.checkpointNotFound(id)
        }
        return checkpoint
    }

    func loadSnapshotOrThrow(id: UUID, workspaceId: UUID? = nil) async throws -> Snapshot {
        let ownerWorkspaceId = workspaceId ?? self.workspaceId
        guard let snapshot = try await store.loadSnapshot(id: id, workspaceId: ownerWorkspaceId) else {
            throw WorkspaceError.snapshotNotFound(id)
        }
        return snapshot
    }

    func performDirectEdit(
        kind: MutationRecord.Kind,
        edit: FileEdit,
        apply: () async throws -> Void
    ) async throws {
        if case .disabled = tracking {
            try await apply()
            return
        }

        try await ensureLoaded()
        let preview = try await previewEdits([edit])
        try await apply()

        let appliedFileChanges = markApplied(preview.edits.first?.fileChanges ?? [])
        try await appendMutation(
            kind: kind,
            touchedPaths: preview.touchedPaths,
            fileChanges: appliedFileChanges,
            diff: appliedFileChanges.count == 1 ? appliedFileChanges[0].diff : nil
        )
    }

    func performBinaryWrite(data: Data, path: WorkspacePath) async throws {
        if case .disabled = tracking {
            try await untrackedWriteData(data, to: path)
            return
        }

        let effect: FileEdit.Effect
        let kind: FileTree.Kind

        if await exists(path) {
            let info = try await fileInfo(at: path)
            if info.kind == .directory {
                throw WorkspaceError.unsupported("cannot write data to a directory: \(path)")
            }
            kind = info.kind
            if computesDiffs {
                effect = try await readData(from: path) == data ? .unchanged : .modified
            } else {
                effect = .modified
            }
        } else {
            kind = .file
            effect = .created
        }

        try await untrackedWriteData(data, to: path)
        try await appendMutation(
            kind: .writeData,
            touchedPaths: [path],
            fileChanges: [
                FileEdit.FileChange(
                    path: path,
                    kind: kind,
                    effect: effect,
                    status: .applied,
                    diff: nil
                ),
            ],
            diff: nil
        )
    }

    func persistCheckpoint(
        snapshot: Snapshot,
        label: String?,
        parentCheckpointId: UUID?,
        baseCheckpointId: UUID?,
        mergedFromWorkspaceId: UUID? = nil,
        mergedFromCheckpointId: UUID? = nil,
        rollbackSourceCheckpointId: UUID? = nil,
        eventKind: CheckpointEvent.Kind,
        comparisonSnapshot: Snapshot? = nil
    ) async throws -> Checkpoint {
        try await store.saveSnapshot(snapshot, workspaceId: workspaceId)

        let parentCheckpoint = parentCheckpointId.flatMap { id in
            checkpoints.first(where: { $0.id == id })
        }

        let previousSnapshot: Snapshot?
        if let comparisonSnapshot {
            previousSnapshot = comparisonSnapshot
        } else if let parentCheckpoint {
            previousSnapshot = try? await store.loadSnapshot(id: parentCheckpoint.snapshotId, workspaceId: workspaceId)
        } else {
            previousSnapshot = nil
        }
        let summary = snapshot.summary(comparedTo: previousSnapshot)

        let previousCursor = parentCheckpoint?.mutationCursor ?? 0
        let currentCursor = latestMutationSequence()
        let checkpoint = Checkpoint(
            workspaceId: workspaceId,
            label: label,
            parentCheckpointId: parentCheckpointId,
            baseCheckpointId: baseCheckpointId,
            mergedFromWorkspaceId: mergedFromWorkspaceId,
            mergedFromCheckpointId: mergedFromCheckpointId,
            rollbackSourceCheckpointId: rollbackSourceCheckpointId,
            firstMutationSequence: currentCursor > previousCursor ? previousCursor + 1 : nil,
            lastMutationSequence: currentCursor > previousCursor ? currentCursor : nil,
            mutationCursor: currentCursor,
            snapshotId: snapshot.id,
            summary: summary
        )

        try await store.saveCheckpoint(checkpoint)

        checkpoints.append(checkpoint)
        checkpoints.sort(by: checkpointSort)
        headCheckpointId = checkpoint.id

        emitCheckpointEvent(CheckpointEvent(kind: eventKind, checkpoint: checkpoint))
        return checkpoint
    }

    func appendMutation(
        kind: MutationRecord.Kind,
        touchedPaths: [WorkspacePath],
        fileChanges: [FileEdit.FileChange],
        diff: TextDiff?
    ) async throws {
        if case .disabled = tracking {
            return
        }
        let provisional = MutationRecord(
            sequence: 0,
            workspaceId: workspaceId,
            kind: kind,
            touchedPaths: Array(Set(touchedPaths)).sorted(),
            fileChanges: fileChanges.sorted(by: fileChangeSort),
            diff: diff
        )
        let persisted = try await store.appendMutation(provisional)
        mutations.append(persisted)
        mutations.sort { $0.sequence < $1.sequence }
        nextMutationSequence = (mutations.map(\.sequence).max() ?? 0) + 1
    }

    func latestMutationSequence() -> Int {
        mutations.map(\.sequence).max() ?? 0
    }

    /// Returns the tracked mutation history for this workspace, oldest first.
    ///
    /// The amount of detail per record is governed by the workspace's ``Workspace/TrackingPolicy``;
    /// with ``Workspace/TrackingPolicy/disabled`` the history is empty.
    public func mutationRecords() async throws -> [MutationRecord] {
        try await ensureLoaded()
        return mutations
    }

    /// Encodes `value` to bytes and a UTF-8 `String` with a **single trailing newline** for
    /// line-oriented / POSIX-friendly file endings. Decoding via ``Workspace/readJSON(from:)``
    /// still works because the JSON comes first; keep this in mind if you read raw bytes with a
    /// different decoder.
    func encodedJSONString<T: Encodable>(for value: T, prettyPrinted: Bool) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.mutationFailed("encoded JSON is not valid UTF-8")
        }
        return string
    }

    func markApplied(_ fileChanges: [FileEdit.FileChange]) -> [FileEdit.FileChange] {
        fileChanges.map { change in
            var copy = change
            copy.status = .applied
            return copy
        }
    }

    func untrackedRestore(_ snapshot: Snapshot) async throws {
        try await Snapshot.restore(snapshot, to: filesystem)
    }

    func removeCheckpointWatcher(id: UUID) {
        checkpointWatchers.removeValue(forKey: id)
        if checkpointWatchers.isEmpty {
            checkpointPollingTask?.cancel()
            checkpointPollingTask = nil
        }
    }

    func ensureCheckpointPolling() {
        guard checkpointPollingTask == nil else {
            return
        }
        checkpointPollingTask = Task { [weak self] in
            while !Task.isCancelled, let workspace = self {
                let interval = await workspace.checkpointEventPollInterval
                try? await Task.sleep(for: interval)
                await workspace.pollCheckpointEvents()
            }
        }
    }

    func pollCheckpointEvents() async {
        guard !checkpointWatchers.isEmpty else {
            return
        }
        guard let loaded = try? await store.listCheckpoints(workspaceId: workspaceId) else {
            return
        }

        let newCheckpoints = loaded.filter { cp in
            !checkpoints.contains(where: { $0.id == cp.id })
        }

        if !newCheckpoints.isEmpty {
            checkpoints.append(contentsOf: newCheckpoints)
            checkpoints.sort(by: checkpointSort)
            headCheckpointId = Self.lineageHeadId(in: checkpoints)

            if let refreshedMutations = try? await store.listMutationRecords(workspaceId: workspaceId) {
                mutations = refreshedMutations.sorted { $0.sequence < $1.sequence }
                nextMutationSequence = (mutations.map(\.sequence).max() ?? 0) + 1
            }
        }

        for checkpoint in newCheckpoints.sorted(by: checkpointSort) {
            emitCheckpointEvent(CheckpointEvent(kind: checkpoint.inferredEventKind, checkpoint: checkpoint))
        }
    }

    func emitCheckpointEvent(_ event: CheckpointEvent) {
        guard !checkpointWatchers.isEmpty else {
            return
        }

        for id in Array(checkpointWatchers.keys) {
            guard var watcher = checkpointWatchers[id] else {
                continue
            }
            guard watcher.deliveredCheckpointIds.insert(event.checkpoint.id).inserted else {
                continue
            }
            watcher.continuation.yield(event)
            checkpointWatchers[id] = watcher
        }
    }

    func snapshotDelta(from original: Snapshot.Entry, to updated: Snapshot.Entry) -> SnapshotDelta {
        var delta = SnapshotDelta()
        collectDelta(from: original, to: updated, into: &delta)
        delta.fileChanges.sort(by: fileChangeSort)
        return delta
    }

    func collectDelta(
        from original: Snapshot.Entry,
        to updated: Snapshot.Entry,
        into delta: inout SnapshotDelta
    ) {
        switch (original, updated) {
        case (.missing, .missing):
            return
        case (.missing, _):
            collectCreated(updated, into: &delta)
        case (_, .missing):
            collectDeleted(original, into: &delta)
        case let (.file(lhs), .file(rhs)):
            if lhs.data != rhs.data || lhs.permissions != rhs.permissions {
                delta.touchedPaths.insert(rhs.path)
                let diff = lhs.data != rhs.data ? utf8TextFileDiff(oldData: lhs.data, newData: rhs.data) : nil
                delta.fileChanges.append(
                    FileEdit.FileChange(
                        path: rhs.path,
                        kind: .file,
                        effect: .modified,
                        status: .applied,
                        diff: diff
                    )
                )
            }
        case let (.symlink(lhs), .symlink(rhs)):
            if lhs.target != rhs.target || lhs.permissions != rhs.permissions {
                delta.touchedPaths.insert(rhs.path)
                delta.fileChanges.append(
                    FileEdit.FileChange(
                        path: rhs.path,
                        kind: .symlink,
                        effect: .modified,
                        status: .applied,
                        diff: nil
                    )
                )
            }
        case let (.directory(lhs), .directory(rhs)):
            if lhs.permissions != rhs.permissions {
                delta.touchedPaths.insert(rhs.path)
            }

            let lhsChildren = Dictionary(uniqueKeysWithValues: lhs.children.map { ($0.path.basename, $0) })
            let rhsChildren = Dictionary(uniqueKeysWithValues: rhs.children.map { ($0.path.basename, $0) })
            let names = Set(lhsChildren.keys).union(rhsChildren.keys).sorted()

            for name in names {
                switch (lhsChildren[name], rhsChildren[name]) {
                case let (lhs?, rhs?):
                    collectDelta(from: lhs, to: rhs, into: &delta)
                case let (lhs?, nil):
                    collectDeleted(lhs, into: &delta)
                case let (nil, rhs?):
                    collectCreated(rhs, into: &delta)
                case (nil, nil):
                    break
                }
            }
        default:
            collectDeleted(original, into: &delta)
            collectCreated(updated, into: &delta)
        }
    }

    func collectCreated(_ entry: Snapshot.Entry, into delta: inout SnapshotDelta) {
        switch entry {
        case let .missing(entry):
            delta.touchedPaths.insert(entry.path)
        case let .file(entry):
            delta.touchedPaths.insert(entry.path)
            delta.fileChanges.append(
                FileEdit.FileChange(
                    path: entry.path,
                    kind: .file,
                    effect: .created,
                    status: .applied,
                    diff: utf8TextFileDiff(oldData: Data(), newData: entry.data)
                )
            )
        case let .directory(entry):
            delta.touchedPaths.insert(entry.path)
            for child in entry.children {
                collectCreated(child, into: &delta)
            }
        case let .symlink(entry):
            delta.touchedPaths.insert(entry.path)
            delta.fileChanges.append(
                FileEdit.FileChange(
                    path: entry.path,
                    kind: .symlink,
                    effect: .created,
                    status: .applied,
                    diff: nil
                )
            )
        }
    }

    func collectDeleted(_ entry: Snapshot.Entry, into delta: inout SnapshotDelta) {
        switch entry {
        case let .missing(entry):
            delta.touchedPaths.insert(entry.path)
        case let .file(entry):
            delta.touchedPaths.insert(entry.path)
            delta.fileChanges.append(
                FileEdit.FileChange(
                    path: entry.path,
                    kind: .file,
                    effect: .deleted,
                    status: .applied,
                    diff: utf8TextFileDiff(oldData: entry.data, newData: Data())
                )
            )
        case let .directory(entry):
            delta.touchedPaths.insert(entry.path)
            for child in entry.children {
                collectDeleted(child, into: &delta)
            }
        case let .symlink(entry):
            delta.touchedPaths.insert(entry.path)
            delta.fileChanges.append(
                FileEdit.FileChange(
                    path: entry.path,
                    kind: .symlink,
                    effect: .deleted,
                    status: .applied,
                    diff: nil
                )
            )
        }
    }

    func utf8TextFileDiff(oldData: Data, newData: Data) -> TextDiff? {
        guard case let .fullDiffs(maxDiffBytes) = tracking else {
            return nil
        }
        if let maxDiffBytes, oldData.count > maxDiffBytes || newData.count > maxDiffBytes {
            return nil
        }
        guard let oldString = String(data: oldData, encoding: .utf8),
              let newString = String(data: newData, encoding: .utf8)
        else {
            return nil
        }
        let diff = TextDiff.lineBased(from: oldString, to: newString)
        return diff.hunks.isEmpty ? nil : diff
    }

    func checkpointSort(lhs: Checkpoint, rhs: Checkpoint) -> Bool {
        Self.orderCheckpoints(lhs, rhs)
    }

    func fileChangeSort(lhs: FileEdit.FileChange, rhs: FileEdit.FileChange) -> Bool {
        if lhs.path == rhs.path {
            return lhs.effect.rawValue < rhs.effect.rawValue
        }
        return lhs.path < rhs.path
    }
}
