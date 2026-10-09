import Foundation

extension Workspace {
    func acquireOperation() async {
        if operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            operationInProgress = true
        }
    }

    func releaseOperation() {
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    func restoreAfterFailure(_ before: [Snapshot], originalError: any Error) async throws -> Never {
        var rollbackError: (any Error)?
        for snapshot in before {
            do {
                try await Snapshot.restore(snapshot, to: filesystem)
            } catch {
                if rollbackError == nil { rollbackError = error }
            }
        }
        if let rollbackError {
            throw WorkspaceRollbackError(originalError: originalError, rollbackError: rollbackError)
        }
        throw originalError
    }

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

    func prepareForMutation() async throws {
        try await ensureLoaded()
        guard !didPrepareStore else { return }
        try await store.prepare(workspaceId: workspaceId)
        didPrepareStore = true
    }

    func loadStoreState() async throws {
        checkpoints = try await store.listCheckpoints(workspaceId: workspaceId)
        mutations = try await store.listMutations(workspaceId: workspaceId)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        didLoadStoreState = true
    }

    func reconcileCheckpointsWithStore() async throws {
        try await ensureLoaded()
        checkpoints = try await store.listCheckpoints(workspaceId: workspaceId).sorted(by: checkpointSort)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
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
        origin: Checkpoint.Origin
    ) async throws -> Checkpoint {
        let checkpoint = try await store.saveRevision(
            snapshot,
            draft: CheckpointDraft(
                workspaceID: workspaceId,
                label: label,
                preferredParentID: parentCheckpointId,
                origin: origin,
                mutationCursor: latestMutationSequence()
            )
        )
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        checkpoints.sort(by: checkpointSort)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        emitWorkspaceEvent(.checkpoint(checkpoint))
        return checkpoint
    }

    @discardableResult
    func appendMutation(operation: Mutation.Operation, changes: ChangeSet) async throws -> Mutation? {
        guard recording != .off else { return nil }
        let persisted = try await store.appendMutation(
            Mutation(sequence: 0, workspaceID: workspaceId, operation: operation, changes: changes)
        )
        mutations.append(persisted)
        mutations.sort { $0.sequence < $1.sequence }
        return persisted
    }

    // If checkpoint persistence fails after the history append, retract exactly
    // our record. Other instances' mutations must not be removed by compensation.
    func persistMutationCheckpoint(
        snapshot: Snapshot, label: String?, origin: Checkpoint.Origin,
        operation: Mutation.Operation, changes: ChangeSet
    ) async throws -> Checkpoint {
        let mutation = changes.isEmpty ? nil : try await appendMutation(operation: operation, changes: changes)
        do {
            return try await persistCheckpoint(
                snapshot: snapshot, label: label, parentCheckpointId: headCheckpointId, origin: origin
            )
        } catch {
            if let mutation {
                do {
                    try await store.removeMutation(sequence: mutation.sequence, workspaceId: workspaceId)
                    mutations.removeAll { $0.sequence == mutation.sequence }
                } catch let cleanupError {
                    throw WorkspaceRollbackError(originalError: error, rollbackError: cleanupError)
                }
            }
            throw error
        }
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

    func ensureCheckpointObservation() async {
        guard checkpointObservationTask == nil else { return }
        guard (try? await ensureLoaded()) != nil else { return }
        let store = store
        let workspaceID = workspaceId
        guard let stream = try? await store.changes(workspaceId: workspaceID) else { return }
        checkpointObservationTask = Task { [weak self] in
            for await _ in stream where !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                await self?.refreshCheckpointEvents()
            }
        }
    }

    func refreshCheckpointEvents() async {
        await acquireOperation()
        defer { releaseOperation() }
        guard eventWatchers.values.contains(where: { $0.filter.includeCheckpoints }) else { return }
        guard (try? await ensureLoaded()) != nil else { return }
        guard let stored = try? await store.listCheckpoints(workspaceId: workspaceId) else { return }

        let newCheckpoints = stored.filter { candidate in
            !checkpoints.contains(where: { $0.id == candidate.id })
        }
        checkpoints = stored.sorted(by: checkpointSort)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        if let refreshed = try? await store.listMutations(workspaceId: workspaceId) {
            mutations = refreshed.sorted { $0.sequence < $1.sequence }
        }
        for checkpoint in newCheckpoints.sorted(by: checkpointSort) {
            emitWorkspaceEvent(.checkpoint(checkpoint))
        }
    }

    func ensureFilesystemObservation() async {
        await acquireOperation()
        defer { releaseOperation() }
        guard filesystemObservationTask == nil,
              let source = filesystem as? any FileSystemChangeSource
        else { return }
        guard let stream = try? await source.changes(),
              let initial = try? await Snapshot.capture(from: source)
        else { return }
        observedFilesystemSnapshot = initial
        filesystemObservationTask = Task { [weak self] in
            for await _ in stream where !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                await self?.refreshFilesystemEvents()
            }
        }
    }

    func noteWorkspaceSnapshot(_ snapshot: Snapshot) {
        guard filesystemObservationTask != nil else { return }
        guard var observed = observedFilesystemSnapshot else { return }
        observed.entry = Snapshot.replacing(observed.entry, with: snapshot.entry)
        observedFilesystemSnapshot = observed
    }

    func refreshFilesystemEvents() async {
        await acquireOperation()
        defer { releaseOperation() }
        guard let before = observedFilesystemSnapshot,
              let after = try? await Snapshot.capture(from: filesystem)
        else { return }
        observedFilesystemSnapshot = after
        let changes = changeSet(from: before, to: after)
        if !changes.isEmpty { emitWorkspaceEvent(.changes(changes)) }
    }

    func checkpointSort(lhs: Checkpoint, rhs: Checkpoint) -> Bool {
        Checkpoint.orderedBefore(lhs, rhs)
    }
}
