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

private actor FlakySnapshotCheckpointStore: CheckpointStore {
    private let base = InMemoryCheckpointStore()
    private var snapshotIdsReturningNil: Set<UUID> = []

    func breakLoadingSnapshot(id: UUID) {
        snapshotIdsReturningNil.insert(id)
    }

    func saveCheckpoint(_ checkpoint: Checkpoint) async throws {
        try await base.saveCheckpoint(checkpoint)
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        try await base.loadCheckpoint(id: id, workspaceId: workspaceId)
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
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

    func appendMutation(_ mutation: MutationRecord) async throws -> MutationRecord {
        try await base.appendMutation(mutation)
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        try await base.listMutationRecords(workspaceId: workspaceId)
    }

    func pruneMutationRecords(workspaceId: UUID, throughSequence: Int) async throws {
        try await base.pruneMutationRecords(workspaceId: workspaceId, throughSequence: throughSequence)
    }
}

@Suite("Workspace checkpoints")
struct WorkspaceCheckpointTests {
    @Test
    func `tracked writes persist mutation ranges and checkpoint summaries`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())

        try await workspace.writeFile("/note.txt", content: "one")
        try await workspace.appendFile("/note.txt", content: " two")
        try await workspace.createDirectory(at: "/docs")

        let checkpoint = try await workspace.createCheckpoint(label: "draft")
        let mutations = try await workspace.mutationRecords()

        #expect(checkpoint.firstMutationSequence == 1)
        #expect(checkpoint.lastMutationSequence == 3)
        #expect(checkpoint.mutationCursor == 3)
        #expect(checkpoint.label == "draft")
        #expect(checkpoint.summary.changeCount == 2)
        #expect(checkpoint.summary.touchedPaths.contains("/note.txt"))
        #expect(checkpoint.summary.touchedPaths.contains("/docs"))
        #expect(checkpoint.summary.hasTextDiffs == true)
        #expect(mutations.map(\.kind) == [.writeFile, .appendFile, .createDirectory])
        #expect(mutations[0].diff?.hunks.isEmpty == false)
        #expect(mutations[1].diff?.hunks.isEmpty == false)
        #expect(mutations[2].diff == nil)
        #expect(try await workspace.readFile("/note.txt") == "one two")
    }

    @Test
    func `rollback restores the tree and emits a rollback event`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())

        try await workspace.writeFile("/shared.txt", content: "one")
        let checkpoint = try await workspace.createCheckpoint(label: "v1")
        try await workspace.writeFile("/shared.txt", content: "two")

        let recorder = CheckpointEventRecorder()
        let stream = try await workspace.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        let rollbackCheckpoint = try await workspace.rollback(to: checkpoint.id, label: "revert")
        let events = try await waitForCheckpointEvents(1, recorder: recorder)

        #expect(try await workspace.readFile("/shared.txt") == "one")
        #expect(rollbackCheckpoint.rollbackSourceCheckpointId == checkpoint.id)
        #expect(events.count == 1)
        #expect(events[0].kind == .rolledBack)
        #expect(events[0].checkpoint == rollbackCheckpoint)
    }

    @Test
    func `rollback appends a rollback mutation record`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/file.txt", content: "one")
        let checkpoint = try await workspace.createCheckpoint(label: "v1")
        try await workspace.writeFile("/file.txt", content: "two")

        _ = try await workspace.rollback(to: checkpoint.id)

        let mutations = try await workspace.mutationRecords()
        #expect(mutations.map(\.kind) == [.writeFile, .writeFile, .rollback])
        #expect(mutations.last?.touchedPaths == ["/file.txt"])
        #expect(mutations.last?.fileChanges.first?.diff?.hunks.isEmpty == false)
        #expect(try await workspace.readFile("/file.txt") == "one")
    }

    @Test
    func `pruneMutationHistory bounds the log while keeping sequences monotonic`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspace = Workspace(filesystem: InMemoryFilesystem(), storage: .directory(at: root))
        for index in 0..<5 {
            try await workspace.writeFile("/file.txt", content: "revision \(index)")
        }

        try await workspace.pruneMutationHistory(throughSequence: 3)
        #expect(try await workspace.mutationRecords().map(\.sequence) == [4, 5])

        try await workspace.pruneMutationHistory(throughSequence: 100)
        #expect(try await workspace.mutationRecords().map(\.sequence) == [5])

        try await workspace.writeFile("/file.txt", content: "after prune")
        #expect(try await workspace.mutationRecords().map(\.sequence) == [5, 6])
    }

    @Test
    func `branch writes are isolated and merge creates one merge checkpoint`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/note.txt", content: "base")
        let base = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch(label: "branch start")
        try await branch.writeFile("/note.txt", content: "branch")
        try await branch.writeFile("/new.txt", content: "new")
        let branchHead = try await branch.createCheckpoint(label: "branch head")

        #expect(try await workspace.readFile("/note.txt") == "base")
        #expect(!(await workspace.exists("/new.txt")))

        let branchCheckpoints = try await branch.listCheckpoints()
        #expect(branchCheckpoints.count == 2)
        #expect(branchCheckpoints[0].baseCheckpointId == base.id)
        #expect(branchHead.parentCheckpointId == branchCheckpoints[0].id)
        #expect((try await workspace.listCheckpoints()).map(\.id) == [base.id])

        let merged = try await workspace.merge(branch, label: "merge branch")
        let mutations = try await workspace.mutationRecords()

        #expect(try await workspace.readFile("/note.txt") == "branch")
        #expect(try await workspace.readFile("/new.txt") == "new")
        #expect(merged.parentCheckpointId == base.id)
        #expect(merged.mergedFromWorkspaceId == branch.workspaceId)
        #expect(merged.mergedFromCheckpointId == branchHead.id)
        #expect(merged.summary.touchedPaths.contains("/note.txt"))
        #expect(merged.summary.touchedPaths.contains("/new.txt"))
        #expect(Array(mutations.map(\.kind).suffix(1)) == [.mergeWorkspace])
    }

    @Test
    func `merge conflicts when parent head advanced after branch`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/note.txt", content: "base")
        let base = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/note.txt", content: "branch")

        try await workspace.writeFile("/note.txt", content: "main")
        let advanced = try await workspace.createCheckpoint(label: "main")

        do {
            _ = try await workspace.merge(branch)
            Issue.record("expected merge conflict")
        } catch let error as WorkspaceError {
            guard case let .mergeConflict(parentWorkspaceId, expectedBase, actualHead) = error else {
                Issue.record("unexpected workspace error: \(error)")
                return
            }
            #expect(parentWorkspaceId == workspace.workspaceId)
            #expect(expectedBase == base.id)
            #expect(actualHead == advanced.id)
        }
    }

    @Test
    func `merge refuses when parent has uncheckpointed tracked changes`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/note.txt", content: "base")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/note.txt", content: "branch")
        _ = try await branch.createCheckpoint(label: "branch head")

        // Tracked parent edits after branching, without a checkpoint: the head still matches the
        // branch base, so only the mutation cursor can reveal them.
        try await workspace.writeFile("/parent-only.txt", content: "keep me")

        do {
            _ = try await workspace.merge(branch)
            Issue.record("expected merge to refuse uncheckpointed parent changes")
        } catch let error as WorkspaceError {
            guard case let .mergeUncheckpointedChanges(parentWorkspaceId, baseCursor, currentCursor) = error else {
                Issue.record("unexpected workspace error: \(error)")
                return
            }
            #expect(parentWorkspaceId == workspace.workspaceId)
            #expect(currentCursor > baseCursor)
        }

        #expect(try await workspace.readFile("/parent-only.txt") == "keep me")
        #expect(try await workspace.readFile("/note.txt") == "base")
    }

    @Test
    func `merge allows parent writes made before the branch`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/note.txt", content: "base")
        _ = try await workspace.createCheckpoint(label: "base")
        try await workspace.writeFile("/pre-branch.txt", content: "pre")

        let branch = try await workspace.branch()
        try await branch.writeFile("/note.txt", content: "branch")

        _ = try await workspace.merge(branch)

        #expect(try await workspace.readFile("/note.txt") == "branch")
        #expect(try await workspace.readFile("/pre-branch.txt") == "pre")
    }

    @Test
    func `file backed storage reloads checkpoint snapshot artifacts`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let workspace = Workspace(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )

        try await workspace.writeFile("/note.txt", content: "checkpoint")
        let checkpoint = try await workspace.createCheckpoint(label: "saved")
        try await workspace.writeFile("/note.txt", content: "current")

        let reloaded = Workspace(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            storage: .directory(at: root)
        )
        let persistedCheckpoint = try #require(try await reloaded.checkpoint(id: checkpoint.id))
        let snapshot = try await reloaded.snapshot(for: persistedCheckpoint)
        let restored = InMemoryFilesystem()

        try await Snapshot.restore(snapshot, to: restored)

        #expect(try await workspace.readFile("/note.txt") == "current")
        #expect(try await restored.readFile(path: "/note.txt") == Data("checkpoint".utf8))
        #expect(snapshot.summary(comparedTo: nil) == checkpoint.summary)
    }

    @Test
    func `all public write surfaces append mutation records`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())

        try await workspace.writeFile("/base.txt", content: "x")
        try await workspace.appendFile("/base.txt", content: "y")
        try await workspace.writeData(Data([0, 1, 2]), to: "/bin.dat")
        try await workspace.writeJSON(["a": 1], to: "/config.json", prettyPrinted: false)
        try await workspace.createDirectory(at: "/nested/deep", recursive: true)
        try await workspace.writeFile("/nested/deep/a.txt", content: "a")
        try await workspace.copyItem(from: "/nested/deep/a.txt", to: "/nested/deep/b.txt")
        try await workspace.moveItem(from: "/nested/deep/b.txt", to: "/moved.txt")
        try await workspace.removeItem(at: "/nested", recursive: true)

        _ = try await workspace.applyEdits([
            .writeFile(path: "/batch.txt", content: "line\n"),
        ])
        try await workspace.writeFile("/replace.txt", content: "hello old world")
        _ = try await workspace.applyReplacement(
            ReplacementRequest(pattern: "*.txt", search: "old", replacement: "new")
        )

        let beforeSnapshot = try await workspace.captureSnapshot()
        try await workspace.writeFile("/temporary.txt", content: "gone")
        try await workspace.restoreSnapshot(beforeSnapshot)

        let mutations = try await workspace.mutationRecords()
        let kinds = mutations.map(\.kind)
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
                .applyEdits,
                .writeFile,
                .applyReplacement,
                .writeFile,
                .restoreSnapshot,
            ]
        )
        #expect(try await workspace.readFile("/base.txt") == "xy")
        #expect(try await workspace.readFile("/moved.txt") == "a")
        #expect(try await workspace.readFile("/replace.txt") == "hello new world")
        #expect(!(await workspace.exists("/temporary.txt")))
    }

    @Test
    func `snapshot and rollback errors use WorkspaceError`() async throws {
        let store = FlakySnapshotCheckpointStore()
        let workspace = Workspace(filesystem: InMemoryFilesystem(), store: store)

        try await workspace.writeFile("/note.txt", content: "v1")
        let checkpoint = try await workspace.createCheckpoint(label: "has-snapshot")

        await store.breakLoadingSnapshot(id: checkpoint.snapshotId)

        do {
            _ = try await workspace.snapshot(for: checkpoint)
            Issue.record("expected snapshotNotFound")
        } catch let error as WorkspaceError {
            guard case let .snapshotNotFound(id) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == checkpoint.snapshotId)
        }

        do {
            _ = try await workspace.rollback(to: UUID())
            Issue.record("expected checkpointNotFound")
        } catch let error as WorkspaceError {
            guard case .checkpointNotFound = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func `watchCheckpointEvents receives checkpoints from another workspace sharing the store`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()

        let observer = Workspace(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)
        let producer = Workspace(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)

        let recorder = CheckpointEventRecorder()
        let stream = try await observer.watchCheckpointEvents()
        let task = startCheckpointRecording(stream, into: recorder)
        defer { task.cancel() }

        try await producer.writeFile("/remote.txt", content: "remote")
        let created = try await producer.createCheckpoint(label: "other-instance")

        let events = try await waitForCheckpointEvents(1, recorder: recorder, timeout: .seconds(2))
        #expect(events.count == 1)
        #expect(events[0].kind == .created)
        #expect(events[0].checkpoint.id == created.id)

        try await observer.writeFile("/local.txt", content: "local")
        let observerCheckpoint = try await observer.createCheckpoint(label: "from-observer")
        #expect(observerCheckpoint.parentCheckpointId == created.id)
    }

    @Test
    func `merge mutation includes per-file text diffs`() async throws {
        let workspace = Workspace()
        try await workspace.writeFile("/a.txt", content: "a1\n")
        try await workspace.writeFile("/b.txt", content: "b1\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/a.txt", content: "a2\n")
        try await branch.writeFile("/b.txt", content: "b2\n")

        _ = try await workspace.merge(branch, label: "merge")
        let mutations = try await workspace.mutationRecords()
        let mergeMutation = try #require(mutations.last)

        #expect(mergeMutation.kind == .mergeWorkspace)
        #expect(mergeMutation.fileChanges.map(\.path) == ["/a.txt", "/b.txt"])
        #expect(mergeMutation.fileChanges.allSatisfy { $0.diff?.hunks.isEmpty == false })
        #expect(mergeMutation.diff == nil)
    }

    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("WorkspaceCheckpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
