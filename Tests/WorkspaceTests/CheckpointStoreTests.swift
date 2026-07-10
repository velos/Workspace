import Foundation
import Testing
@testable import Workspace

@Suite("Checkpoint store")
struct CheckpointStoreTests {
    @Test
    func `in-memory store isolates workspaces and assigns mutation sequences`() async throws {
        let store = InMemoryCheckpointStore()
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = Self.sampleSnapshot()
        let checkpoint = Self.sampleCheckpoint(workspaceID: firstID, snapshotID: snapshot.id)

        try await store.saveSnapshot(snapshot, workspaceId: firstID)
        try await store.saveCheckpoint(checkpoint)
        let first = try await store.appendMutation(Self.sampleMutation(workspaceID: firstID, path: "/a"))
        let second = try await store.appendMutation(Self.sampleMutation(workspaceID: firstID, path: "/b"))

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(try await store.loadCheckpoint(id: checkpoint.id, workspaceId: firstID) == checkpoint)
        #expect(try await store.loadSnapshot(id: snapshot.id, workspaceId: firstID) == snapshot)
        #expect(try await store.listMutations(workspaceId: firstID).map(\.sequence) == [1, 2])
        #expect(try await store.listCheckpoints(workspaceId: secondID).isEmpty)
        #expect(try await store.listMutations(workspaceId: secondID).isEmpty)
    }

    @Test
    func `file store persists manifests and deduplicated content-addressed blobs`() async throws {
        let root = try TestSupport.temporaryDirectory("StoreCAS")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let data = Data("shared".utf8)
        let snapshot = Snapshot(
            rootPath: .root,
            entry: .directory(
                .init(
                    path: .root,
                    permissions: .defaultDirectory,
                    children: [
                        .file(.init(path: "/a", data: data, permissions: .defaultFile)),
                        .file(.init(path: "/b", data: data, permissions: .defaultFile)),
                    ]
                )
            )
        )
        let checkpoint = Self.sampleCheckpoint(workspaceID: workspaceID, snapshotID: snapshot.id)
        let writer = FileCheckpointStore(rootDirectory: root)
        try await writer.saveSnapshot(snapshot, workspaceId: workspaceID)
        try await writer.saveCheckpoint(checkpoint)

        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.loadSnapshot(id: snapshot.id, workspaceId: workspaceID) == snapshot)
        #expect(try await reader.loadCheckpoint(id: checkpoint.id, workspaceId: workspaceID) == checkpoint)
        #expect(
            try await reader.readSnapshotFile(
                id: snapshot.id,
                workspaceId: workspaceID,
                path: "/a",
                offset: 1,
                length: 3
            ) == Data("har".utf8)
        )

        let blobs = root.appendingPathComponent(workspaceID.uuidString).appendingPathComponent("blobs")
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        #expect(names == [SHA256.hexDigest(of: data)])
    }

    @Test
    func `concurrent store instances assign one monotonic mutation sequence`() async throws {
        let root = try TestSupport.temporaryDirectory("StoreConcurrent")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let first = FileCheckpointStore(rootDirectory: root)
        let second = FileCheckpointStore(rootDirectory: root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    _ = try await store.appendMutation(
                        Self.sampleMutation(workspaceID: workspaceID, path: WorkspacePath(normalizing: "/\(index)"))
                    )
                }
            }
            try await group.waitForAll()
        }

        let records = try await FileCheckpointStore(rootDirectory: root).listMutations(workspaceId: workspaceID)
        #expect(records.map(\.sequence) == Array(1...20))
        #expect(Set(records.flatMap { $0.changes.touchedPaths }).count == 20)
    }

    @Test
    func `mutation pruning retains the sequence cursor`() async throws {
        let root = try TestSupport.temporaryDirectory("StorePrune")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        for index in 0..<5 {
            _ = try await store.appendMutation(
                Self.sampleMutation(workspaceID: workspaceID, path: WorkspacePath(normalizing: "/\(index)"))
            )
        }

        try await store.pruneMutations(workspaceId: workspaceID, throughSequence: 100)
        #expect(try await store.listMutations(workspaceId: workspaceID).map(\.sequence) == [5])
        let next = try await store.appendMutation(Self.sampleMutation(workspaceID: workspaceID, path: "/next"))
        #expect(next.sequence == 6)
    }

    @Test
    func `unsupported store versions are rejected`() async throws {
        let root = try TestSupport.temporaryDirectory("StoreVersion")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let directory = root.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"version\":999}".utf8).write(to: directory.appendingPathComponent("format.json"))

        let store = FileCheckpointStore(rootDirectory: root)
        await #expect(throws: WorkspaceError.self) {
            _ = try await store.listMutations(workspaceId: workspaceID)
        }
    }

    private static func sampleSnapshot() -> Snapshot {
        Snapshot(
            rootPath: .root,
            entry: .directory(
                .init(
                    path: .root,
                    permissions: .defaultDirectory,
                    children: [.file(.init(path: "/note", data: Data("note".utf8), permissions: .defaultFile))]
                )
            )
        )
    }

    private static func sampleCheckpoint(workspaceID: UUID, snapshotID: UUID) -> Checkpoint {
        Checkpoint(
            workspaceId: workspaceID,
            label: "test",
            parentCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotID,
            summary: ChangeSet().summary
        )
    }

    private static func sampleMutation(workspaceID: UUID, path: WorkspacePath) -> Mutation {
        Mutation(
            sequence: 0,
            workspaceID: workspaceID,
            operation: .edit,
            changes: ChangeSet(
                changes: [.init(path: path, kind: .file, effect: .created)]
            )
        )
    }
}
