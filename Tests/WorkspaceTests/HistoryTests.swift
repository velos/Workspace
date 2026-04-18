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
        let mutations = try await session.listMutationRecords()
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

        let rollbackCheckpoint = try await history.rollbackShared(to: checkpoint.id, label: "revert")
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
        let published = try await sessionA.publishHead(label: "publish a")

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
            _ = try await sessionB.publishHead(label: "publish b")
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
            storage: .directory(root)
        )

        let session = try await history.createSession()
        try await session.writeFile("/note.txt", content: "hello")
        let checkpoint = try await session.createCheckpoint(label: "draft")
        let mutation = try #require((try await session.listMutationRecords()).first)
        let reloaded = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(root)
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
        #expect(try await reloaded.listMutationRecords() == [mutation])
    }

    @Test
    func `file backed history reloads checkpoint snapshot artifact`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let history = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(root)
        )

        try await history.writeFile("/note.txt", content: "checkpoint")
        let checkpoint = try await history.createCheckpoint(label: "saved")
        try await history.writeFile("/note.txt", content: "current")

        let reloaded = History(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(root)
        )
        let persistedCheckpoint = try #require(try await reloaded.checkpoint(id: checkpoint.id))
        let snapshot = try await reloaded.loadSnapshot(for: persistedCheckpoint)
        let restored = InMemoryFilesystem()

        try await Snapshot.restore(snapshot, to: restored)

        #expect(try await history.shared.readFile("/note.txt") == "current")
        #expect(try await restored.readFile(path: "/note.txt") == Data("checkpoint".utf8))
        #expect(Snapshot.summary(comparing: snapshot, to: nil) == checkpoint.summary)
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
