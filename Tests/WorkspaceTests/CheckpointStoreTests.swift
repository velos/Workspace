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

    @Test
    func `FileCheckpointStore skips and repairs a torn trailing mutation line`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let store = FileCheckpointStore(rootDirectory: root)

        for index in 0..<2 {
            let mutation = MutationRecord(
                sequence: 0,
                workspaceId: workspaceId,
                kind: .writeFile,
                touchedPaths: [WorkspacePath(normalizing: "/file-\(index).txt")],
                fileChanges: []
            )
            try await store.appendMutation(mutation)
        }

        // Simulate a crash mid-append: a partial record with no trailing newline.
        let jsonl = mutationsJsonlURL(root: root, workspaceId: workspaceId)
        let handle = try FileHandle(forWritingTo: jsonl)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":3,\"worksp".utf8))
        try handle.close()

        // Reads skip the torn tail instead of poisoning the whole log.
        let reader = FileCheckpointStore(rootDirectory: root)
        let beforeRepair = try await reader.listMutationRecords(workspaceId: workspaceId)
        #expect(beforeRepair.map(\.sequence) == [1, 2])

        // The next append truncates the torn tail and continues the sequence.
        let appended = try await reader.appendMutation(
            MutationRecord(
                sequence: 0,
                workspaceId: workspaceId,
                kind: .writeFile,
                touchedPaths: [WorkspacePath(normalizing: "/file-2.txt")],
                fileChanges: []
            )
        )
        #expect(appended.sequence == 3)

        let afterRepair = try await reader.listMutationRecords(workspaceId: workspaceId)
        #expect(afterRepair.map(\.sequence) == [1, 2, 3])
        #expect(afterRepair.allSatisfy { $0.workspaceId == workspaceId })
    }

    @Test
    func `FileCheckpointStore still surfaces corruption before the final line`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let store = FileCheckpointStore(rootDirectory: root)

        for index in 0..<2 {
            let mutation = MutationRecord(
                sequence: 0,
                workspaceId: workspaceId,
                kind: .writeFile,
                touchedPaths: [WorkspacePath(normalizing: "/file-\(index).txt")],
                fileChanges: []
            )
            try await store.appendMutation(mutation)
        }

        // Corrupt the first record while keeping the file newline-terminated: this is real
        // mid-file damage, not a torn append, and must not be silently skipped.
        let jsonl = mutationsJsonlURL(root: root, workspaceId: workspaceId)
        let contents = try String(contentsOf: jsonl, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[0] = "not json"
        try Data(lines.joined(separator: "\n").utf8).write(to: jsonl)

        let reader = FileCheckpointStore(rootDirectory: root)
        do {
            _ = try await reader.listMutationRecords(workspaceId: workspaceId)
            Issue.record("expected mid-file corruption to surface as an error")
        } catch {
            // Expected: only a torn tail without a trailing newline is tolerated.
        }
    }

    @Test
    func `FileCheckpointStore deduplicates snapshot content into blobs`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let store = FileCheckpointStore(rootDirectory: root)
        let workspaceId = UUID()

        func fileEntry(_ path: WorkspacePath, _ text: String) -> Snapshot.Entry {
            .file(Snapshot.File(path: path, data: Data(text.utf8), permissions: POSIXPermissions(0o644)))
        }
        func tree(_ children: [Snapshot.Entry]) -> Snapshot {
            Snapshot(
                rootPath: .root,
                entry: .directory(
                    Snapshot.Directory(path: .root, permissions: .defaultDirectory, children: children)
                )
            )
        }

        let first = tree([fileEntry("/a.txt", "alpha"), fileEntry("/b.txt", "beta")])
        let second = tree([fileEntry("/a.txt", "alpha"), fileEntry("/b.txt", "changed")])
        try await store.saveSnapshot(first, workspaceId: workspaceId)
        try await store.saveSnapshot(second, workspaceId: workspaceId)

        // "alpha" is shared between the snapshots and stored once: three blobs, not four.
        let blobsDirectory = root
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: blobsDirectory.path)
        #expect(blobs.count == 3)

        // The manifest carries hashes, not base64-inflated contents.
        let manifestURL = root
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("\(first.id.uuidString).json", isDirectory: false)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        #expect(!manifestText.contains(Data("alpha".utf8).base64EncodedString()))
        #expect(manifestText.contains("\"version\""))
        #expect(manifestText.contains(SHA256.hexDigest(of: Data("alpha".utf8))))

        // Loading reconstructs full snapshots, including contents and permissions.
        #expect(try await store.loadSnapshot(id: first.id, workspaceId: workspaceId) == first)
        #expect(try await store.loadSnapshot(id: second.id, workspaceId: workspaceId) == second)

        // A fresh store instance reads the same artifacts.
        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.loadSnapshot(id: second.id, workspaceId: workspaceId) == second)
    }

    @Test
    func `FileCheckpointStore loads legacy inline snapshots`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let workspaceId = UUID()
        let snapshot = Snapshot(
            rootPath: .root,
            entry: .directory(
                Snapshot.Directory(
                    path: .root,
                    permissions: .defaultDirectory,
                    children: [
                        .file(Snapshot.File(path: "/x.txt", data: Data("legacy".utf8), permissions: POSIXPermissions(0o600))),
                    ]
                )
            )
        )

        // Write the legacy format (full snapshot with inline contents) directly.
        let snapshotsDirectory = root
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(
            to: snapshotsDirectory.appendingPathComponent("\(snapshot.id.uuidString).json", isDirectory: false)
        )

        let store = FileCheckpointStore(rootDirectory: root)
        #expect(try await store.loadSnapshot(id: snapshot.id, workspaceId: workspaceId) == snapshot)
    }

    @Test
    func `pruneMutationRecords bounds the log and keeps the newest record`() async throws {
        let root = try makeTempDirectory()
        defer { removeTempDirectory(root) }

        let store = FileCheckpointStore(rootDirectory: root)
        let workspaceId = UUID()
        for index in 0..<5 {
            try await store.appendMutation(
                MutationRecord(
                    sequence: 0,
                    workspaceId: workspaceId,
                    kind: .writeFile,
                    touchedPaths: [WorkspacePath(normalizing: "/file-\(index).txt")],
                    fileChanges: []
                )
            )
        }

        try await store.pruneMutationRecords(workspaceId: workspaceId, throughSequence: 3)
        #expect(try await store.listMutationRecords(workspaceId: workspaceId).map(\.sequence) == [4, 5])

        // Pruning everything still retains the newest record so sequences stay monotonic.
        try await store.pruneMutationRecords(workspaceId: workspaceId, throughSequence: 100)
        #expect(try await store.listMutationRecords(workspaceId: workspaceId).map(\.sequence) == [5])

        let appended = try await store.appendMutation(
            MutationRecord(
                sequence: 0,
                workspaceId: workspaceId,
                kind: .writeFile,
                touchedPaths: ["/next.txt"],
                fileChanges: []
            )
        )
        #expect(appended.sequence == 6)
    }

    private func mutationsJsonlURL(root: URL, workspaceId: UUID) -> URL {
        root
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent("mutations.jsonl", isDirectory: false)
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
