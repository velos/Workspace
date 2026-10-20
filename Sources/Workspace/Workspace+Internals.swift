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

    func restoreAfterFailure(_ before: [Snapshot], originalError: any Error, restoringSymlinkPermissions: Bool = false) async throws -> Never {
        var rollbackError: (any Error)?
        for snapshot in before {
            do {
                try await Snapshot.restore(snapshot, to: filesystem)
                if restoringSymlinkPermissions { try await restoreTransactionSymlinkPermissions(snapshot.entry) }
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
        let page = try await store.listMutations(workspaceId: workspaceId, afterSequence: 0)
        mutations = page.records
        historyRefreshSequence = mutations.last?.sequence ?? 0
        historyRetractionEpoch = page.retractionEpoch
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
                origin: origin
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
        cachePersistedMutations([persisted])
        if persisted.sequence == historyRefreshSequence + 1 {
            historyRefreshSequence = persisted.sequence
        }
        return persisted
    }

    func persistMutationCheckpoint(
        snapshot: Snapshot, label: String?, origin: Checkpoint.Origin,
        operation: Mutation.Operation, changes: ChangeSet
    ) async throws -> Checkpoint {
        try await withMutationCheckpoint(operation: operation, changes: changes) {
            try await persistCheckpoint(
                snapshot: snapshot, label: label, parentCheckpointId: headCheckpointId, origin: origin
            )
        }
    }

    // If checkpoint persistence fails after the history append, retract exactly
    // our record. Other instances' mutations must not be removed by compensation.
    func withMutationCheckpoint(
        operation: Mutation.Operation, changes: ChangeSet,
        publish: () async throws -> Checkpoint
    ) async throws -> Checkpoint {
        let mutation = changes.isEmpty ? nil : try await appendMutation(operation: operation, changes: changes)
        do {
            return try await publish()
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
        // Existing checkpoints are the subscription baseline. Query-cache refreshes after
        // this point must not acknowledge event delivery.
        deliveredCheckpointEventIDs.formUnion(checkpoints.map(\.id))
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
            !deliveredCheckpointEventIDs.contains(candidate.id)
        }
        checkpoints = stored.sorted(by: checkpointSort)
        headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
        try? await refreshPersistedHistory()
        for checkpoint in newCheckpoints.sorted(by: checkpointSort) {
            // Re-check after suspension: a local commit or another refresh may have delivered it.
            if !deliveredCheckpointEventIDs.contains(checkpoint.id) {
                emitWorkspaceEvent(.checkpoint(checkpoint))
            }
        }
        deliveredCheckpointEventIDs.formIntersection(checkpoints.map(\.id))
    }

    func ensureFilesystemObservation() async {
        await acquireOperation()
        defer { releaseOperation() }
        guard filesystemObservationTask == nil,
              let source = filesystem as? any FileSystemChangeSource
        else { return }
        guard let stream = try? await source.changeSignals(),
              let initial = try? await FilesystemObservation.start(on: filesystem, budget: observation.contentCacheBytes)
        else { return }
        observedFilesystem = initial
        filesystemObservationTask = Task { [weak self] in
            for await signal in stream where !Task.isCancelled {
                await self?.enqueueFilesystemSignal(signal)
            }
        }
    }

    func enqueueFilesystemSignal(_ signal: FileSystemChangeSignal, retry: Bool = false) {
        guard filesystemObservationTask != nil else { return }
        if !retry {
            filesystemRefreshFailures = 0
            filesystemRetryMilliseconds = 40
        }
        switch (pendingFilesystemSignal, signal) {
        case (.rescan, _), (_, .rescan): pendingFilesystemSignal = .rescan
        case let (.paths(old), .paths(new)): pendingFilesystemSignal = .paths(old.merging(new, uniquingKeysWith: max))
        case (nil, _): pendingFilesystemSignal = signal
        }
        guard filesystemRefreshTask == nil, filesystemRefreshFailures < 3 else { return }
        let delay = filesystemRetryMilliseconds
        filesystemRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            await self?.refreshFilesystemEvents()
        }
    }

    func noteWorkspaceSnapshot(_ snapshot: Snapshot) async {
        guard var observed = observedFilesystem else { return }
        observedFilesystem = nil
        // No content reads: the edit journal already holds the after image. This
        // reconciliation is not atomic with external writers; README documents the
        // window between the journal's write and this metadata capture.
        guard let metadata = try? await MetadataIndex.capture(from: filesystem, at: snapshot.rootPath) else {
            if filesystemObservationTask != nil { observedFilesystem = observed }
            return
        }
        observed.replace(root: snapshot.rootPath, metadata: metadata)
        observed.remember(snapshot.entry)
        if filesystemObservationTask != nil { observedFilesystem = observed }
    }

    func refreshFilesystemEvents() async {
        await acquireOperation()
        defer { releaseOperation() }
        let signal = pendingFilesystemSignal ?? .rescan
        pendingFilesystemSignal = nil
        guard var observed = observedFilesystem else {
            filesystemRefreshTask = nil
            return
        }
        observedFilesystem = nil
        do {
            let changes = try await observed.refresh(on: filesystem, signal: signal)
            filesystemRetryMilliseconds = 40
            filesystemRefreshFailures = 0
            if filesystemObservationTask != nil {
                observedFilesystem = observed
                if !changes.isEmpty { emitWorkspaceEvent(.changes(changes)) }
            }
        } catch {
            if filesystemObservationTask != nil {
                observedFilesystem = observed
                // Keep the consumed invalidation alongside signals received during the read.
                // Bound automatic attempts; a new native signal restarts the retry budget.
                filesystemRefreshFailures += 1
                filesystemRetryMilliseconds = min(1_000, filesystemRetryMilliseconds * 2)
                enqueueFilesystemSignal(signal, retry: true)
            }
        }
        filesystemRefreshTask = nil
        if let pending = pendingFilesystemSignal { enqueueFilesystemSignal(pending, retry: true) }
    }

    func checkpointSort(lhs: Checkpoint, rhs: Checkpoint) -> Bool {
        Checkpoint.orderedBefore(lhs, rhs)
    }
}
