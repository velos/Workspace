import Foundation
import Testing
@testable import Workspace

private actor CheckpointEventRecorder {
    private var events: [CheckpointEvent] = []

    func append(_ event: CheckpointEvent) {
        events.append(event)
    }

    func snapshot() -> [CheckpointEvent] {
        events
    }
}

private func startCheckpointRecording(
    _ stream: AsyncStream<CheckpointEvent>,
    into recorder: CheckpointEventRecorder
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await recorder.append(event)
        }
    }
}

private func waitForCheckpointEvents(
    _ expectedCount: Int,
    recorder: CheckpointEventRecorder,
    timeout: Duration = .seconds(1)
) async throws -> [CheckpointEvent] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        let snapshot = await recorder.snapshot()
        if snapshot.count >= expectedCount {
            return Array(snapshot.prefix(expectedCount))
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    return await recorder.snapshot()
}

/// Delegates to ``InMemoryCheckpointStore`` but can force ``loadSnapshot`` to return nil for specific ids (exercises ``HistoryError/snapshotNotFound``).
private actor FlakySnapshotCheckpointStore: CheckpointStore {
    private let base = InMemoryCheckpointStore()
    private var snapshotIdsReturningNil: Set<UUID> = []

    func breakLoadingSnapshot(id: UUID) {
        snapshotIdsReturningNil.insert(id)
    }

    func saveCheckpoint(_ checkpoint: History.Checkpoint) async throws {
        try await base.saveCheckpoint(checkpoint)
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> History.Checkpoint? {
        try await base.loadCheckpoint(id: id, workspaceId: workspaceId)
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [History.Checkpoint] {
        try await base.listCheckpoints(workspaceId: workspaceId)
    }

    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {
        try await base.saveSnapshot(snapshot, workspaceId: workspaceId)
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        if snapshotIdsReturningNil.contains(id) {
            return nil
        }
        return try await base.loadSnapshot(id: id, workspaceId: workspaceId)
    }

    func appendMutation(_ mutation: MutationRecord) async throws {
        try await base.appendMutation(mutation)
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        try await base.listMutationRecords(workspaceId: workspaceId)
    }
}

@Suite("History")
struct HistoryTests {
    @Test
    func `session checkpoints persist mutation ranges and shared workspace remains unchanged`() async throws {
        let workspaceId = UUID()
        let history = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem()
        )

        let session = try await history.createSession()
        try await session.writeFile("/note.txt", content: "one")
        try await session.appendFile("/note.txt", content: " two")
        try await session.createDirectory(at: "/docs")

        let checkpoint = try await session.createCheckpoint(label: "draft")
        let mutations = try await session.mutationRecords()
        let storeCheckpoints = try await history.listCheckpoints(scope: .session, sessionId: session.id)

        #expect(checkpoint.scope == .session)
        #expect(checkpoint.sessionId == session.id)
        #expect(checkpoint.firstMutationSequence == 1)
        #expect(checkpoint.lastMutationSequence == 3)
        #expect(checkpoint.mutationCursor == 3)
        #expect(checkpoint.label == "draft")
        #expect(mutations.map(\.kind) == [.writeFile, .appendFile, .createDirectory])
        #expect(mutations[0].diff?.hunks.isEmpty == false)
        #expect(mutations[1].diff?.hunks.isEmpty == false)
        #expect(mutations[2].diff == nil)
        #expect(storeCheckpoints == [checkpoint])
        #expect(!(await history.shared.exists("/note.txt")))
    }

    @Test
    func `empty checkpoints are persisted and session rollback creates a rollback checkpoint`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        let session = try await history.createSession()
        let emptyCheckpoint = try await session.createCheckpoint(label: "start")

        try await session.writeFile("/note.txt", content: "draft")
        let rollbackCheckpoint = try await session.rollback(to: emptyCheckpoint.id, label: "undo")

        #expect(emptyCheckpoint.firstMutationSequence == nil)
        #expect(emptyCheckpoint.lastMutationSequence == nil)
        #expect(emptyCheckpoint.mutationCursor == 0)
        #expect(!(await session.workspace.exists("/note.txt")))
        #expect(rollbackCheckpoint.scope == .session)
        #expect(rollbackCheckpoint.rollbackSourceCheckpointId == emptyCheckpoint.id)
        #expect(rollbackCheckpoint.sessionId == session.id)
        #expect((try await session.listCheckpoints()).count == 2)
    }

    @Test
    func `shared rollback restores the shared tree and emits a rollback event`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        try await history.writeFile("/shared.txt", content: "one")
        let checkpoint = try await history.createCheckpoint(label: "v1")
        try await history.writeFile("/shared.txt", content: "two")

        let recorder = CheckpointEventRecorder()
        let stream = try await history.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        let rollbackCheckpoint = try await history.rollback(to: checkpoint.id, label: "revert")
        let events = try await waitForCheckpointEvents(1, recorder: recorder)

        #expect(try await history.shared.readFile("/shared.txt") == "one")
        #expect(rollbackCheckpoint.scope == .shared)
        #expect(rollbackCheckpoint.rollbackSourceCheckpointId == checkpoint.id)
        #expect(events.count == 1)
        #expect(events[0].kind == .rolledBack)
        #expect(events[0].checkpoint == rollbackCheckpoint)
    }

    @Test
    func `sessions checkpoint independently and publish conflicts when shared head has advanced`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        let sessionA = try await history.createSession()
        let sessionB = try await history.createSession()

        try await sessionA.writeFile("/note.txt", content: "alpha")
        try await sessionB.writeFile("/note.txt", content: "beta")

        let checkpointA = try await sessionA.createCheckpoint(label: "a1")
        let checkpointB = try await sessionB.createCheckpoint(label: "b1")
        let published = try await sessionA.publish(label: "publish a")

        #expect(checkpointA.scope == .session)
        #expect(checkpointB.scope == .session)
        #expect(checkpointA.sessionId == sessionA.id)
        #expect(checkpointB.sessionId == sessionB.id)
        #expect(checkpointA.baseSharedCheckpointId == checkpointB.baseSharedCheckpointId)
        #expect(published.scope == .shared)
        #expect(published.originSessionId == sessionA.id)
        #expect(published.sessionId == sessionA.id)
        #expect(try await history.shared.readFile("/note.txt") == "alpha")
        #expect(try await sessionA.baseSharedCheckpointId() == published.id)

        do {
            _ = try await sessionB.publish(label: "publish b")
            Issue.record("expected publish conflict")
        } catch let error as HistoryError {
            switch error {
            case let .publishConflict(sessionId, expectedBaseSharedCheckpointId, actualSharedCheckpointId):
                #expect(sessionId == sessionB.id)
                #expect(expectedBaseSharedCheckpointId == checkpointB.baseSharedCheckpointId)
                #expect(actualSharedCheckpointId == published.id)
            default:
                Issue.record("unexpected history error: \(error)")
            }
        }
    }

    @Test
    func `checkpoint summary tracks file changes and text diffs`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        let session = try await history.createSession()
        try await session.writeFile("/a.txt", content: "hello")
        try await session.writeFile("/b.txt", content: "world")
        try await session.createDirectory(at: "/docs")

        let checkpoint = try await session.createCheckpoint(label: "initial")

        #expect(checkpoint.summary.changeCount == 3)
        #expect(checkpoint.summary.touchedPaths.contains("/a.txt"))
        #expect(checkpoint.summary.touchedPaths.contains("/b.txt"))
        #expect(checkpoint.summary.touchedPaths.contains("/docs"))
        #expect(checkpoint.summary.hasTextDiffs == true)

        try await session.writeFile("/a.txt", content: "updated")
        let second = try await session.createCheckpoint(label: "update")

        #expect(second.summary.changeCount == 1)
        #expect(second.summary.touchedPaths == [WorkspacePath("/a.txt")])
        #expect(second.summary.hasTextDiffs == true)
    }

    @Test
    func `history metadata and file-backed store roundtrip through Codable`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let history = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )

        let session = try await history.createSession()
        try await session.writeFile("/note.txt", content: "hello")
        let checkpoint = try await session.createCheckpoint(label: "draft")
        let mutation = try #require((try await session.mutationRecords()).first)
        let reloaded = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let decodedCheckpoint = try decoder.decode(History.Checkpoint.self, from: encoder.encode(checkpoint))
        let decodedMutation = try decoder.decode(MutationRecord.self, from: encoder.encode(mutation))
        let decodedEvent = try decoder.decode(
            CheckpointEvent.self,
            from: encoder.encode(CheckpointEvent(kind: .created, checkpoint: checkpoint))
        )

        #expect(decodedCheckpoint == checkpoint)
        #expect(decodedMutation == mutation)
        #expect(decodedEvent == CheckpointEvent(kind: .created, checkpoint: checkpoint))
        #expect(try await reloaded.checkpoint(id: checkpoint.id) == checkpoint)
        #expect(try await reloaded.mutationRecords() == [mutation])
    }

    @Test
    func `file backed history reloads checkpoint snapshot artifact`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let history = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )

        try await history.writeFile("/note.txt", content: "checkpoint")
        let checkpoint = try await history.createCheckpoint(label: "saved")
        try await history.writeFile("/note.txt", content: "current")

        let reloaded = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )
        let persistedCheckpoint = try #require(try await reloaded.checkpoint(id: checkpoint.id))
        let snapshot = try await reloaded.snapshot(for: persistedCheckpoint)
        let restored = InMemoryFilesystem()

        try await Snapshot.restore(snapshot, to: restored)

        #expect(try await history.shared.readFile("/note.txt") == "current")
        #expect(try await restored.readFile(path: "/note.txt") == Data("checkpoint".utf8))
        #expect(snapshot.summary(comparedTo: nil) == checkpoint.summary)
    }

    @Test
    func `session creation and checkpointing work with mounted shared filesystems`() async throws {
        let mountedWorkspace = InMemoryFilesystem()
        try await mountedWorkspace.writeFile(path: "/file.txt", data: Data("shared".utf8), append: false)

        let history = History(
            filesystem: MountableFilesystem(
                base: InMemoryFilesystem(),
                mounts: [.init(mountPoint: "/workspace", filesystem: mountedWorkspace)]
            )
        )

        let session = try await history.createSession()
        let original = try await session.workspace.readFile("/workspace/file.txt")
        try await session.writeFile("/workspace/file.txt", content: "session")
        let checkpoint = try await session.createCheckpoint(label: "mounted")

        #expect(original == "shared")
        #expect(try await session.workspace.readFile("/workspace/file.txt") == "session")
        #expect(try await history.shared.readFile("/workspace/file.txt") == "shared")
        #expect(checkpoint.scope == .session)
        #expect(checkpoint.sessionId == session.id)
    }

    @Test
    func `convenience History init defaults to in-memory shared workspace`() async throws {
        let history = History()

        try await history.writeFile("/note.txt", content: "hello")
        let checkpoint = try await history.createCheckpoint(label: "initial")

        #expect(checkpoint.scope == .shared)
        #expect(try await history.shared.readFile("/note.txt") == "hello")
        #expect(try await history.mutationRecords(scope: .shared).map(\.kind) == [.writeFile])
    }

    @Test
    func `mutationRecords filters by shared scope and snapshot(for:) loads checkpoint contents`() async throws {
        let history = History()
        let session = try await history.createSession()
        try await session.writeFile("/session.txt", content: "session")

        try await history.writeFile("/shared.txt", content: "shared-1")
        let checkpoint = try await history.createCheckpoint(label: "shared")
        try await history.writeFile("/shared.txt", content: "shared-2")

        let sharedMutations = try await history.mutationRecords(scope: .shared)
        let sessionMutations = try await history.mutationRecords(scope: .session, sessionId: session.id)
        let snapshot = try await history.snapshot(for: checkpoint)

        #expect(sharedMutations.map(\.kind) == [.writeFile, .writeFile])
        #expect(sharedMutations.allSatisfy { $0.scope == .shared })
        #expect(sessionMutations.map(\.kind) == [.writeFile])
        #expect(sessionMutations.allSatisfy { $0.sessionId == session.id })
        #expect(snapshot.id == checkpoint.snapshotId)

        let restored = Workspace(filesystem: InMemoryFilesystem())
        try await restored.restoreSnapshot(snapshot)
        #expect(try await restored.readFile("/shared.txt") == "shared-1")
        #expect(!(await restored.exists("/session.txt")))
    }

    @Test
    func `rollback throws checkpointNotFound and rejects session checkpoints from shared scope`() async throws {
        let history = History()
        try await history.writeFile("/shared.txt", content: "v1")
        let sharedCheckpoint = try await history.createCheckpoint(label: "shared-v1")

        let session = try await history.createSession()
        try await session.writeFile("/note.txt", content: "draft")
        let sessionCheckpoint = try await session.createCheckpoint(label: "session-v1")

        let bogusId = UUID()
        do {
            _ = try await history.rollback(to: bogusId)
            Issue.record("expected checkpointNotFound")
        } catch let error as HistoryError {
            guard case let .checkpointNotFound(id) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == bogusId)
        }

        do {
            _ = try await history.rollback(to: sessionCheckpoint.id)
            Issue.record("expected checkpointScopeMismatch")
        } catch let error as HistoryError {
            guard case let .checkpointScopeMismatch(expected, actual) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(expected == .shared)
            #expect(actual == .session)
        }

        let rolled = try await history.rollback(to: sharedCheckpoint.id)
        #expect(rolled.rollbackSourceCheckpointId == sharedCheckpoint.id)
    }

    @Test
    func `Storage directory(at:) round-trips checkpoints across History instances`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let history = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )
        try await history.writeFile("/state.json", content: "{}")
        let checkpoint = try await history.createCheckpoint(label: "checkpoint-a")

        let reopened = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )
        let reloaded = try #require(try await reopened.checkpoint(id: checkpoint.id))
        let snapshot = try await reopened.snapshot(for: reloaded)

        #expect(reloaded == checkpoint)
        #expect(snapshot.entry.path == .root)
    }

    @Test
    func `shared mutations record append writeData writeJSON and tree operations`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        try await history.writeFile("/base.txt", content: "x")
        try await history.appendFile("/base.txt", content: "y")
        try await history.writeData(Data([0, 1, 2]), to: "/bin.dat")
        try await history.writeJSON(["a": 1], to: "/config.json", prettyPrinted: false)
        try await history.createDirectory(at: "/nested/deep", recursive: true)
        try await history.writeFile("/nested/deep/a.txt", content: "a")
        try await history.copyItem(from: "/nested/deep/a.txt", to: "/nested/deep/b.txt")
        try await history.moveItem(from: "/nested/deep/b.txt", to: "/moved.txt")
        try await history.removeItem(at: "/nested", recursive: true)

        let kinds = try await history.mutationRecords(scope: .shared).map(\.kind)
        #expect(
            kinds == [
                .writeFile,
                .appendFile,
                .writeData,
                .writeJSON,
                .createDirectory,
                .writeFile,
                .copyItem,
                .moveItem,
                .removeItem,
            ]
        )
        #expect(try await history.shared.readFile("/base.txt") == "xy")
        #expect(try await history.shared.readFile("/moved.txt") == "a")
    }

    @Test
    func `shared applyEdits and applyReplacement append mutation records`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        let batch = try await history.applyEdits(
            [
                .writeFile(path: "/a.txt", content: "line\n"),
                .writeFile(path: "/b.txt", content: "other\n"),
            ]
        )
        #expect(batch.edits.count == 2)

        try await history.writeFile("/replace.txt", content: "hello old world")
        let replacement = try await history.applyReplacement(
            ReplacementRequest(pattern: "*.txt", search: "old", replacement: "new")
        )
        #expect(replacement.changes.count == 1)

        let mutations = try await history.mutationRecords(scope: .shared).map(\.kind)
        #expect(mutations == [.applyEdits, .writeFile, .applyReplacement])
        #expect(try await history.shared.readFile("/replace.txt") == "hello new world")
    }

    @Test
    func `session rollback to shared checkpoint rewires base and rejects other session checkpoints`() async throws {
        let history = History(filesystem: InMemoryFilesystem())
        try await history.writeFile("/shared.txt", content: "v1")
        let sharedCp = try await history.createCheckpoint(label: "shared-head")

        let sessionA = try await history.createSession()
        let sessionB = try await history.createSession()
        try await sessionA.writeFile("/a.txt", content: "a")
        try await sessionB.writeFile("/b.txt", content: "b")
        let bCheckpoint = try await sessionB.createCheckpoint(label: "b-only")

        let rolled = try await sessionA.rollback(to: sharedCp.id, label: "to-shared")
        #expect(try await sessionA.baseSharedCheckpointId() == sharedCp.id)
        #expect(!(await sessionA.workspace.exists("/a.txt")))
        #expect(rolled.rollbackSourceCheckpointId == sharedCp.id)

        do {
            _ = try await sessionA.rollback(to: bCheckpoint.id)
            Issue.record("expected checkpointSessionMismatch")
        } catch let error as HistoryError {
            guard case let .checkpointSessionMismatch(checkpointId, expectedSessionId, actualSessionId) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(checkpointId == bCheckpoint.id)
            #expect(expectedSessionId == sessionA.id)
            #expect(actualSessionId == sessionB.id)
        }
    }

    @Test
    func `watchCheckpointEvents emits created for new shared checkpoints after subscribing`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        let recorder = CheckpointEventRecorder()
        let stream = try await history.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        try await history.writeFile("/tracked.txt", content: "v1")
        let checkpoint = try await history.createCheckpoint(label: "snap")

        let events = try await waitForCheckpointEvents(1, recorder: recorder)
        #expect(events.count == 1)
        #expect(events[0].kind == .created)
        #expect(events[0].checkpoint.id == checkpoint.id)
        #expect(events[0].checkpoint.label == "snap")
    }

    @Test
    func `watchCheckpointEvents emits published when a session head is published`() async throws {
        let history = History(filesystem: InMemoryFilesystem())
        let session = try await history.createSession()
        try await session.writeFile("/pub.txt", content: "content")

        let recorder = CheckpointEventRecorder()
        let stream = try await history.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        let published = try await session.publish(label: "out")

        let events = try await waitForCheckpointEvents(1, recorder: recorder)
        #expect(events.count == 1)
        #expect(events[0].kind == .published)
        #expect(events[0].checkpoint.id == published.id)
        #expect(events[0].checkpoint.originSessionId == session.id)
    }

    @Test
    func `publishSessionHead throws sessionNotFound for an unknown session id`() async throws {
        let history = History()
        let unknown = UUID()
        do {
            _ = try await history.publishSessionHead(sessionId: unknown)
            Issue.record("expected sessionNotFound")
        } catch let error as HistoryError {
            guard case let .sessionNotFound(id) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == unknown)
        }
    }

    @Test
    func `shared applyEdits with an empty batch does not append a mutation`() async throws {
        let history = History()
        try await history.writeFile("/x.txt", content: "x")
        let before = try await history.mutationRecords(scope: .shared).count

        _ = try await history.applyEdits([])

        let after = try await history.mutationRecords(scope: .shared).count
        #expect(after == before)
    }

    @Test
    func `session applyEdits and applyReplacement record session scoped mutations`() async throws {
        let history = History()
        let session = try await history.createSession()

        _ = try await session.applyEdits(
            [
                .writeFile(path: "/batch.txt", content: "a\n"),
            ]
        )
        try await session.writeFile("/replace.txt", content: "find me")
        _ = try await session.applyReplacement(
            ReplacementRequest(pattern: "*.txt", search: "find", replacement: "found")
        )

        let kinds = try await history.mutationRecords(scope: .session, sessionId: session.id).map(\.kind)
        #expect(kinds == [.applyEdits, .writeFile, .applyReplacement])
        #expect(try await session.workspace.readFile("/replace.txt") == "found me")
    }

    @Test
    func `History init with an existing workspace uses it as shared`() async throws {
        let fs = InMemoryFilesystem()
        let workspace = Workspace(filesystem: fs)
        try await workspace.writeFile("/seed.txt", content: "seed")

        let history = History(workspace: workspace)

        #expect(try await history.shared.readFile("/seed.txt") == "seed")
        try await history.writeFile("/more.txt", content: "more")
        #expect(try await workspace.readFile("/more.txt") == "more")
    }

    @Test
    func `listCheckpoints with scope shared excludes session checkpoints`() async throws {
        let history = History()
        try await history.writeFile("/s.txt", content: "s")
        let sharedCP = try await history.createCheckpoint(label: "shared-only")

        let session = try await history.createSession()
        try await session.writeFile("/sess.txt", content: "sess")
        let sessionCP = try await session.createCheckpoint(label: "sess-only")

        let sharedOnly = try await history.listCheckpoints(scope: .shared)
        let forSession = try await history.listCheckpoints(scope: .session, sessionId: session.id)

        #expect(sharedOnly.contains(where: { $0.id == sharedCP.id }))
        #expect(sharedOnly.contains(where: { $0.id == sessionCP.id }) == false)
        #expect(forSession == [sessionCP])
    }

    @Test
    func `checkpoint id returns nil when no checkpoint exists`() async throws {
        let history = History()
        let missing = try await history.checkpoint(id: UUID())
        #expect(missing == nil)
    }

    @Test
    func `publish with no session edits still creates a published shared checkpoint`() async throws {
        let history = History()
        try await history.writeFile("/base.txt", content: "base")
        let session = try await history.createSession()

        let published = try await session.publish(label: "noop")

        #expect(published.scope == .shared)
        #expect(published.originSessionId == session.id)
        #expect(published.inferredEventKind == .published)

        let publishMutations = try await history.mutationRecords(scope: .shared).filter { $0.kind == .publishSessionHead }
        #expect(publishMutations.isEmpty)

        #expect(try await history.shared.readFile("/base.txt") == "base")
    }

    @Test
    func `session writeData and writeJSON append session mutations`() async throws {
        let history = History()
        let session = try await history.createSession()

        try await session.writeData(Data([9, 8]), to: "/raw.bin")
        try await session.writeJSON(["k": true], to: "/cfg.json", prettyPrinted: true)

        let kinds = try await history.mutationRecords(scope: .session, sessionId: session.id).map(\.kind)
        #expect(kinds == [.writeData, .writeJSON])
    }

    @Test
    func `snapshot for checkpoint throws snapshotNotFound when store drops the artifact`() async throws {
        let store = FlakySnapshotCheckpointStore()
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        let history = History(workspace: workspace, store: store)

        try await history.writeFile("/a.txt", content: "a")
        let checkpoint = try await history.createCheckpoint(label: "has-snapshot")

        await store.breakLoadingSnapshot(id: checkpoint.snapshotId)

        do {
            _ = try await history.snapshot(for: checkpoint)
            Issue.record("expected snapshotNotFound")
        } catch let error as HistoryError {
            guard case let .snapshotNotFound(id) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == checkpoint.snapshotId)
        }
    }

    @Test
    func `shared rollback throws snapshotNotFound when snapshot artifact is missing`() async throws {
        let store = FlakySnapshotCheckpointStore()
        let history = History(workspace: Workspace(filesystem: InMemoryFilesystem()), store: store)

        try await history.writeFile("/x.txt", content: "x")
        let checkpoint = try await history.createCheckpoint(label: "v1")
        try await history.writeFile("/x.txt", content: "y")

        await store.breakLoadingSnapshot(id: checkpoint.snapshotId)

        do {
            _ = try await history.rollback(to: checkpoint.id)
            Issue.record("expected snapshotNotFound")
        } catch let error as HistoryError {
            guard case let .snapshotNotFound(id) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == checkpoint.snapshotId)
        }
    }

    @Test
    func `watchCheckpointEvents receives checkpoints created by another History sharing the store`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()

        let observer = History(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)
        let producer = History(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)

        let recorder = CheckpointEventRecorder()
        let stream = try await observer.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        try await producer.writeFile("/remote.txt", content: "r")
        let created = try await producer.createCheckpoint(label: "other-instance")

        let events = try await waitForCheckpointEvents(1, recorder: recorder, timeout: .seconds(2))
        #expect(events.count >= 1)
        let match = try #require(events.first(where: { $0.checkpoint.id == created.id }))
        #expect(match.kind == .created)
    }

    @Test
    func `session removeItem copyItem and moveItem record session mutations`() async throws {
        let history = History()
        let session = try await history.createSession()

        try await session.writeFile("/a.txt", content: "a")
        try await session.createDirectory(at: "/d", recursive: true)
        try await session.writeFile("/d/inner.txt", content: "inner")
        try await session.copyItem(from: "/a.txt", to: "/d/copy.txt")
        try await session.moveItem(from: "/d/copy.txt", to: "/moved.txt")
        try await session.removeItem(at: "/moved.txt")

        let kinds = try await history.mutationRecords(scope: .session, sessionId: session.id).map(\.kind)
        #expect(
            kinds == [
                .writeFile,
                .createDirectory,
                .writeFile,
                .copyItem,
                .moveItem,
                .removeItem,
            ]
        )
    }

    @Test
    func `shared writeData to an existing file is unchanged when bytes match`() async throws {
        let history = History()
        let data = Data([7, 7, 7])

        try await history.writeData(data, to: "/bin.dat")
        try await history.writeData(data, to: "/bin.dat")

        let mutations = try await history.mutationRecords(scope: .shared)
        #expect(mutations.count == 2)
        #expect(mutations.allSatisfy { $0.kind == .writeData })
        let effects = mutations.flatMap(\.fileChanges).map(\.effect)
        #expect(effects == [.created, .unchanged])
    }

    @Test
    func `shared writeData targets an existing directory before overwriting with file contents`() async throws {
        let history = History()
        try await history.createDirectory(at: "/bucket", recursive: true)

        try await history.writeData(Data("blob".utf8), to: "/bucket")

        let mutation = try #require((try await history.mutationRecords(scope: .shared)).last)
        #expect(mutation.kind == .writeData)
        let change = try #require(mutation.fileChanges.first)
        #expect(change.kind == .directory)
        #expect(change.effect == .unchanged)
    }

    @Test
    func `publish records a publishSessionHead mutation when session replaces a file with a directory`() async throws {
        let history = History()
        try await history.writeFile("/shape.txt", content: "was-a-file")

        let session = try await history.createSession()
        try await session.removeItem(at: "/shape.txt")
        try await session.createDirectory(at: "/shape.txt", recursive: true)
        try await session.writeFile("/shape.txt/nested.txt", content: "now-tree")

        _ = try await session.publish(label: "restructure")

        let publishRows = try await history.mutationRecords(scope: .shared).filter { $0.kind == .publishSessionHead }
        #expect(publishRows.count == 1)
        #expect(try await history.shared.readFile("/shape.txt/nested.txt") == "now-tree")
    }

    @Test
    func `session listCheckpoints includes shared checkpoints and session scoped rows`() async throws {
        let history = History()
        try await history.writeFile("/shared-only.txt", content: "s")
        let sharedCP = try await history.createCheckpoint(label: "on-shared")

        let session = try await history.createSession()
        try await session.writeFile("/local.txt", content: "l")
        let sessionCP = try await session.createCheckpoint(label: "on-session")

        let visible = try await session.listCheckpoints()
        #expect(visible.contains(where: { $0.id == sharedCP.id && $0.scope == .shared }))
        #expect(visible.contains(where: { $0.id == sessionCP.id && $0.scope == .session }))
    }

    @Test
    func `session applyEdits with an empty batch does not append mutations`() async throws {
        let history = History()
        let session = try await history.createSession()
        try await session.writeFile("/z.txt", content: "z")

        let before = try await history.mutationRecords(scope: .session, sessionId: session.id).count
        _ = try await session.applyEdits([])
        let after = try await history.mutationRecords(scope: .session, sessionId: session.id).count

        #expect(after == before)
    }

    @Test
    func `multiple watchCheckpointEvents subscriptions share one polling loop`() async throws {
        let history = History(filesystem: InMemoryFilesystem())

        _ = try await history.watchCheckpointEvents()
        _ = try await history.watchCheckpointEvents()

        try await history.writeFile("/multi-watch.txt", content: "mw")
        let checkpoint = try await history.createCheckpoint(label: "mw")

        #expect(checkpoint.label == "mw")
    }

    @Test
    func `cancelling a checkpoint stream allows a new watch to receive subsequent events`() async throws {
        let history = History()

        let firstStream = try await history.watchCheckpointEvents()
        let consumer = Task {
            for await _ in firstStream {}
        }
        try await Task.sleep(for: .milliseconds(30))
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(120))

        let recorder = CheckpointEventRecorder()
        let secondStream = try await history.watchCheckpointEvents()
        let recording = startCheckpointRecording(secondStream, into: recorder)
        defer { recording.cancel() }

        try await history.writeFile("/after-resubscribe.txt", content: "ar")
        let checkpoint = try await history.createCheckpoint(label: "resubscribe")

        let events = try await waitForCheckpointEvents(1, recorder: recorder)
        #expect(events.contains(where: { $0.checkpoint.id == checkpoint.id && $0.kind == .created }))
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("HistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
