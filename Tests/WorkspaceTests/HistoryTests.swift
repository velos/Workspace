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
