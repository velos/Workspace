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
        let summary = Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let snapshot = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .directory(
                Snapshot.Directory(path: .root, permissions: .defaultDirectory, children: [])
            )
        )

        let cpEarly = Checkpoint(
            id: UUID(),
            workspaceId: workspaceA,
            label: "a",
            createdAt: Date(timeIntervalSince1970: 100),
            parentCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )

        let cpLate = Checkpoint(
            id: UUID(),
            workspaceId: workspaceA,
            label: "b",
            createdAt: Date(timeIntervalSince1970: 200),
            parentCheckpointId: cpEarly.id,
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
            kind: .writeFile,
            touchedPaths: ["/x"],
            fileChanges: []
        )
        let m1 = MutationRecord(
            sequence: 1,
            workspaceId: workspaceA,
            kind: .writeFile,
            touchedPaths: ["/y"],
            fileChanges: []
        )
        try await store.appendMutation(m3)
        try await store.appendMutation(m1)

        let mutations = try await store.listMutationRecords(workspaceId: workspaceA)
        #expect(mutations.map(\.sequence) == [1, 2])

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
        let summary = Checkpoint.Summary(changeCount: 1, touchedPaths: ["/f"], hasTextDiffs: true)

        let snapshot = Snapshot(
            id: snapshotId,
            rootPath: .root,
            entry: .file(
                Snapshot.File(path: "/f", data: Data("hi".utf8), permissions: .defaultFile)
            )
        )

        let checkpoint = Checkpoint(
            workspaceId: workspaceId,
            label: "disk",
            parentCheckpointId: nil,
            firstMutationSequence: 1,
            lastMutationSequence: 2,
            mutationCursor: 2,
            snapshotId: snapshotId,
            summary: summary
        )

        let mutation = MutationRecord(
            sequence: 1,
            workspaceId: workspaceId,
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
    func `InMemoryCheckpointStore saveCheckpoint overwrites an existing checkpoint id`() async throws {
        let store = InMemoryCheckpointStore()
        let workspaceId = UUID()
        let sharedId = UUID()
        let snapshotId = UUID()
        let summary = Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let first = Checkpoint(
            id: sharedId,
            workspaceId: workspaceId,
            label: "first",
            createdAt: Date(timeIntervalSince1970: 50),
            parentCheckpointId: nil,
            firstMutationSequence: nil,
            lastMutationSequence: nil,
            mutationCursor: 0,
            snapshotId: snapshotId,
            summary: summary
        )
        var second = first
        second.label = "second"
        second.createdAt = Date(timeIntervalSince1970: 150)

        try await store.saveCheckpoint(first)
        try await store.saveCheckpoint(second)

        let loaded = try await store.loadCheckpoint(id: sharedId, workspaceId: workspaceId)
        #expect(loaded == second)

        let listed = try await store.listCheckpoints(workspaceId: workspaceId)
        #expect(listed.count == 1)
        #expect(listed[0].label == "second")
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
            kind: .writeFile,
            touchedPaths: ["/b"],
            fileChanges: []
        )
        let m1 = MutationRecord(
            sequence: 1,
            workspaceId: workspaceId,
            kind: .writeFile,
            touchedPaths: ["/a"],
            fileChanges: []
        )

        try await storeA.appendMutation(m2)
        try await storeA.appendMutation(m1)

        let storeB = FileCheckpointStore(rootDirectory: root)
        let merged = try await storeB.listMutationRecords(workspaceId: workspaceId)
        #expect(merged.map(\.sequence) == [1, 2])
        #expect(merged.map(\.touchedPaths) == [["/b"], ["/a"]])

        let m3 = MutationRecord(
            sequence: 3,
            workspaceId: workspaceId,
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
        let summary = Checkpoint.Summary(changeCount: 0, touchedPaths: [], hasTextDiffs: false)

        let first = Checkpoint(
            id: checkpointId,
            workspaceId: workspaceId,
            label: "v1",
            parentCheckpointId: nil,
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

    @Test
    func `FileCheckpointStore listMutationRecords returns empty array when no log file exists`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let store = FileCheckpointStore(rootDirectory: root)

        let mutations = try await store.listMutationRecords(workspaceId: workspaceId)
        #expect(mutations.isEmpty)

        let workspaceRoot = root.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
        let mutationsFile = workspaceRoot.appendingPathComponent("mutations.jsonl")
        #expect(!FileManager.default.fileExists(atPath: mutationsFile.path))
    }

    @Test
    func `FileCheckpointStore migrates legacy mutations json array to jsonl`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let workspaceRoot = root.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let legacyURL = workspaceRoot.appendingPathComponent("mutations.json", isDirectory: false)
        let jsonlURL = workspaceRoot.appendingPathComponent("mutations.jsonl", isDirectory: false)

        let stored = MutationRecord(
            sequence: 99,
            workspaceId: workspaceId,
            kind: .writeFile,
            touchedPaths: ["/legacy.txt"],
            fileChanges: []
        )
        let data = try JSONEncoder().encode([stored])
        try data.write(to: legacyURL)

        let store = FileCheckpointStore(rootDirectory: root)
        let loaded = try await store.listMutationRecords(workspaceId: workspaceId)
        #expect(loaded.count == 1)
        #expect(loaded[0].touchedPaths == ["/legacy.txt"])
        #expect(loaded[0].sequence == 99)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: jsonlURL.path))
    }

    @Test
    func `FileCheckpointStore listMutationRecords treats an empty mutations file as no records`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let workspaceRoot = root.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let mutationsFile = workspaceRoot.appendingPathComponent("mutations.jsonl")
        try Data().write(to: mutationsFile)

        let store = FileCheckpointStore(rootDirectory: root)

        let mutations = try await store.listMutationRecords(workspaceId: workspaceId)
        #expect(mutations.isEmpty)

        let appended = MutationRecord(
            sequence: 0,
            workspaceId: workspaceId,
            kind: .writeFile,
            touchedPaths: ["/x"],
            fileChanges: []
        )
        let written = try await store.appendMutation(appended)

        let after = try await store.listMutationRecords(workspaceId: workspaceId)
        #expect(after == [written])
        #expect(written.sequence == 1)
    }

    @Test
    func `FileCheckpointStore appendMutation serializes concurrent writers without losing records`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let writerCount = 8
        let perWriter = 25
        let stores = (0..<writerCount).map { _ in FileCheckpointStore(rootDirectory: root) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writerIndex in 0..<writerCount {
                let store = stores[writerIndex]
                group.addTask {
                    for stepIndex in 0..<perWriter {
                        let path = WorkspacePath(normalizing: "/w\(writerIndex)/s\(stepIndex)")
                        let mutation = MutationRecord(
                            sequence: 0,
                            workspaceId: workspaceId,
                            kind: .writeFile,
                            touchedPaths: [path],
                            fileChanges: []
                        )
                        try await store.appendMutation(mutation)
                    }
                }
            }
            try await group.waitForAll()
        }

        let reader = FileCheckpointStore(rootDirectory: root)
        let mutations = try await reader.listMutationRecords(workspaceId: workspaceId)

        #expect(mutations.count == writerCount * perWriter)
        let expectedSequences = Set(1...(writerCount * perWriter))
        #expect(Set(mutations.map(\.sequence)) == expectedSequences)
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
