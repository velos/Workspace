import Foundation
import Testing
@testable import Workspace

@Suite("CheckpointStore")
struct CheckpointStoreTests {
    @Test
    func `InMemoryCheckpointStore persists checkpoints snapshots and mutations per workspace`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let snapshot = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .directory(
                Snapshot.Directory(path: .root, permissions: .defaultDirectory, children: [])
            )
        )

        let cpEarly = History.Checkpoint(
            id: UUID(),
            workspaceId: workspaceA,
            sessionId: nil,
            scope: .shared,
            label: "a",
            createdAt: Date(timeIntervalSince1970: 100),
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )

        let cpLate = History.Checkpoint(
            id: UUID(),
            workspaceId: workspaceA,
            sessionId: nil,
            scope: .shared,
            label: "b",
            createdAt: Date(timeIntervalSince1970: 200),
            parentCheckpointId: cpEarly.id,
            baseSharedCheckpointId: nil,
            firstMutationSequence: 1,
            lastMutationSequence: 1,
            mutationCursor: 1,
            snapshotId: snapshotId,
            summary: summary
        )

        try await store.saveSnapshot(snapshot, workspaceId: workspaceA)
        try await store.saveCheckpoint(cpLate)
        try await store.saveCheckpoint(cpEarly)

        let listed = try await store.listCheckpoints(workspaceId: workspaceA)
        #expect(listed.map(\.id) == [cpEarly.id, cpLate.id])

        let loadedEarly = try await store.loadCheckpoint(id: cpEarly.id, workspaceId: workspaceA)
        #expect(loadedEarly == cpEarly)

        let loadedMissing = try await store.loadCheckpoint(id: UUID(), workspaceId: workspaceA)
        #expect(loadedMissing == nil)

        #expect(try await store.listCheckpoints(workspaceId: workspaceB).isEmpty)

        let m3 = MutationRecord(
            sequence: 3,
            workspaceId: workspaceA,
            sessionId: nil,
            scope: .shared,
            kind: .writeFile,
            touchedPaths: ["/x"],
            fileChanges: []
        )
        let m1 = MutationRecord(
            sequence: 1,
            workspaceId: workspaceA,
            sessionId: nil,
            scope: .shared,
            kind: .writeFile,
            touchedPaths: ["/y"],
            fileChanges: []
        )
        try await store.appendMutation(m3)
        try await store.appendMutation(m1)

        let mutations = try await store.listMutationRecords(workspaceId: workspaceA)
        #expect(mutations.map(\.sequence) == [1, 3])

        let reloadedSnapshot = try await store.loadSnapshot(id: snapshotId, workspaceId: workspaceA)
        #expect(reloadedSnapshot == snapshot)
        #expect(try await store.loadSnapshot(id: UUID(), workspaceId: workspaceA) == nil)
    }

    @Test
    func `FileCheckpointStore roundtrips data on disk across actor instances`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 1, touchedPaths: ["/f"], hasTextDiffs: true)

        let snapshot = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .file(
                Snapshot.File(path: "/f", data: Data("hi".utf8), permissions: .defaultFile)
            )
        )

        let checkpoint = History.Checkpoint(
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: "disk",
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: 1,
            lastMutationSequence: 2,
            mutationCursor: 2,
            snapshotId: snapshotId,
            summary: summary
        )

        let mutation = MutationRecord(
            sequence: 1,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            kind: .writeFile,
            touchedPaths: ["/f"],
            fileChanges: []
        )

        let writer = FileCheckpointStore(rootDirectory: root)
        try await writer.saveSnapshot(snapshot, workspaceId: workspaceId)
        try await writer.saveCheckpoint(checkpoint)
        try await writer.appendMutation(mutation)

        let reader = FileCheckpointStore(rootDirectory: root)
        let checkpoints = try await reader.listCheckpoints(workspaceId: workspaceId)
        #expect(checkpoints == [checkpoint])

        let loaded = try await reader.loadCheckpoint(id: checkpoint.id, workspaceId: workspaceId)
        #expect(loaded == checkpoint)

        let loadedSnap = try await reader.loadSnapshot(id: snapshotId, workspaceId: workspaceId)
        #expect(loadedSnap == snapshot)

        let mutations = try await reader.listMutationRecords(workspaceId: workspaceId)
        #expect(mutations == [mutation])

        #expect(try await reader.listCheckpoints(workspaceId: UUID()).isEmpty)
        #expect(try await reader.listMutationRecords(workspaceId: UUID()).isEmpty)
    }

    @Test
    func `InMemoryCheckpointStore saveSnapshot replaces an existing snapshot id`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()
        let snapshotId = UUID()

        let first = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .file(Snapshot.File(path: "/a", data: Data("1".utf8), permissions: .defaultFile))
        )
        let second = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .file(Snapshot.File(path: "/a", data: Data("2".utf8), permissions: .defaultFile))
        )

        try await store.saveSnapshot(first, workspaceId: workspaceId)
        try await store.saveSnapshot(second, workspaceId: workspaceId)

        let loaded = try await store.loadSnapshot(id: snapshotId, workspaceId: workspaceId)
        #expect(loaded == second)
    }

    @Test
    func `InMemoryCheckpointStore loadCheckpoint returns the first saved match when ids collide`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()
        let sharedId = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let first = History.Checkpoint(
            id: sharedId,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: "first",
            createdAt: Date(timeIntervalSince1970: 50),
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        let second = History.Checkpoint(
            id: sharedId,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: "second",
            createdAt: Date(timeIntervalSince1970: 150),
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )

        try await store.saveCheckpoint(first)
        try await store.saveCheckpoint(second)

        let loaded = try await store.loadCheckpoint(id: sharedId, workspaceId: workspaceId)
        #expect(loaded == first)

        let listed = try await store.listCheckpoints(workspaceId: workspaceId)
        #expect(listed.count == 2)
    }

    @Test
    func `FileCheckpointStore appendMutation merges and sorts existing log on disk`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let storeA = FileCheckpointStore(rootDirectory: root)

        let m2 = MutationRecord(
            sequence: 2,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            kind: .writeFile,
            touchedPaths: ["/b"],
            fileChanges: []
        )
        let m1 = MutationRecord(
            sequence: 1,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            kind: .writeFile,
            touchedPaths: ["/a"],
            fileChanges: []
        )

        try await storeA.appendMutation(m2)
        try await storeA.appendMutation(m1)

        let storeB = FileCheckpointStore(rootDirectory: root)
        let merged = try await storeB.listMutationRecords(workspaceId: workspaceId)
        #expect(merged.map(\.sequence) == [1, 2])
        #expect(merged.map(\.touchedPaths) == [["/a"], ["/b"]])

        let m3 = MutationRecord(
            sequence: 3,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            kind: .appendFile,
            touchedPaths: ["/c"],
            fileChanges: []
        )
        try await storeB.appendMutation(m3)

        let storeC = FileCheckpointStore(rootDirectory: root)
        #expect(try await storeC.listMutationRecords(workspaceId: workspaceId).map(\.sequence) == [1, 2, 3])
    }

    @Test
    func `FileCheckpointStore saveCheckpoint overwrites the same id file`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let checkpointId = UUID()
        let snapshotId = UUID()
        let summary = History.Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let first = History.Checkpoint(
            id: checkpointId,
            workspaceId: workspaceId,
            sessionId: nil,
            scope: .shared,
            label: "v1",
            parentCheckpointId: nil,
            baseSharedCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        var second = first
        second.label = "v2"

        let writer = FileCheckpointStore(rootDirectory: root)
        try await writer.saveCheckpoint(first)
        try await writer.saveCheckpoint(second)

        let reader = FileCheckpointStore(rootDirectory: root)
        let loaded = try await reader.loadCheckpoint(id: checkpointId, workspaceId: workspaceId)
        #expect(loaded?.label == "v2")

        let listed = try await reader.listCheckpoints(workspaceId: workspaceId)
        #expect(listed.count == 1)
        #expect(listed[0].label == "v2")
    }

    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("CheckpointStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
