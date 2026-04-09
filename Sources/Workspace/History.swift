import Foundation

/// Coordinates shared history, session overlays, checkpoints, rollback, and publish.
public actor History {
    private struct SessionState {
        var workspace: Workspace
        var baseSharedCheckpointId: UUID?
        var lastCheckpointId: UUID?
    }

    private struct EventWatcher {
        var workspaceId: UUID
        var continuation: AsyncStream<CheckpointEvent>.Continuation
    }

    private struct SnapshotDelta {
        var touchedPaths: Set<WorkspacePath> = []
        var fileChanges: [FileEdit.FileChange] = []

        var hasChanges: Bool {
            !touchedPaths.isEmpty || !fileChanges.isEmpty
        }
    }

    public let workspaceId: UUID

    private let sharedWorkspace: Workspace
    private let store: any CheckpointStore

    private var didLoadStoreState = false
    private var sessions: [UUID: SessionState] = [:]
    private var checkpoints: [Checkpoint] = []
    private var mutations: [MutationRecord] = []
    private var sharedHeadCheckpointId: UUID?
    private var nextMutationSequence = 1
    private var eventWatchers: [UUID: EventWatcher] = [:]

    /// Creates a history coordinator over `filesystem`.
    public init(
        workspaceId: UUID = UUID(),
        filesystem: any FileSystem,
        historyDirectory: URL
    ) {
        self.workspaceId = workspaceId
        sharedWorkspace = Workspace(filesystem: filesystem)
        store = FileCheckpointStore(rootDirectory: historyDirectory)
    }

    /// Creates a history coordinator over an existing shared workspace.
    public init(
        workspaceId: UUID = UUID(),
        workspace: Workspace,
        historyDirectory: URL
    ) {
        self.workspaceId = workspaceId
        sharedWorkspace = workspace
        store = FileCheckpointStore(rootDirectory: historyDirectory)
    }

    init(
        workspaceId: UUID = UUID(),
        filesystem: any FileSystem,
        store: any CheckpointStore
    ) {
        self.workspaceId = workspaceId
        sharedWorkspace = Workspace(filesystem: filesystem)
        self.store = store
    }

    init(
        workspaceId: UUID = UUID(),
        workspace: Workspace,
        store: any CheckpointStore
    ) {
        self.workspaceId = workspaceId
        sharedWorkspace = workspace
        self.store = store
    }

    /// Reads raw data from the shared workspace.
    public func readData(from path: WorkspacePath) async throws -> Data {
        try await ensureLoaded()
        return try await sharedWorkspace.readData(from: path)
    }

    /// Reads UTF-8 text from the shared workspace.
    public func readFile(_ path: WorkspacePath) async throws -> String {
        try await ensureLoaded()
        return try await sharedWorkspace.readFile(path)
    }

    /// Reads JSON from the shared workspace.
    public func readJSON<T: Decodable & Sendable>(_ type: T.Type = T.self, from path: WorkspacePath) async throws -> T {
        try await ensureLoaded()
        return try await sharedWorkspace.readJSON(type, from: path)
    }

    /// Returns whether an entry exists in the shared workspace.
    public func exists(_ path: WorkspacePath) async throws -> Bool {
        try await ensureLoaded()
        return await sharedWorkspace.exists(path)
    }

    /// Returns shared workspace metadata.
    public func fileInfo(at path: WorkspacePath) async throws -> FileInfo {
        try await ensureLoaded()
        return try await sharedWorkspace.fileInfo(at: path)
    }

    /// Lists a shared workspace directory.
    public func listDirectory(at path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await ensureLoaded()
        return try await sharedWorkspace.listDirectory(at: path)
    }

    /// Expands a glob against the shared workspace.
    public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
        try await ensureLoaded()
        return try await sharedWorkspace.glob(pattern, currentDirectory: currentDirectory)
    }

    /// Walks the shared workspace tree.
    public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTree {
        try await ensureLoaded()
        return try await sharedWorkspace.walkTree(path, maxDepth: maxDepth)
    }

    /// Summarizes the shared workspace tree.
    public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTreeSummary {
        try await ensureLoaded()
        return try await sharedWorkspace.summarizeTree(path, maxDepth: maxDepth)
    }

    /// Watches shared workspace filesystem changes.
    public func watchChanges(at path: WorkspacePath, recursive: Bool = true) async throws -> AsyncStream<ChangeEvent> {
        try await ensureLoaded()
        return await sharedWorkspace.watchChanges(at: path, recursive: recursive)
    }

    /// Watches durable checkpoint events for `workspaceId`.
    func watchCheckpointEvents(workspaceId: UUID) async throws -> AsyncStream<CheckpointEvent> {
        try await ensureLoaded()

        guard workspaceId == self.workspaceId else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        let watcherId = UUID()
        var continuation: AsyncStream<CheckpointEvent>.Continuation?
        let stream = AsyncStream<CheckpointEvent> {
            continuation = $0
        }

        guard let continuation else {
            return stream
        }

        eventWatchers[watcherId] = EventWatcher(workspaceId: workspaceId, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEventWatcher(id: watcherId)
            }
        }
        return stream
    }

    /// Creates a tracked session overlay from the current shared head.
    public func createSession() async throws -> Session {
        try await ensureLoaded()

        let sessionId = UUID()
        let snapshot = try await sharedWorkspace.captureSnapshot()
        let overlay = InMemoryFilesystem()
        let sessionWorkspace = Workspace(filesystem: overlay)
        try await sessionWorkspace.restoreSnapshot(snapshot)

        sessions[sessionId] = SessionState(
            workspace: sessionWorkspace,
            baseSharedCheckpointId: sharedHeadCheckpointId,
            lastCheckpointId: nil
        )

        return Session(
            id: sessionId,
            workspaceId: workspaceId,
            workspace: sessionWorkspace,
            history: self
        )
    }

    /// Writes UTF-8 text to the shared workspace.
    public func writeFile(_ path: WorkspacePath, content: String) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .writeFile,
            edit: .writeFile(path: path, content: content)
        ) { workspace in
            try await workspace.writeFile(path, content: content)
        }
    }

    /// Appends UTF-8 text to a shared workspace file.
    public func appendFile(_ path: WorkspacePath, content: String) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .appendFile,
            edit: .appendFile(path: path, content: content)
        ) { workspace in
            try await workspace.appendFile(path, content: content)
        }
    }

    /// Writes raw data to the shared workspace.
    public func writeData(_ data: Data, to path: WorkspacePath) async throws {
        try await ensureLoaded()
        try await performBinaryWrite(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            data: data,
            path: path
        )
    }

    /// Encodes JSON and writes it to the shared workspace.
    public func writeJSON<T: Encodable & Sendable>(
        _ value: T,
        to path: WorkspacePath,
        prettyPrinted: Bool = true
    ) async throws {
        try await ensureLoaded()
        let content = try encodedJSONString(for: value, prettyPrinted: prettyPrinted)
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .writeJSON,
            edit: .writeFile(path: path, content: content)
        ) { workspace in
            try await workspace.writeFile(path, content: content)
        }
    }

    /// Creates a directory in the shared workspace.
    public func createDirectory(at path: WorkspacePath, recursive: Bool = true) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .createDirectory,
            edit: .createDirectory(path: path, recursive: recursive)
        ) { workspace in
            try await workspace.createDirectory(at: path, recursive: recursive)
        }
    }

    /// Removes an item from the shared workspace.
    public func removeItem(at path: WorkspacePath, recursive: Bool = true) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .removeItem,
            edit: .delete(path: path, recursive: recursive)
        ) { workspace in
            try await workspace.removeItem(at: path, recursive: recursive)
        }
    }

    /// Copies an item inside the shared workspace.
    public func copyItem(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .copyItem,
            edit: .copy(from: source, to: destination, recursive: recursive)
        ) { workspace in
            try await workspace.copyItem(from: source, to: destination, recursive: recursive)
        }
    }

    /// Moves an item inside the shared workspace.
    public func moveItem(from source: WorkspacePath, to destination: WorkspacePath) async throws {
        try await ensureLoaded()
        try await performDirectEdit(
            on: sharedWorkspace,
            scope: .shared,
            sessionId: nil,
            kind: .moveItem,
            edit: .move(from: source, to: destination)
        ) { workspace in
            try await workspace.moveItem(from: source, to: destination)
        }
    }

    /// Applies a batch of tracked edits to the shared workspace.
    public func applyEdits(
        _ edits: [FileEdit],
        failurePolicy: MutationFailurePolicy = .rollback
    ) async throws -> FileEdit.BatchResult {
        try await ensureLoaded()
        let result = try await sharedWorkspace.applyEdits(edits, failurePolicy: failurePolicy)
        if !edits.isEmpty {
            try await appendMutation(
                kind: .applyEdits,
                scope: .shared,
                sessionId: nil,
                touchedPaths: result.touchedPaths,
                fileChanges: result.edits.flatMap(\.fileChanges),
                diff: result.edits.count == 1 ? result.edits[0].fileChanges.first?.diff : nil
            )
        }
        return result
    }

    /// Applies a tracked multi-file replacement to the shared workspace.
    public func applyReplacement(
        _ request: ReplacementRequest,
        failurePolicy: MutationFailurePolicy = .rollback
    ) async throws -> ReplacementResult {
        try await ensureLoaded()
        let result = try await sharedWorkspace.applyReplacement(request, failurePolicy: failurePolicy)
        if !result.changes.isEmpty || !result.failures.isEmpty {
            try await appendMutation(
                kind: .applyReplacement,
                scope: .shared,
                sessionId: nil,
                touchedPaths: result.touchedPaths,
                fileChanges: result.changes.map {
                    FileEdit.FileChange(
                        path: $0.path,
                        kind: .file,
                        effect: .modified,
                        status: $0.status,
                        diff: $0.diff
                    )
                },
                diff: result.changes.count == 1 ? result.changes[0].diff : nil
            )
        }
        return result
    }

    /// Creates a shared checkpoint.
    public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        let snapshot = try await sharedWorkspace.captureSnapshot()
        return try await persistCheckpoint(
            snapshot: snapshot,
            scope: .shared,
            sessionId: nil,
            label: label,
            parentCheckpointId: sharedHeadCheckpointId,
            baseSharedCheckpointId: nil,
            originSessionId: nil,
            rollbackSourceCheckpointId: nil,
            eventKind: .created
        )
    }

    /// Rolls the shared workspace back to a prior shared checkpoint.
    public func rollbackShared(to checkpointId: UUID, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        let checkpoint = try checkpointOrThrow(id: checkpointId)
        guard checkpoint.scope == .shared else {
            throw HistoryError.checkpointScopeMismatch(expected: .shared, actual: checkpoint.scope)
        }
        try await sharedWorkspace.restoreSnapshot(checkpoint.snapshot)
        let restoredSnapshot = try await sharedWorkspace.captureSnapshot()
        return try await persistCheckpoint(
            snapshot: restoredSnapshot,
            scope: .shared,
            sessionId: nil,
            label: label,
            parentCheckpointId: sharedHeadCheckpointId,
            baseSharedCheckpointId: nil,
            originSessionId: nil,
            rollbackSourceCheckpointId: checkpoint.id,
            eventKind: .rolledBack
        )
    }

    /// Publishes the current session head into the shared workspace.
    func publishSessionHead(sessionId: UUID, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        var session = try sessionState(for: sessionId)

        guard sharedHeadCheckpointId == session.baseSharedCheckpointId else {
            throw HistoryError.publishConflict(
                sessionId: sessionId,
                expectedBaseSharedCheckpointId: session.baseSharedCheckpointId,
                actualSharedCheckpointId: sharedHeadCheckpointId
            )
        }

        let previousSharedSnapshot = try await sharedWorkspace.captureSnapshot()
        let sessionSnapshot = try await session.workspace.captureSnapshot()
        let delta = snapshotDelta(from: previousSharedSnapshot.entry, to: sessionSnapshot.entry)

        try await sharedWorkspace.restoreSnapshot(sessionSnapshot)

        if delta.hasChanges {
            try await appendMutation(
                kind: .publishSessionHead,
                scope: .shared,
                sessionId: sessionId,
                touchedPaths: Array(delta.touchedPaths).sorted(),
                fileChanges: delta.fileChanges,
                diff: nil
            )
        }

        let checkpoint = try await persistCheckpoint(
            snapshot: sessionSnapshot,
            scope: .shared,
            sessionId: sessionId,
            label: label,
            parentCheckpointId: sharedHeadCheckpointId,
            baseSharedCheckpointId: nil,
            originSessionId: sessionId,
            rollbackSourceCheckpointId: nil,
            eventKind: .published
        )

        session.baseSharedCheckpointId = checkpoint.id
        sessions[sessionId] = session
        return checkpoint
    }

    /// Lists checkpoints for the managed workspace.
    public func listCheckpoints(
        scope: Checkpoint.Scope? = nil,
        sessionId: UUID? = nil
    ) async throws -> [Checkpoint] {
        try await ensureLoaded()
        return checkpoints.filter { checkpoint in
            if let scope, checkpoint.scope != scope {
                return false
            }
            if let sessionId {
                return checkpoint.sessionId == sessionId
            }
            return true
        }
    }

    /// Lists mutation records for the managed workspace.
    func listMutationRecords(
        scope: Checkpoint.Scope? = nil,
        sessionId: UUID? = nil
    ) async throws -> [MutationRecord] {
        try await ensureLoaded()
        return mutations.filter { mutation in
            if let scope, mutation.scope != scope {
                return false
            }
            if let sessionId {
                return mutation.sessionId == sessionId
            }
            return true
        }
    }

    /// Returns one checkpoint when present.
    public func checkpoint(id: UUID) async throws -> Checkpoint? {
        try await ensureLoaded()
        return checkpoints.first(where: { $0.id == id })
    }

    func sessionWriteFile(_ sessionId: UUID, path: WorkspacePath, content: String) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .writeFile,
            edit: .writeFile(path: path, content: content)
        ) { workspace in
            try await workspace.writeFile(path, content: content)
        }
    }

    func sessionAppendFile(_ sessionId: UUID, path: WorkspacePath, content: String) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .appendFile,
            edit: .appendFile(path: path, content: content)
        ) { workspace in
            try await workspace.appendFile(path, content: content)
        }
    }

    func sessionWriteData(_ sessionId: UUID, data: Data, path: WorkspacePath) async throws {
        try await ensureLoaded()
        let workspace = try sessionState(for: sessionId).workspace
        try await performBinaryWrite(on: workspace, scope: .session, sessionId: sessionId, data: data, path: path)
    }

    func sessionWriteJSON<T: Encodable & Sendable>(
        _ sessionId: UUID,
        value: T,
        path: WorkspacePath,
        prettyPrinted: Bool
    ) async throws {
        try await ensureLoaded()
        let workspace = try sessionState(for: sessionId).workspace
        let content = try encodedJSONString(for: value, prettyPrinted: prettyPrinted)
        try await performDirectEdit(
            on: workspace,
            scope: .session,
            sessionId: sessionId,
            kind: .writeJSON,
            edit: .writeFile(path: path, content: content)
        ) { workspace in
            try await workspace.writeFile(path, content: content)
        }
    }

    func sessionCreateDirectory(_ sessionId: UUID, path: WorkspacePath, recursive: Bool) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .createDirectory,
            edit: .createDirectory(path: path, recursive: recursive)
        ) { workspace in
            try await workspace.createDirectory(at: path, recursive: recursive)
        }
    }

    func sessionRemoveItem(_ sessionId: UUID, path: WorkspacePath, recursive: Bool) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .removeItem,
            edit: .delete(path: path, recursive: recursive)
        ) { workspace in
            try await workspace.removeItem(at: path, recursive: recursive)
        }
    }

    func sessionCopyItem(
        _ sessionId: UUID,
        source: WorkspacePath,
        destination: WorkspacePath,
        recursive: Bool
    ) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .copyItem,
            edit: .copy(from: source, to: destination, recursive: recursive)
        ) { workspace in
            try await workspace.copyItem(from: source, to: destination, recursive: recursive)
        }
    }

    func sessionMoveItem(_ sessionId: UUID, source: WorkspacePath, destination: WorkspacePath) async throws {
        try await ensureLoaded()
        try await performSessionDirectEdit(
            sessionId: sessionId,
            kind: .moveItem,
            edit: .move(from: source, to: destination)
        ) { workspace in
            try await workspace.moveItem(from: source, to: destination)
        }
    }

    func sessionApplyEdits(
        _ sessionId: UUID,
        edits: [FileEdit],
        failurePolicy: MutationFailurePolicy
    ) async throws -> FileEdit.BatchResult {
        try await ensureLoaded()
        let workspace = try sessionState(for: sessionId).workspace
        let result = try await workspace.applyEdits(edits, failurePolicy: failurePolicy)
        if !edits.isEmpty {
            try await appendMutation(
                kind: .applyEdits,
                scope: .session,
                sessionId: sessionId,
                touchedPaths: result.touchedPaths,
                fileChanges: result.edits.flatMap(\.fileChanges),
                diff: result.edits.count == 1 ? result.edits[0].fileChanges.first?.diff : nil
            )
        }
        return result
    }

    func sessionApplyReplacement(
        _ sessionId: UUID,
        request: ReplacementRequest,
        failurePolicy: MutationFailurePolicy
    ) async throws -> ReplacementResult {
        try await ensureLoaded()
        let workspace = try sessionState(for: sessionId).workspace
        let result = try await workspace.applyReplacement(request, failurePolicy: failurePolicy)
        if !result.changes.isEmpty || !result.failures.isEmpty {
            try await appendMutation(
                kind: .applyReplacement,
                scope: .session,
                sessionId: sessionId,
                touchedPaths: result.touchedPaths,
                fileChanges: result.changes.map {
                    FileEdit.FileChange(
                        path: $0.path,
                        kind: .file,
                        effect: .modified,
                        status: $0.status,
                        diff: $0.diff
                    )
                },
                diff: result.changes.count == 1 ? result.changes[0].diff : nil
            )
        }
        return result
    }

    func createSessionCheckpoint(sessionId: UUID, label: String? = nil) async throws -> Checkpoint {
        try await ensureLoaded()
        let session = try sessionState(for: sessionId)
        let snapshot = try await session.workspace.captureSnapshot()
        return try await persistCheckpoint(
            snapshot: snapshot,
            scope: .session,
            sessionId: sessionId,
            label: label,
            parentCheckpointId: session.lastCheckpointId,
            baseSharedCheckpointId: session.baseSharedCheckpointId,
            originSessionId: nil,
            rollbackSourceCheckpointId: nil,
            eventKind: .created
        )
    }

    func rollbackSession(
        sessionId: UUID,
        to checkpointId: UUID,
        label: String? = nil
    ) async throws -> Checkpoint {
        try await ensureLoaded()
        var session = try sessionState(for: sessionId)
        let checkpoint = try checkpointOrThrow(id: checkpointId)

        switch checkpoint.scope {
        case .shared:
            break
        case .session where checkpoint.sessionId == sessionId:
            break
        case .session:
            throw HistoryError.checkpointSessionMismatch(
                checkpointId: checkpoint.id,
                expectedSessionId: sessionId,
                actualSessionId: checkpoint.sessionId
            )
        }

        try await session.workspace.restoreSnapshot(checkpoint.snapshot)

        switch checkpoint.scope {
        case .shared:
            session.baseSharedCheckpointId = checkpoint.id
        case .session:
            session.baseSharedCheckpointId = checkpoint.baseSharedCheckpointId
        }
        sessions[sessionId] = session

        let restoredSnapshot = try await session.workspace.captureSnapshot()
        return try await persistCheckpoint(
            snapshot: restoredSnapshot,
            scope: .session,
            sessionId: sessionId,
            label: label,
            parentCheckpointId: session.lastCheckpointId,
            baseSharedCheckpointId: session.baseSharedCheckpointId,
            originSessionId: nil,
            rollbackSourceCheckpointId: checkpoint.id,
            eventKind: .rolledBack
        )
    }

    func sessionBaseSharedCheckpointId(_ sessionId: UUID) async throws -> UUID? {
        try await ensureLoaded()
        return try sessionState(for: sessionId).baseSharedCheckpointId
    }

    private func ensureLoaded() async throws {
        guard !didLoadStoreState else {
            return
        }

        checkpoints = try await store.listCheckpoints(workspaceId: workspaceId)
        mutations = try await store.listMutationRecords(workspaceId: workspaceId)
        nextMutationSequence = (mutations.map(\.sequence).max() ?? 0) + 1
        sharedHeadCheckpointId = checkpoints
            .filter { $0.scope == .shared }
            .sorted(by: checkpointSort)
            .last?
            .id
        didLoadStoreState = true
    }

    private func sessionState(for sessionId: UUID) throws -> SessionState {
        guard let session = sessions[sessionId] else {
            throw HistoryError.sessionNotFound(sessionId)
        }
        return session
    }

    private func checkpointOrThrow(id: UUID) throws -> Checkpoint {
        guard let checkpoint = checkpoints.first(where: { $0.id == id }) else {
            throw HistoryError.checkpointNotFound(id)
        }
        return checkpoint
    }

    private func performSessionDirectEdit(
        sessionId: UUID,
        kind: MutationRecord.Kind,
        edit: FileEdit,
        apply: @escaping @Sendable (Workspace) async throws -> Void
    ) async throws {
        let workspace = try sessionState(for: sessionId).workspace
        try await performDirectEdit(
            on: workspace,
            scope: .session,
            sessionId: sessionId,
            kind: kind,
            edit: edit,
            apply: apply
        )
    }

    private func performDirectEdit(
        on workspace: Workspace,
        scope: Checkpoint.Scope,
        sessionId: UUID?,
        kind: MutationRecord.Kind,
        edit: FileEdit,
        apply: @escaping @Sendable (Workspace) async throws -> Void
    ) async throws {
        let preview = try await workspace.previewEdits([edit])
        try await apply(workspace)

        let appliedFileChanges = markApplied(preview.edits.first?.fileChanges ?? [])
        try await appendMutation(
            kind: kind,
            scope: scope,
            sessionId: sessionId,
            touchedPaths: preview.touchedPaths,
            fileChanges: appliedFileChanges,
            diff: appliedFileChanges.count == 1 ? appliedFileChanges[0].diff : nil
        )
    }

    private func performBinaryWrite(
        on workspace: Workspace,
        scope: Checkpoint.Scope,
        sessionId: UUID?,
        data: Data,
        path: WorkspacePath
    ) async throws {
        let effect: FileEdit.Effect
        let kind: FileTree.Kind

        if await workspace.exists(path) {
            let info = try await workspace.fileInfo(at: path)
            kind = info.kind
            if info.kind == .directory {
                effect = .unchanged
            } else {
                effect = try await workspace.readData(from: path) == data ? .unchanged : .modified
            }
        } else {
            kind = .file
            effect = .created
        }

        try await workspace.writeData(data, to: path)
        try await appendMutation(
            kind: .writeData,
            scope: scope,
            sessionId: sessionId,
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

    private func persistCheckpoint(
        snapshot: Snapshot,
        scope: Checkpoint.Scope,
        sessionId: UUID?,
        label: String?,
        parentCheckpointId: UUID?,
        baseSharedCheckpointId: UUID?,
        originSessionId: UUID?,
        rollbackSourceCheckpointId: UUID?,
        eventKind: CheckpointEvent.Kind
    ) async throws -> Checkpoint {
        let parentCheckpoint = parentCheckpointId.flatMap { id in
            checkpoints.first(where: { $0.id == id })
        }
        let previousCursor = parentCheckpoint?.mutationCursor ?? 0
        let currentCursor = latestMutationSequence(scope: scope, sessionId: sessionId)
        let checkpointId = UUID()
        let resolvedBaseSharedCheckpointId = scope == .shared ? checkpointId : baseSharedCheckpointId

        let checkpoint = Checkpoint(
            id: checkpointId,
            workspaceId: workspaceId,
            sessionId: sessionId,
            scope: scope,
            label: label,
            parentCheckpointId: parentCheckpointId,
            baseSharedCheckpointId: resolvedBaseSharedCheckpointId,
            firstMutationSequence: currentCursor > previousCursor ? previousCursor + 1 : nil,
            lastMutationSequence: currentCursor > previousCursor ? currentCursor : nil,
            mutationCursor: currentCursor,
            originSessionId: originSessionId,
            rollbackSourceCheckpointId: rollbackSourceCheckpointId,
            snapshot: snapshot
        )

        try await store.saveCheckpoint(checkpoint)

        checkpoints.append(checkpoint)
        checkpoints.sort(by: checkpointSort)

        switch scope {
        case .shared:
            sharedHeadCheckpointId = checkpoint.id
        case .session:
            if let sessionId, var session = sessions[sessionId] {
                session.lastCheckpointId = checkpoint.id
                sessions[sessionId] = session
            }
        }

        emit(CheckpointEvent(kind: eventKind, checkpoint: checkpoint))
        return checkpoint
    }

    private func appendMutation(
        kind: MutationRecord.Kind,
        scope: Checkpoint.Scope,
        sessionId: UUID?,
        touchedPaths: [WorkspacePath],
        fileChanges: [FileEdit.FileChange],
        diff: TextDiff?
    ) async throws {
        let mutation = MutationRecord(
            sequence: nextMutationSequence,
            workspaceId: workspaceId,
            sessionId: sessionId,
            scope: scope,
            kind: kind,
            touchedPaths: Array(Set(touchedPaths)).sorted(),
            fileChanges: fileChanges.sorted(by: fileChangeSort),
            diff: diff
        )

        nextMutationSequence += 1
        mutations.append(mutation)
        mutations.sort(by: { $0.sequence < $1.sequence })
        try await store.appendMutation(mutation)
    }

    private func latestMutationSequence(scope: Checkpoint.Scope, sessionId: UUID?) -> Int {
        mutations
            .filter {
                guard $0.scope == scope else {
                    return false
                }
                if scope == .session {
                    return $0.sessionId == sessionId
                }
                return true
            }
            .map(\.sequence)
            .max() ?? 0
    }

    private func encodedJSONString<T: Encodable>(for value: T, prettyPrinted: Bool) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }

        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalidEncoding(.root)
        }
        return string
    }

    private func markApplied(_ fileChanges: [FileEdit.FileChange]) -> [FileEdit.FileChange] {
        fileChanges.map { change in
            var copy = change
            copy.status = .applied
            return copy
        }
    }

    private func snapshotDelta(from original: Snapshot.Entry, to updated: Snapshot.Entry) -> SnapshotDelta {
        var delta = SnapshotDelta()
        collectDelta(from: original, to: updated, into: &delta)
        delta.fileChanges.sort(by: fileChangeSort)
        return delta
    }

    private func collectDelta(
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
                delta.fileChanges.append(
                    FileEdit.FileChange(
                        path: rhs.path,
                        kind: .file,
                        effect: .modified,
                        status: .applied,
                        diff: nil
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

            let lhsChildren = Dictionary(uniqueKeysWithValues: lhs.children.map { (Snapshot.path(of: $0).basename, $0) })
            let rhsChildren = Dictionary(uniqueKeysWithValues: rhs.children.map { (Snapshot.path(of: $0).basename, $0) })
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

    private func collectCreated(_ entry: Snapshot.Entry, into delta: inout SnapshotDelta) {
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
                    diff: nil
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

    private func collectDeleted(_ entry: Snapshot.Entry, into delta: inout SnapshotDelta) {
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
                    diff: nil
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

    private func emit(_ event: CheckpointEvent) {
        let watchers = eventWatchers.values.filter { $0.workspaceId == event.workspaceId }
        for watcher in watchers {
            watcher.continuation.yield(event)
        }
    }

    private func removeEventWatcher(id: UUID) {
        eventWatchers.removeValue(forKey: id)
    }

    private func checkpointSort(lhs: Checkpoint, rhs: Checkpoint) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func fileChangeSort(lhs: FileEdit.FileChange, rhs: FileEdit.FileChange) -> Bool {
        if lhs.path == rhs.path {
            return lhs.effect.rawValue < rhs.effect.rawValue
        }
        return lhs.path < rhs.path
    }
}

extension History {
    /// A tracked session-local editing overlay managed by `History`.
    public actor Session {
        public let id: UUID
        public let workspaceId: UUID

        private let workspace: Workspace
        private let history: History

        init(id: UUID, workspaceId: UUID, workspace: Workspace, history: History) {
            self.id = id
            self.workspaceId = workspaceId
            self.workspace = workspace
            self.history = history
        }

        /// Reads raw data from the session overlay.
        public func readData(from path: WorkspacePath) async throws -> Data {
            try await workspace.readData(from: path)
        }

        /// Reads UTF-8 text from the session overlay.
        public func readFile(_ path: WorkspacePath) async throws -> String {
            try await workspace.readFile(path)
        }

        /// Reads JSON from the session overlay.
        public func readJSON<T: Decodable & Sendable>(_ type: T.Type = T.self, from path: WorkspacePath) async throws -> T {
            try await workspace.readJSON(type, from: path)
        }

        /// Returns whether an entry exists in the session overlay.
        public func exists(_ path: WorkspacePath) async -> Bool {
            await workspace.exists(path)
        }

        /// Returns session overlay metadata.
        public func fileInfo(at path: WorkspacePath) async throws -> FileInfo {
            try await workspace.fileInfo(at: path)
        }

        /// Lists a session overlay directory.
        public func listDirectory(at path: WorkspacePath) async throws -> [DirectoryEntry] {
            try await workspace.listDirectory(at: path)
        }

        /// Expands a glob against the session overlay.
        public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
            try await workspace.glob(pattern, currentDirectory: currentDirectory)
        }

        /// Walks the session overlay tree.
        public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTree {
            try await workspace.walkTree(path, maxDepth: maxDepth)
        }

        /// Summarizes the session overlay tree.
        public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTreeSummary {
            try await workspace.summarizeTree(path, maxDepth: maxDepth)
        }

        /// Watches session-local filesystem changes.
        public func watchChanges(at path: WorkspacePath, recursive: Bool = true) async -> AsyncStream<ChangeEvent> {
            await workspace.watchChanges(at: path, recursive: recursive)
        }

        /// Writes UTF-8 text into the session overlay.
        public func writeFile(_ path: WorkspacePath, content: String) async throws {
            try await history.sessionWriteFile(id, path: path, content: content)
        }

        /// Appends UTF-8 text into the session overlay.
        public func appendFile(_ path: WorkspacePath, content: String) async throws {
            try await history.sessionAppendFile(id, path: path, content: content)
        }

        /// Writes raw data into the session overlay.
        public func writeData(_ data: Data, to path: WorkspacePath) async throws {
            try await history.sessionWriteData(id, data: data, path: path)
        }

        /// Encodes JSON into the session overlay.
        public func writeJSON<T: Encodable & Sendable>(
            _ value: T,
            to path: WorkspacePath,
            prettyPrinted: Bool = true
        ) async throws {
            try await history.sessionWriteJSON(id, value: value, path: path, prettyPrinted: prettyPrinted)
        }

        /// Creates a directory in the session overlay.
        public func createDirectory(at path: WorkspacePath, recursive: Bool = true) async throws {
            try await history.sessionCreateDirectory(id, path: path, recursive: recursive)
        }

        /// Removes an item from the session overlay.
        public func removeItem(at path: WorkspacePath, recursive: Bool = true) async throws {
            try await history.sessionRemoveItem(id, path: path, recursive: recursive)
        }

        /// Copies an item inside the session overlay.
        public func copyItem(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true) async throws {
            try await history.sessionCopyItem(id, source: source, destination: destination, recursive: recursive)
        }

        /// Moves an item inside the session overlay.
        public func moveItem(from source: WorkspacePath, to destination: WorkspacePath) async throws {
            try await history.sessionMoveItem(id, source: source, destination: destination)
        }

        /// Applies a tracked batch of edits to the session overlay.
        public func applyEdits(
            _ edits: [FileEdit],
            failurePolicy: MutationFailurePolicy = .rollback
        ) async throws -> FileEdit.BatchResult {
            try await history.sessionApplyEdits(id, edits: edits, failurePolicy: failurePolicy)
        }

        /// Applies a tracked replacement to the session overlay.
        public func applyReplacement(
            _ request: ReplacementRequest,
            failurePolicy: MutationFailurePolicy = .rollback
        ) async throws -> ReplacementResult {
            try await history.sessionApplyReplacement(id, request: request, failurePolicy: failurePolicy)
        }

        /// Creates a session-local checkpoint.
        public func createCheckpoint(label: String? = nil) async throws -> Checkpoint {
            try await history.createSessionCheckpoint(sessionId: id, label: label)
        }

        /// Restores the session overlay to a prior checkpoint.
        public func rollback(to checkpointId: UUID, label: String? = nil) async throws -> Checkpoint {
            try await history.rollbackSession(sessionId: id, to: checkpointId, label: label)
        }

        /// Publishes the current session head into the shared workspace.
        public func publishHead(label: String? = nil) async throws -> Checkpoint {
            try await history.publishSessionHead(sessionId: id, label: label)
        }

        /// Lists checkpoints visible to this session.
        public func listCheckpoints() async throws -> [Checkpoint] {
            let checkpoints = try await history.listCheckpoints()
            return checkpoints.filter { checkpoint in
                switch checkpoint.scope {
                case .shared:
                    return true
                case .session:
                    return checkpoint.sessionId == id
                }
            }
        }

        /// Lists mutation records for this session.
        func listMutationRecords() async throws -> [MutationRecord] {
            try await history.listMutationRecords(scope: .session, sessionId: id)
        }

        /// Returns the shared checkpoint this session is currently based on.
        func baseSharedCheckpointId() async throws -> UUID? {
            try await history.sessionBaseSharedCheckpointId(id)
        }
    }
}
