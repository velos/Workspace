import Foundation

extension Workspace {
    func ensureLoaded() async throws {
        if didLoadStoreState { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task<Void, Error> { try await self.loadStoreState() }
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
        mutations = try await store.listMutations(workspaceId: workspaceId)
        headCheckpointId = Self.lineageHeadId(in: checkpoints)
        didLoadStoreState = true
    }

    func reconcileCheckpointsWithStore() async throws {
        try await ensureLoaded()
        checkpoints = try await store.listCheckpoints(workspaceId: workspaceId).sorted(by: checkpointSort)
        headCheckpointId = Self.lineageHeadId(in: checkpoints)
    }

    static func lineageHeadId(in checkpoints: [Checkpoint]) -> UUID? {
        guard !checkpoints.isEmpty else { return nil }
        let referencedParents = Set(checkpoints.compactMap(\.parentID))
        let tips = checkpoints.filter { !referencedParents.contains($0.id) }
        return (tips.isEmpty ? checkpoints : tips).max(by: orderCheckpoints)?.id
    }

    static func orderCheckpoints(_ lhs: Checkpoint, _ rhs: Checkpoint) -> Bool {
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
        let owner = workspaceId ?? self.workspaceId
        guard let snapshot = try await store.loadSnapshot(id: id, workspaceId: owner) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        return snapshot
    }

    func persistCheckpoint(
        snapshot: Snapshot,
        label: String?,
        parentCheckpointId: UUID?,
        origin: Checkpoint.Origin,
        comparisonSnapshot: Snapshot? = nil
    ) async throws -> Checkpoint {
        try await store.saveSnapshot(snapshot, workspaceId: workspaceId)

        let parent = parentCheckpointId.flatMap { id in checkpoints.first(where: { $0.id == id }) }
        let previous: Snapshot?
        if let comparisonSnapshot {
            previous = comparisonSnapshot
        } else if let parent {
            previous = try? await store.loadSnapshot(id: parent.snapshotId, workspaceId: workspaceId)
        } else {
            previous = nil
        }
        let baseline = previous ?? Snapshot(
            rootPath: snapshot.rootPath,
            entry: .missing(.init(path: snapshot.rootPath))
        )
        let summary = ChangeSet.compare(
            before: baseline,
            after: snapshot,
            maxTextBytes: 1_000_000
        ).summary

        let previousCursor = parent?.mutationCursor ?? 0
        let currentCursor = latestMutationSequence()
        let checkpoint = Checkpoint(
            workspaceId: workspaceId,
            label: label,
            parentCheckpointId: parentCheckpointId,
            origin: origin,
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
        emitWorkspaceEvent(.checkpoint(checkpoint))
        return checkpoint
    }

    func appendMutation(operation: Mutation.Operation, changes: ChangeSet) async throws {
        guard recording != .off else { return }
        let persisted = try await store.appendMutation(
            Mutation(sequence: 0, workspaceID: workspaceId, operation: operation, changes: changes)
        )
        mutations.append(persisted)
        mutations.sort { $0.sequence < $1.sequence }
    }

    func latestMutationSequence() -> Int {
        mutations.last?.sequence ?? 0
    }

    func encodedJSONString<T: Encodable>(for value: T, prettyPrinted: Bool) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.mutationFailed("encoded JSON is not valid UTF-8")
        }
        return string
    }

    func ensureCheckpointPolling() {
        guard checkpointPollingTask == nil else { return }
        checkpointPollingTask = Task { [weak self] in
            while !Task.isCancelled, let workspace = self {
                let interval = await workspace.checkpointEventPollInterval
                try? await Task.sleep(for: interval)
                await workspace.pollCheckpointEvents()
            }
        }
    }

    func pollCheckpointEvents() async {
        guard eventWatchers.values.contains(where: { $0.filter.includeCheckpoints }) else { return }
        guard (try? await ensureLoaded()) != nil else { return }
        guard let stored = try? await store.listCheckpoints(workspaceId: workspaceId) else { return }

        let newCheckpoints = stored.filter { candidate in
            !checkpoints.contains(where: { $0.id == candidate.id })
        }
        guard !newCheckpoints.isEmpty else { return }

        checkpoints.append(contentsOf: newCheckpoints)
        checkpoints.sort(by: checkpointSort)
        headCheckpointId = Self.lineageHeadId(in: checkpoints)
        if let refreshed = try? await store.listMutations(workspaceId: workspaceId) {
            mutations = refreshed.sorted { $0.sequence < $1.sequence }
        }
        for checkpoint in newCheckpoints.sorted(by: checkpointSort) {
            emitWorkspaceEvent(.checkpoint(checkpoint))
        }
    }

    func checkpointSort(lhs: Checkpoint, rhs: Checkpoint) -> Bool {
        Self.orderCheckpoints(lhs, rhs)
    }
}
