import Foundation
import Testing
@testable import Workspace

@Suite("Checkpoint tree format")
struct CheckpointFormatTests {
    @Test func `one changed leaf writes only its ancestor trees and reopens correctly`() async throws {
        let root = try TestSupport.temporaryDirectory("TreeReuse")
        let files = try TestSupport.temporaryDirectory("TreeReuseFiles")
        defer { TestSupport.remove(root); TestSupport.remove(files) }
        let fs = try LocalFileSystem(root: files)
        for directory in 0..<12 {
            let path = WorkspacePath(normalizing: "/dir\(directory)/deep/leaf")
            try await fs.createDirectory(path: path.parent, recursive: true)
            try await fs.writeFile(path: path, data: Data("old \(directory)\n".utf8), append: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: files.appendingPathComponent(String(path.string.dropFirst())).path)
        }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        let first = try await store.captureRevision(from: fs, draft: draft(id))
        let trees = root.appendingPathComponent(id.uuidString).appendingPathComponent("trees")
        let original = try artifacts(trees)
        try await fs.writeFile(path: "/dir0/deep/leaf", data: Data("new\n".utf8), append: false)
        let second = try await store.captureRevision(from: fs, draft: draft(id, parent: first.id))
        let updated = try artifacts(trees)
        #expect(updated.count - original.count == 3) // root, dir0, deep
        for (name, bytes) in original { #expect(updated[name] == bytes) }
        #expect(second.summary.touchedPaths == ["/dir0/deep/leaf"])
        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.readSnapshotFile(id: first.snapshotId, workspaceId: id, path: "/dir0/deep/leaf", offset: 0, length: nil) == Data("old 0\n".utf8))
        #expect(try await reader.readSnapshotFile(id: second.snapshotId, workspaceId: id, path: "/dir0/deep/leaf", offset: 0, length: nil) == Data("new\n".utf8))
        let third = try await store.captureRevision(from: fs, draft: draft(id, parent: second.id))
        #expect(third.summary.changedPathCount == 0)
        #expect(try artifacts(trees) == updated)
        // A cold range read must not decode an unrelated subtree. Corruption there
        // is still reported by operations that need the complete snapshot.
        let manifestURL = root.appendingPathComponent(id.uuidString).appendingPathComponent("snapshots/\(third.snapshotId.uuidString).json")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let rootNode = try #require(manifest["root"] as? [String: Any])
        let rootHash = try #require(rootNode["treeHash"] as? String)
        let children = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: trees.appendingPathComponent(rootHash))) as? [[String: Any]])
        let unrelated = try #require(children.first { ($0["name"] as? String) == "dir11" })
        let unrelatedHash = try #require(unrelated["treeHash"] as? String)
        try FileManager.default.removeItem(at: trees.appendingPathComponent(unrelatedHash))
        let cold = FileCheckpointStore(rootDirectory: root)
        #expect(try await cold.resolveSnapshotFile(id: third.snapshotId, workspaceId: id, path: "/dir0/deep/leaf").size == 4)
        #expect(try await cold.readSnapshotFile(id: third.snapshotId, workspaceId: id, path: "/dir0/deep/leaf", offset: 1, length: 2) == Data("ew".utf8))
        let workspace = Workspace(workspaceID: id, fileSystem: fs, persistence: .directory(root))
        #expect(try await workspace.info("/dir0/deep/leaf", at: .checkpoint(third.id)).size == 4)
        #expect(try await workspace.list("/dir0", at: .checkpoint(third.id)).map(\.name) == ["deep"])
        #expect(try await workspace.list(.root, at: .checkpoint(third.id)).count == 12)
        await #expect(throws: WorkspaceError.self) { _ = try await cold.loadSnapshot(id: third.snapshotId, workspaceId: id) }
    }

    @Test func `materialized saves reuse trees without trusting uncaptured timestamps`() async throws {
        let root = try TestSupport.temporaryDirectory("SavedTreeReuse")
        let files = try TestSupport.temporaryDirectory("SavedTreeFiles")
        defer { TestSupport.remove(root); TestSupport.remove(files) }
        let fs = try LocalFileSystem(root: files)
        try await fs.createDirectory(path: "/a/b", recursive: true)
        try await fs.writeFile(path: "/a/b/note", data: Data("old".utf8), append: false)
        let fileURL = files.appendingPathComponent("a/b/note")
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileURL.path)
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        let first = try await store.captureRevision(from: fs, draft: draft(id))
        var materialized = try #require(await store.loadSnapshot(id: first.snapshotId, workspaceId: id))
        materialized.id = UUID()
        let trees = root.appendingPathComponent(id.uuidString).appendingPathComponent("trees")
        let before = try artifacts(trees)
        let saved = try await store.saveRevision(materialized, draft: draft(id, parent: first.id))
        #expect(try artifacts(trees) == before)
        try await fs.writeFile(path: "/a/b/note", data: Data("new".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileURL.path)
        let recaptured = try await store.captureRevision(from: fs, draft: draft(id, parent: saved.id))
        #expect(recaptured.summary.touchedPaths == ["/a/b/note"])
        #expect(try await store.readSnapshotFile(id: recaptured.snapshotId, workspaceId: id, path: "/a/b/note", offset: 0, length: nil) == Data("new".utf8))
    }

    @Test func `pack compaction reclaims dead entries and dry run matches physical usage`() async throws {
        let root = try TestSupport.temporaryDirectory("PackCompaction")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        let first = try await store.saveRevision(snapshot(count: 100), draft: draft(id))
        let otherWriter = FileCheckpointStore(rootDirectory: root)
        _ = try await otherWriter.saveRevision(snapshot(count: 100), draft: draft(id, parent: first.id))
        let kept = snapshot(count: 40, start: 60)
        let second = try await store.saveRevision(kept, draft: draft(id, parent: first.id))
        let workspace = root.appendingPathComponent(id.uuidString)
        let packs = workspace.appendingPathComponent("packs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: packs.path).contains { $0.hasSuffix(".pack") })
        let oldDirectoryDate = try #require(packs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        // An interrupted pack write with no index must also be swept.
        let orphan = packs.appendingPathComponent(".pending-" + UUID().uuidString + ".pack")
        try Data("unpublished".utf8).write(to: orphan)
        let before = try artifacts(packs)
        let dry = try await store.compact(workspaceId: id, retaining: .latest(1, preservingLabeled: false), dryRun: true)
        #expect(try artifacts(packs) == before)
        #expect(dry.report.after.blobCount == 40)
        #expect(dry.report.after.blobBytes == (60..<100).reduce(UInt64(0)) { $0 + UInt64(content($1).count) })
        let applied = try await store.compact(workspaceId: id, retaining: .latest(1, preservingLabeled: false), dryRun: false)
        #expect(applied.report.after == dry.report.after)
        #expect(try await store.storageStatistics(workspaceId: id) == dry.report.after)
        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.loadSnapshot(id: second.snapshotId, workspaceId: id)?.entry == kept.entry)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await reader.compact(workspaceId: id, retaining: .all, dryRun: false).report.reclaimedBytes == 0)
        // This instance cached the old pack catalog before compaction. It must
        // refresh before deduplicating a new root against those hashes.
        try FileManager.default.setAttributes([.modificationDate: oldDirectoryDate], ofItemAtPath: packs.path)
        let appended = try await otherWriter.saveRevision(snapshot(count: 100), draft: draft(id))
        #expect(try await reader.loadSnapshot(id: appended.snapshotId, workspaceId: id)?.entry == snapshot(count: 100).entry)
    }

    @Test func `compaction resumes after only some roots moved to replacement packs`() async throws {
        let root = try TestSupport.temporaryDirectory("InterruptedRepack")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        let first = try await store.saveRevision(snapshot(count: 100), draft: draft(id))
        let second = try await store.saveRevision(snapshot(count: 100), draft: draft(id, parent: first.id))
        let directory = root.appendingPathComponent(id.uuidString)
        let packs = directory.appendingPathComponent("packs")
        let oldPack = try #require(FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil).first { $0.pathExtension == "pack" })
        let newID = UUID().uuidString
        try FileManager.default.copyItem(at: oldPack, to: packs.appendingPathComponent(newID + ".pack"))
        let unindexed = try FileHandle(forWritingTo: packs.appendingPathComponent(newID + ".pack"))
        try unindexed.seekToEnd()
        try unindexed.write(contentsOf: Data("unindexed tail".utf8))
        try unindexed.close()
        // Model the durable state after repacking and updating just one snapshot root.
        let oldID = oldPack.deletingPathExtension().lastPathComponent
        let oldIndex = try String(contentsOf: packs.appendingPathComponent(oldID + ".json"), encoding: .utf8)
        try Data(oldIndex.replacingOccurrences(of: oldID, with: newID).utf8).write(to: packs.appendingPathComponent(newID + ".json"))
        let manifestURL = directory.appendingPathComponent("snapshots/\(second.snapshotId.uuidString).json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var node = try #require(manifest["root"] as? [String: Any])
        let treeID = try #require(node["treeHash"] as? String)
        let oldTree = try String(contentsOf: directory.appendingPathComponent("trees/" + treeID), encoding: .utf8)
        let newTree = Data(oldTree.replacingOccurrences(of: oldID, with: newID).utf8)
        let newTreeID = SHA256.hexDigest(of: newTree)
        try newTree.write(to: directory.appendingPathComponent("trees/" + newTreeID))
        node["treeHash"] = newTreeID
        manifest["root"] = node
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let reopened = FileCheckpointStore(rootDirectory: root)
        let dry = try await reopened.compact(workspaceId: id, retaining: .all, dryRun: true)
        let result = try await reopened.compact(workspaceId: id, retaining: .all, dryRun: false)
        #expect(result.report.after == dry.report.after)
        #expect(try await reopened.storageStatistics(workspaceId: id) == dry.report.after)
        #expect(result.report.after.blobCount == 100)
        for checkpoint in [first, second] {
            #expect(try await reopened.loadSnapshot(id: checkpoint.snapshotId, workspaceId: id)?.entry == snapshot(count: 100).entry)
        }
    }

    @Test(arguments: [false, true])
    func `interrupted capture never publishes incomplete blobs or trees`(failPublication: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("InterruptedPack")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let base = InMemoryFileSystem()
        for i in 0..<100 {
            try await base.writeFile(path: path(i), data: content(i), append: false)
        }
        let fs = HookableFileSystem(base: base)
        let store = FileCheckpointStore(rootDirectory: root)
        try await store.prepare(workspaceId: id)
        let snapshots = root.appendingPathComponent(id.uuidString).appendingPathComponent("snapshots")
        await Self.arm(fs, reads: 80) {
            if failPublication {
                // Fail the final root-manifest write, after blobs/trees were staged.
                try FileManager.default.removeItem(at: snapshots)
                try Data("blocked".utf8).write(to: snapshots)
            } else { throw TestFileSystemError.injected }
        }
        await #expect(throws: (any Error).self) { _ = try await store.captureRevision(from: fs, draft: draft(id)) }
        if failPublication {
            try FileManager.default.removeItem(at: snapshots)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        }
        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.listCheckpoints(workspaceId: id).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
        let swept = try await reader.compact(workspaceId: id, retaining: .all, dryRun: false)
        #expect(swept.report.after == .empty)
        #expect(try await reader.storageStatistics(workspaceId: id) == .empty)
        let recovered = try await reader.captureRevision(from: base, draft: draft(id))
        #expect(try await reader.loadSnapshot(id: recovered.snapshotId, workspaceId: id)?.entry == snapshot(count: 100).entry)
    }

    @Test func `name trees deduplicate relocated subtrees and reject invalid entries`() async throws {
        let root = try TestSupport.temporaryDirectory("RelativeTrees")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root, cacheByteLimit: 4096)
        let absent = UUID()
        do {
            _ = try await store.resolveSnapshotFile(id: absent, workspaceId: id, path: "/missing")
            Issue.record("missing workspace unexpectedly resolved a file")
        } catch {
            if case let WorkspaceError.revisionDataNotFound(actual) = error {
                #expect(actual == absent)
            } else { Issue.record("unexpected missing-workspace error: \(error)") }
        }

        func tree(_ name: String) -> Snapshot {
            let parent = WorkspacePath.root.appending(name)
            return Snapshot(rootPath: .root, entry: .directory(.init(path: .root, permissions: .defaultDirectory, children: [
                .directory(.init(path: parent, permissions: .defaultDirectory, children: [
                    .directory(.init(path: parent.appending("deep"), permissions: .defaultDirectory, children: [
                        .file(.init(path: parent.appending("deep/file"), data: Data("same".utf8), permissions: .defaultFile))
                    ]))
                ]))
            ])))
        }
        let first = try await store.saveRevision(tree("before"), draft: draft(id))
        let directory = root.appendingPathComponent(id.uuidString)
        let trees = directory.appendingPathComponent("trees")
        let original = try artifacts(trees)
        let second = try await store.saveRevision(tree("after"), draft: draft(id, parent: first.id))
        #expect(try artifacts(trees).count == original.count + 1) // only root changes on rename
        for (checkpoint, name) in [(first, "before"), (second, "after")] {
            let path = WorkspacePath(normalizing: "/\(name)/deep/file")
            #expect(try await store.readSnapshotFile(id: checkpoint.snapshotId, workspaceId: id, path: path, offset: 0, length: nil) == Data("same".utf8))
        }
        // Each object has a valid hash but an invalid name or child kind.
        let manifestURL = directory.appendingPathComponent("snapshots/\(second.snapshotId).json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var node = try #require(manifest["root"] as? [String: Any])
        let invalidEntries = ["", ".", "..", "a/b", "a/\u{301}b", "a\0b"].map { ($0, "directory") }
            + [("absent", "missing")]
        for (name, kind) in invalidEntries {
            let bytes = try JSONSerialization.data(withJSONObject: [[
                "name": name, "kind": kind, "permissions": ["rawValue": 493]
            ]])
            let hash = SHA256.hexDigest(of: bytes)
            try bytes.write(to: trees.appendingPathComponent(hash))
            node["treeHash"] = hash
            manifest["root"] = node
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            await #expect(throws: WorkspaceError.self) {
                _ = try await store.snapshotEntry(id: second.snapshotId, workspaceId: id, path: .root, includeChildren: true)
            }
        }
    }

    @Test func `LRU refreshes hits and enforces decoded byte budget`() {
        var cache = CostLRU<String, Int>(limit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 4)
        #expect(cache.value(for: "a") == 1)
        cache.insert(3, for: "c", cost: 4)
        #expect(cache.value(for: "b") == nil) // hit promoted a over b
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.cost == 8)
        cache.insert(4, for: "a", cost: 7)
        #expect(cache.value(for: "c") == nil)
        #expect(cache.cost == 7)
        cache.insert(5, for: "large", cost: 11)
        #expect(cache.value(for: "large") == nil)
        #expect(cache.value(for: "a") == 4)
        cache.removeAll()
        #expect(cache.cost == 0 && cache.count == 0)
    }

    @Test func `capture cache inserts retain resident trees across an oversized scan`() {
        var cache = CostLRU<Int, Int>(limit: 8)
        for key in 0..<7 { cache.insert(key, for: key, cost: 1) }
        for key in 7..<100 {
            cache.insert(key, for: key, cost: 1, evicting: .mostRecent)
            #expect(cache.cost <= 8)
        }
        for key in 0..<7 { #expect(cache.value(for: key) == key) }
        #expect(cache.value(for: 99) == 99)
        #expect(cache.count == 8 && cache.cost == 8)
    }

    @Test func `durable orphan root is swept after metadata publication fails`() async throws {
        let root = try TestSupport.temporaryDirectory("OrphanRoot")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/note", data: Data("complete".utf8), append: false)
        let fs = HookableFileSystem(base: base)
        let store = FileCheckpointStore(rootDirectory: root)
        try await store.prepare(workspaceId: id)
        let directory = root.appendingPathComponent(id.uuidString)
        let checkpoints = directory.appendingPathComponent("checkpoints")
        await fs.onRead { _ in
            try FileManager.default.removeItem(at: checkpoints)
            try Data("blocked".utf8).write(to: checkpoints)
        }
        await #expect(throws: (any Error).self) { _ = try await store.captureRevision(from: fs, draft: draft(id)) }
        #expect(try artifacts(directory.appendingPathComponent("snapshots")).count == 1)
        try FileManager.default.removeItem(at: checkpoints)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        #expect(try await store.listCheckpoints(workspaceId: id).isEmpty)
        let dry = try await store.compact(workspaceId: id, retaining: .all, dryRun: true)
        #expect(dry.report.before.snapshotCount == 1)
        let swept = try await store.compact(workspaceId: id, retaining: .all, dryRun: false)
        #expect(swept.report.after == .empty)
        #expect(try artifacts(directory.appendingPathComponent("snapshots")).isEmpty)
    }

    @Test func `failed capture after pack rollover sweeps indexed and unindexed packs`() async throws {
        let root = try TestSupport.temporaryDirectory("RolloverFailure")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let base = InMemoryFileSystem()
        for i in 0..<55 {
            try await base.writeFile(path: path(i), data: Data(repeating: UInt8(i), count: 1024 * 1024), append: false)
        }
        let fs = HookableFileSystem(base: base)
        let store = FileCheckpointStore(rootDirectory: root, cacheByteLimit: 8192)
        await Self.arm(fs, reads: 53) { throw TestFileSystemError.injected }
        await #expect(throws: (any Error).self) { _ = try await store.captureRevision(from: fs, draft: draft(id)) }
        let packs = root.appendingPathComponent(id.uuidString).appendingPathComponent("packs")
        let staged = try artifacts(packs)
        #expect(staged.keys.contains { $0.hasSuffix(".json") })
        #expect(staged.keys.contains { $0.hasSuffix(".pack") && staged[String($0.dropLast(5)) + ".json"] == nil })
        try Data("pending".utf8).write(to: packs.appendingPathComponent(".pending-abandoned.pack"))
        let dry = try await store.compact(workspaceId: id, retaining: .all, dryRun: true)
        let swept = try await store.compact(workspaceId: id, retaining: .all, dryRun: false)
        #expect(swept.report.after == dry.report.after)
        #expect(swept.report.after == .empty)
        #expect(try artifacts(packs).isEmpty)
        // Reuse the same writer/catalog after sweeping; no hash may resolve to a deleted pack.
        let recovered = try await store.captureRevision(from: base, draft: draft(id))
        let reopened = FileCheckpointStore(rootDirectory: root)
        for i in 0..<55 {
            #expect(try await reopened.readSnapshotFile(id: recovered.snapshotId, workspaceId: id, path: path(i), offset: 0, length: nil) == Data(repeating: UInt8(i), count: 1024 * 1024))
        }
    }

    @Test(arguments: [0, 1, 3])
    func `compaction resumes after generation advance and partial object deletion`(successfulDeletes: Int) async throws {
        let root = try TestSupport.temporaryDirectory("DeletionFailure")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = FileCheckpointStore(rootDirectory: root)
        let first = try await writer.saveRevision(snapshot(count: 100), draft: draft(id))
        let kept = snapshot(count: 10, start: 40)
        let last = try await writer.saveRevision(kept, draft: draft(id, parent: first.id))
        let directory = root.appendingPathComponent(id.uuidString)
        let token = directory.appendingPathComponent("packs.generation")
        let generation = try Data(contentsOf: token)
        let manager = DeletionFailureManager(successfulDeletes: successfulDeletes)
        let failing = FileCheckpointStore(rootDirectory: root, fileManager: manager)
        await #expect(throws: TestFileSystemError.self) {
            _ = try await failing.compact(workspaceId: id, retaining: .latest(1, preservingLabeled: false), dryRun: false)
        }
        #expect(try Data(contentsOf: token) != generation)
        let reader = FileCheckpointStore(rootDirectory: root)
        #expect(try await reader.loadSnapshot(id: last.snapshotId, workspaceId: id)?.entry == kept.entry)
        let dry = try await reader.compact(workspaceId: id, retaining: .all, dryRun: true)
        let result = try await reader.compact(workspaceId: id, retaining: .all, dryRun: false)
        #expect(result.report.after == dry.report.after)
        #expect(try await reader.storageStatistics(workspaceId: id) == result.report.after)
        let recovered = try await writer.saveRevision(snapshot(count: 100), draft: draft(id, parent: last.id))
        #expect(try await reader.loadSnapshot(id: recovered.snapshotId, workspaceId: id)?.entry == snapshot(count: 100).entry)
    }

    private final class DeletionFailureManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(successfulDeletes: Int) { remaining = successfulDeletes; super.init() }
        override func removeItem(at url: URL) throws {
            let directory = url.deletingLastPathComponent().lastPathComponent
            if directory == "trees" || directory == "packs" {
                try lock.withLock {
                    if remaining == 0 { throw TestFileSystemError.injected }
                    remaining -= 1
                }
            }
            try super.removeItem(at: url)
        }
    }

    @Test func `canonically equivalent sibling names remain distinct across saves and captures`() async throws {
        let root = try TestSupport.temporaryDirectory("ByteNames")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let nfc = WorkspacePath(normalizing: "/caf\u{E9}")
        let nfd = WorkspacePath(normalizing: "/cafe\u{301}")
        func snapshot(_ nfdBytes: Data) -> Snapshot {
            Snapshot(rootPath: .root, entry: .directory(.init(path: .root, permissions: .defaultDirectory, children: [
                .file(.init(path: nfc, data: Data([0, 1]), permissions: .defaultFile)),
                .file(.init(path: nfd, data: nfdBytes, permissions: .defaultFile))
            ])))
        }
        let store = FileCheckpointStore(rootDirectory: root)
        // Independent saved roots exercise persistence without the materialized snapshot
        // diff's String-keyed map, which is fixed by the separate security track.
        let first = try await store.saveRevision(snapshot(Data([0, 2])), draft: draft(id))
        let second = try await store.saveRevision(snapshot(Data([0, 2])), draft: draft(id))
        let trees = root.appendingPathComponent(id.uuidString).appendingPathComponent("trees")
        let original = try artifacts(trees)
        let unchanged = try await store.captureRevision(
            from: ByteNameFileSystem(snapshot(Data([0, 2]))), draft: draft(id, parent: second.id)
        )
        #expect(unchanged.summary.changedPathCount == 0)
        let afterMetadataCapture = try artifacts(trees)
        let again = try await store.captureRevision(
            from: ByteNameFileSystem(snapshot(Data([0, 2]))), draft: draft(id, parent: unchanged.id)
        )
        #expect(again.summary.changedPathCount == 0)
        #expect(try artifacts(trees) == afterMetadataCapture)
        let changed = try await store.captureRevision(
            from: ByteNameFileSystem(snapshot(Data([0, 3]))), draft: draft(id, parent: again.id)
        )
        #expect(changed.summary.touchedPaths.map { Array($0.string.utf8) } == [Array(nfd.string.utf8)])
        #expect(try artifacts(trees).count == afterMetadataCapture.count + 1)
        #expect(!original.isEmpty)
        // Both hot and cold path lookups must select the byte-exact sibling.
        for reader in [store, FileCheckpointStore(rootDirectory: root)] {
            for checkpoint in [first, second, unchanged, again, changed] {
                #expect(try await reader.readSnapshotFile(id: checkpoint.snapshotId, workspaceId: id, path: nfc, offset: 0, length: nil) == Data([0, 1]))
                let expected = checkpoint.id == changed.id ? Data([0, 3]) : Data([0, 2])
                #expect(try await reader.readSnapshotFile(id: checkpoint.snapshotId, workspaceId: id, path: nfd, offset: 0, length: nil) == expected)
            }
        }
    }

    @Test func `parented saves preserve byte-only symlink target changes`() async throws {
        let root = try TestSupport.temporaryDirectory("ByteSymlinkTargets")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        func snapshot(_ target: String) -> Snapshot {
            Snapshot(rootPath: .root, entry: .directory(.init(
                path: .root, permissions: .defaultDirectory, children: [
                    .symlink(.init(path: "/alias", target: target, permissions: POSIXPermissions(0o777)))
                ]
            )))
        }
        let before = try await store.saveRevision(snapshot("/caf\u{e9}"), draft: draft(id))
        let after = try await store.saveRevision(snapshot("/cafe\u{301}"), draft: draft(id, parent: before.id))
        #expect(after.summary.touchedPaths == ["/alias"])
        for reader in [store, FileCheckpointStore(rootDirectory: root)] {
            let saved = try #require(await reader.loadSnapshot(id: after.snapshotId, workspaceId: id))
            #expect(saved.entry == snapshot("/cafe\u{301}").entry)
        }
    }

    /// Deliberately bypasses host filesystem normalization and WorkspacePath's
    /// pre-security-patch Hashable conformance. Directory order is NFC then NFD.
    private final class ByteNameFileSystem: FileSystem, Sendable {
        let files: [Snapshot.File]
        init(_ snapshot: Snapshot) {
            guard case let .directory(directory) = snapshot.entry else { preconditionFailure() }
            files = directory.children.compactMap { if case let .file(file) = $0 { file } else { nil } }
        }
        private func file(_ path: WorkspacePath) throws -> Snapshot.File {
            guard let file = files.first(where: { $0.path.string.utf8.elementsEqual(path.string.utf8) }) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            return file
        }
        func stat(path: WorkspacePath) async throws -> FileInfo {
            if path.isRoot { return FileInfo(path: path, kind: .directory, size: 0, permissions: .defaultDirectory, modificationDate: nil) }
            let value = try file(path)
            return FileInfo(path: path, kind: .file, size: UInt64(value.data.count), permissions: value.permissions, modificationDate: nil)
        }
        func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
            guard path.isRoot else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
            return files.map { DirectoryEntry(name: $0.path.name, info: FileInfo(path: $0.path, kind: .file, size: UInt64($0.data.count), permissions: $0.permissions, modificationDate: nil)) }
        }
        func readFile(path: WorkspacePath) async throws -> Data { try file(path).data }
        func exists(path: WorkspacePath) async -> Bool { path.isRoot || (try? file(path)) != nil }
        func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { throw WorkspaceError.unsupported("test filesystem glob") }
        func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { throw WorkspaceError.readOnly }
        func createDirectory(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
        func remove(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
        func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { throw WorkspaceError.readOnly }
        func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    }

    private static func arm(_ fs: HookableFileSystem, reads: Int, action: @escaping @Sendable () throws -> Void) async {
        await fs.onRead { _ in
            if reads == 1 { try action() }
            else { await arm(fs, reads: reads - 1, action: action) }
        }
    }

    private func artifacts(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    private func content(_ i: Int) -> Data {
        // Exercise direct large-blob writes as well as buffered tiny records.
        if i == 99 { return Data(repeating: 0, count: 1024 * 1024 + 17) }
        return Data(String(format: "content-%03d\n", i).utf8)
    }
    private func path(_ i: Int) -> WorkspacePath { WorkspacePath(normalizing: String(format: "/file%03d", i)) }
    private func snapshot(count: Int, start: Int = 0) -> Snapshot {
        Snapshot(rootPath: .root, entry: .directory(.init(path: .root, permissions: .defaultDirectory,
            children: (start..<(start + count)).map { .file(.init(path: path($0), data: content($0), permissions: .defaultFile)) })))
    }
    private func draft(_ id: UUID, parent: UUID? = nil) -> CheckpointDraft {
        CheckpointDraft(workspaceID: id, label: nil, preferredParentID: parent, origin: .manual)
    }

}
