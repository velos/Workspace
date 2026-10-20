import Foundation
import Testing
@testable import Workspace

@Suite("Checkpoint store")
struct CheckpointStoreTests {
    @Test(arguments: [false, true])
    func `retraction never reuses an observed sequence`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("SequenceRetraction")
        defer { TestSupport.remove(root) }
        let id = UUID()
        var store: any CheckpointStore = diskBacked
            ? FileCheckpointStore(rootDirectory: root) : InMemoryCheckpointStore()
        let first = try await store.appendMutation(Self.sampleMutation(workspaceID: id, path: "/a"))
        let retracted = try await store.appendMutation(Self.sampleMutation(workspaceID: id, path: "/b"))
        try await store.removeMutation(sequence: retracted.sequence, workspaceId: id)
        if diskBacked { store = FileCheckpointStore(rootDirectory: root) }
        let afterRetraction = try await store.captureRevision(from: InMemoryFileSystem(), draft: Self.sampleDraft(workspaceID: id))
        #expect(afterRetraction.mutationCursor == 2)
        let next = try await store.appendMutation(Self.sampleMutation(workspaceID: id, path: "/c"))
        let assigned: [Int] = [first.sequence, retracted.sequence, next.sequence]
        #expect(assigned == [1, 2, 3])
        #expect(try await store.listMutations(workspaceId: id).map(\.sequence) == [1, 3])
        try await store.removeMutation(sequence: first.sequence, workspaceId: id)
        try await store.removeMutation(sequence: next.sequence, workspaceId: id)
        if diskBacked { store = FileCheckpointStore(rootDirectory: root) }
        let emptyCheckpoint = try await store.saveRevision(Self.sampleSnapshot(), draft: Self.sampleDraft(workspaceID: id))
        #expect(emptyCheckpoint.mutationCursor == 3)
        let emptyCapture = try await store.captureRevision(from: InMemoryFileSystem(), draft: Self.sampleDraft(workspaceID: id))
        #expect(emptyCapture.mutationCursor == 3)
        let afterEmpty = try await store.appendMutation(Self.sampleMutation(workspaceID: id, path: "/d"))
        #expect(afterEmpty.sequence == 4)
        let other = try await store.appendMutation(Self.sampleMutation(workspaceID: UUID(), path: "/a"))
        #expect(other.sequence == 1)
    }

    @Test
    func `reserved torn appends preserve the cursor`() async throws {
        let root = try TestSupport.temporaryDirectory("SequenceSidecar")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        try await store.appendMutation(Self.sampleMutation(workspaceID: id, path: "/a"))
        let directory = root.appendingPathComponent(id.uuidString)
        let sidecar = directory.appendingPathComponent("mutations.sequence.json")
        // Simulate a reserved sequence whose append failed mid-UTF8.
        let state = #"{"highWaterMark":7,"retractionEpoch":3}"#
        try Data(state.utf8).write(to: sidecar)
        let log = directory.appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0x22, 0xE2, 0x82]))
        try handle.close()
        let checkpoint = try await store.captureRevision(from: InMemoryFileSystem(), draft: Self.sampleDraft(workspaceID: id))
        #expect(checkpoint.mutationCursor == 7)
        #expect(try Data(contentsOf: log).last == UInt8(ascii: "\n"))
        try await store.removeMutation(sequence: 1, workspaceId: id)
        let page = try await store.listMutations(workspaceId: id, afterSequence: 0)
        #expect(page.records.isEmpty)
        #expect(page.retractionEpoch == 4)
        let next = try await FileCheckpointStore(rootDirectory: root).appendMutation(Self.sampleMutation(workspaceID: id, path: "/next"))
        #expect(next.sequence == 8)
    }

    @Test
    func `in-memory store isolates workspaces and assigns mutation sequences`() async throws {
        let store = InMemoryCheckpointStore()
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = Self.sampleSnapshot()
        let checkpoint = try await store.saveRevision(snapshot, draft: Self.sampleDraft(workspaceID: firstID))
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
        let writer = FileCheckpointStore(rootDirectory: root)
        let checkpoint = try await writer.saveRevision(snapshot, draft: Self.sampleDraft(workspaceID: workspaceID))

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
    func `incremental mutation reads cross byte chunks and tolerate only a torn tail`() async throws {
        let root = try TestSupport.temporaryDirectory("StoreIncremental")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        for index in 1...5 {
            // A record longer than the backward-read chunk, with multibyte characters spanning
            // chunk boundaries. No filesystem entry is created for this recorded path.
            let path = index == 3 ? "/" + String(repeating: "🎉", count: 20000) : "/\(index)"
            _ = try await store.appendMutation(Self.sampleMutation(workspaceID: workspaceID, path: WorkspacePath(normalizing: path)))
        }
        #expect(try await store.listMutations(workspaceId: workspaceID, afterSequence: 1).records.map(\.sequence) == [2, 3, 4, 5])
        #expect(try await store.listMutations(workspaceId: workspaceID, afterSequence: 3).records.map(\.sequence) == [4, 5])
        #expect(try await store.listMutations(workspaceId: workspaceID, afterSequence: 5).records.isEmpty)

        let log = root.appendingPathComponent(workspaceID.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0x22, 0xE2, 0x82]))
        try handle.close()
        #expect(try await store.listMutations(workspaceId: workspaceID, afterSequence: 1).records.map(\.sequence) == [2, 3, 4, 5])
        let next = try await store.appendMutation(Self.sampleMutation(workspaceID: workspaceID, path: "/6"))
        #expect(next.sequence == 6)
        try await store.pruneMutations(workspaceId: workspaceID, throughSequence: 5)
        #expect(try await store.listMutations(workspaceId: workspaceID, afterSequence: 5).records.map(\.sequence) == [6])

        let corrupt = try FileHandle(forWritingTo: log)
        try corrupt.seekToEnd()
        try corrupt.write(contentsOf: Data([0x7B, 0x22, 0xE2, 0x82, 0x0A]))
        try corrupt.close()
        await #expect(throws: DecodingError.self) {
            _ = try await store.listMutations(workspaceId: workspaceID, afterSequence: 6)
        }
    }

    @Test(arguments: [nil, "{}", "not JSON", #"{"version":1}"#,
                      #"{"format":"other","version":1}"#,
                      #"{"format":"workspace-history","version":0}"#,
                      #"{"format":"workspace-history","version":2}"#] as [String?])
    func `invalid store markers require deleting the history directory`(marker: String?) async throws {
        let root = try TestSupport.temporaryDirectory("StoreFormat")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let directory = root.appendingPathComponent(workspaceID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = directory.appendingPathComponent("format.json")
        if let marker { try Data(marker.utf8).write(to: format) }

        let store = FileCheckpointStore(rootDirectory: root)
        // Neither opening for writes nor reading may silently initialize an existing directory.
        for writing in [false, true] {
            do {
                if writing { try await store.prepare(workspaceId: workspaceID) }
                else { _ = try await store.listMutations(workspaceId: workspaceID) }
                Issue.record("invalid store marker was accepted")
            } catch let error as WorkspaceError {
                guard case let .storageCorrupted(message) = error else { throw error }
                #expect(message.contains("delete the history directory"))
                #expect(message.contains(directory.path))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == (marker == nil ? [] : ["format.json"]))
        if let marker { #expect(try String(contentsOf: format, encoding: .utf8) == marker) }
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

    private static func sampleDraft(workspaceID: UUID) -> CheckpointDraft {
        CheckpointDraft(
            workspaceID: workspaceID,
            label: "test",
            preferredParentID: nil,
            origin: .manual
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
