import Foundation
import Testing
@testable import Workspace

private actor CountingCheckpointStore: CheckpointStore {
    private let checkpoints: [Checkpoint]
    private let snapshots: [UUID: Snapshot]
    private let mutations: [MutationRecord]
    private var checkpointListCount = 0
    private var mutationListCount = 0

    init(
        checkpoints: [Checkpoint] = [],
        snapshots: [UUID: Snapshot] = [:],
        mutations: [MutationRecord] = []
    ) {
        self.checkpoints = checkpoints
        self.snapshots = snapshots
        self.mutations = mutations
    }

    func saveCheckpoint(_ checkpoint: Checkpoint) async throws {}

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        checkpoints.first { $0.id == id && $0.workspaceId == workspaceId }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        checkpointListCount += 1
        try await Task.sleep(for: .milliseconds(20))
        return checkpoints.filter { $0.workspaceId == workspaceId }
    }

    func saveSnapshot(_ snapshot: Snapshot, workspaceId: UUID) async throws {}

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        snapshots[id]
    }

    func appendMutation(_ mutation: MutationRecord) async throws -> MutationRecord {
        mutation
    }

    func listMutationRecords(workspaceId: UUID) async throws -> [MutationRecord] {
        mutationListCount += 1
        try await Task.sleep(for: .milliseconds(20))
        return mutations.filter { $0.workspaceId == workspaceId }
    }

    func listCounts() -> (checkpoints: Int, mutations: Int) {
        (checkpointListCount, mutationListCount)
    }
}

@Suite("Workspace internals")
struct WorkspaceInternalsTests {
    @Test
    func `ensureLoaded coalesces concurrent store loads`() async throws {
        let workspaceId = UUID()
        let store = CountingCheckpointStore()
        let workspace = Workspace(
            workspaceId: workspaceId,
            filesystem: InMemoryFilesystem(),
            store: store
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await workspace.ensureLoaded()
                }
            }
            try await group.waitForAll()
        }

        let counts = await store.listCounts()
        #expect(counts.checkpoints == 1)
        #expect(counts.mutations == 1)
    }

    @Test
    func `appendMutation canonicalizes touched paths and file changes`() async throws {
        let workspace = Workspace()
        try await workspace.ensureLoaded()

        try await workspace.appendMutation(
            kind: .applyEdits,
            touchedPaths: ["/b.txt", "/a.txt", "/b.txt"],
            fileChanges: [
                FileEdit.FileChange(path: "/b.txt", kind: .file, effect: .modified),
                FileEdit.FileChange(path: "/a.txt", kind: .file, effect: .created),
                FileEdit.FileChange(path: "/a.txt", kind: .file, effect: .deleted),
            ],
            diff: nil
        )

        let mutation = try #require(try await workspace.mutationRecords().first)
        #expect(mutation.sequence == 1)
        #expect(mutation.touchedPaths == ["/a.txt", "/b.txt"])
        #expect(mutation.fileChanges.map(\.path) == ["/a.txt", "/a.txt", "/b.txt"])
        #expect(mutation.fileChanges.map(\.effect) == [.created, .deleted, .modified])
    }

    @Test
    func `pollCheckpointEvents refreshes mutation cursor before the next local checkpoint`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()
        let observer = Workspace(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)
        let producer = Workspace(workspaceId: workspaceId, filesystem: InMemoryFilesystem(), store: store)

        let stream = try await observer.watchCheckpointEvents()
        let task = Task {
            for await _ in stream {}
        }
        defer { task.cancel() }

        try await producer.writeFile("/remote.txt", content: "remote")
        let remote = try await producer.createCheckpoint(label: "remote")

        await observer.pollCheckpointEvents()
        try await observer.writeFile("/local.txt", content: "local")
        let local = try await observer.createCheckpoint(label: "local")
        let localMutation = try #require(try await observer.mutationRecords().last)

        #expect(local.parentCheckpointId == remote.id)
        #expect(local.firstMutationSequence == 2)
        #expect(local.lastMutationSequence == 2)
        #expect(localMutation.sequence == 2)
    }

    @Test
    func `snapshotDelta captures type changes symlink updates and directory permission changes`() async throws {
        let workspace = Workspace()
        let original = Snapshot.Entry.directory(
            Snapshot.Directory(
                path: .root,
                permissions: .defaultDirectory,
                children: [
                    .file(Snapshot.File(path: "/node", data: Data("old\n".utf8), permissions: .defaultFile)),
                    .symlink(Snapshot.Symlink(path: "/link", target: "/node", permissions: .defaultFile)),
                    .directory(Snapshot.Directory(path: "/docs", permissions: POSIXPermissions(0o755), children: [])),
                ]
            )
        )
        let updated = Snapshot.Entry.directory(
            Snapshot.Directory(
                path: .root,
                permissions: .defaultDirectory,
                children: [
                    .directory(
                        Snapshot.Directory(
                            path: "/node",
                            permissions: .defaultDirectory,
                            children: [
                                .file(
                                    Snapshot.File(
                                        path: "/node/child.txt",
                                        data: Data("new\n".utf8),
                                        permissions: .defaultFile
                                    )
                                ),
                            ]
                        )
                    ),
                    .symlink(Snapshot.Symlink(path: "/link", target: "/node/child.txt", permissions: .defaultFile)),
                    .directory(Snapshot.Directory(path: "/docs", permissions: POSIXPermissions(0o700), children: [])),
                ]
            )
        )

        let delta = await workspace.snapshotDelta(from: original, to: updated)
        let changesByPath = Dictionary(uniqueKeysWithValues: delta.fileChanges.map { ($0.path, $0) })

        #expect(delta.hasChanges)
        #expect(delta.touchedPaths == ["/docs", "/link", "/node", "/node/child.txt"])
        #expect(delta.fileChanges.map(\.path) == ["/link", "/node", "/node/child.txt"])
        #expect(changesByPath["/link"]?.kind == .symlink)
        #expect(changesByPath["/link"]?.effect == .modified)
        #expect(changesByPath["/link"]?.diff == nil)
        #expect(changesByPath["/node"]?.effect == .deleted)
        #expect(changesByPath["/node"]?.diff?.hunks.isEmpty == false)
        #expect(changesByPath["/node/child.txt"]?.effect == .created)
        #expect(changesByPath["/node/child.txt"]?.diff?.hunks.isEmpty == false)
    }

    @Test
    func `snapshotDelta captures created and deleted symlinks without text diffs`() async throws {
        let workspace = Workspace()
        let original = Snapshot.Entry.directory(
            Snapshot.Directory(
                path: .root,
                permissions: .defaultDirectory,
                children: [
                    .file(Snapshot.File(path: "/target.txt", data: Data("target\n".utf8), permissions: .defaultFile)),
                    .symlink(Snapshot.Symlink(path: "/deleted-link", target: "/target.txt", permissions: .defaultFile)),
                ]
            )
        )
        let updated = Snapshot.Entry.directory(
            Snapshot.Directory(
                path: .root,
                permissions: .defaultDirectory,
                children: [
                    .file(Snapshot.File(path: "/target.txt", data: Data("target\n".utf8), permissions: .defaultFile)),
                    .symlink(Snapshot.Symlink(path: "/created-link", target: "/target.txt", permissions: .defaultFile)),
                ]
            )
        )

        let delta = await workspace.snapshotDelta(from: original, to: updated)
        let changesByPath = Dictionary(uniqueKeysWithValues: delta.fileChanges.map { ($0.path, $0) })

        #expect(delta.touchedPaths == ["/created-link", "/deleted-link"])
        #expect(delta.fileChanges.map(\.path) == ["/created-link", "/deleted-link"])
        #expect(changesByPath["/created-link"]?.kind == .symlink)
        #expect(changesByPath["/created-link"]?.effect == .created)
        #expect(changesByPath["/created-link"]?.diff == nil)
        #expect(changesByPath["/deleted-link"]?.kind == .symlink)
        #expect(changesByPath["/deleted-link"]?.effect == .deleted)
        #expect(changesByPath["/deleted-link"]?.diff == nil)
    }

    @Test
    func `performBinaryWrite through an existing symlink records symlink metadata and updates target`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/target.bin", data: Data([1, 2, 3]), append: false)
        try await filesystem.createSymlink(path: "/alias.bin", target: "/target.bin")
        let workspace = Workspace(filesystem: filesystem)

        try await workspace.writeData(Data([4, 5, 6]), to: "/alias.bin")
        try await workspace.writeData(Data([4, 5, 6]), to: "/alias.bin")

        let mutations = try await workspace.mutationRecords()
        let first = try #require(mutations.first)
        let second = try #require(mutations.last)

        #expect(try await filesystem.readFile(path: "/target.bin") == Data([4, 5, 6]))
        #expect(try await filesystem.readSymlink(path: "/alias.bin") == "/target.bin")
        #expect(first.kind == .writeData)
        #expect(first.touchedPaths == ["/alias.bin"])
        #expect(first.fileChanges.count == 1)
        #expect(first.fileChanges[0].path == "/alias.bin")
        #expect(first.fileChanges[0].kind == .symlink)
        #expect(first.fileChanges[0].effect == .modified)
        #expect(first.fileChanges[0].status == .applied)
        #expect(first.fileChanges[0].diff == nil)
        #expect(second.sequence == 2)
        #expect(second.fileChanges[0].kind == .symlink)
        #expect(second.fileChanges[0].effect == .unchanged)
    }

    @Test
    func `untrackedRestore restores root snapshots without appending a mutation`() async throws {
        let workspace = Workspace()

        try await workspace.writeFile("/kept.txt", content: "one")
        let snapshot = try await workspace.captureSnapshot()
        try await workspace.writeFile("/extra.txt", content: "two")
        let before = try await workspace.mutationRecords().count

        try await workspace.untrackedRestore(snapshot)
        let after = try await workspace.mutationRecords().count

        #expect(before == 2)
        #expect(after == before)
        #expect(try await workspace.readFile("/kept.txt") == "one")
        #expect(!(await workspace.exists("/extra.txt")))
    }
}
