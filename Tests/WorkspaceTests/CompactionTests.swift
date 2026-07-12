import Foundation
import Testing
@testable import Workspace

@Suite("Storage compaction")
struct CompactionTests {
    @Test
    func `dry run projects the same pruning without changing storage`() async throws {
        let root = try TestSupport.temporaryDirectory("CompactionDryRun")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(workspaceID: UUID(), persistence: .directory(root))

        try await workspace.writeText("/note", "one")
        let first = try await workspace.createCheckpoint()
        try await workspace.writeText("/note", "two")
        let second = try await workspace.createCheckpoint()
        try await workspace.writeText("/note", "three")
        let third = try await workspace.createCheckpoint()

        let preview = try await workspace.compact(
            retaining: .latest(1, preservingLabeled: false),
            dryRun: true
        )
        #expect(preview.dryRun)
        #expect(Set(preview.removedCheckpointIDs) == [first.id, second.id])
        #expect(preview.rebasedCheckpointIDs == [third.id])
        #expect(preview.before.checkpointCount == 3)
        #expect(preview.after.checkpointCount == 1)
        #expect(try await workspace.checkpoints().count == 3)
        #expect(try await workspace.storageStatistics() == preview.before)

        let applied = try await workspace.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(!applied.dryRun)
        #expect(applied.after == preview.after)
        #expect(applied.removedCheckpointIDs == preview.removedCheckpointIDs)
        #expect(try await workspace.storageStatistics() == applied.after)
        #expect(try await workspace.checkpoints().map(\.id) == [third.id])
        #expect(try await workspace.checkpoint(id: third.id)?.parentID == nil)
        #expect(try await workspace.history().count == 3)
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.readText("/note", at: .checkpoint(first.id))
        }
    }

    @Test
    func `latest retention preserves labeled and selected checkpoints and rebases lineage`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/note", "one")
        let labeled = try await workspace.createCheckpoint(label: "keep")
        try await workspace.writeText("/note", "two")
        let selected = try await workspace.createCheckpoint()
        let removed = try await workspace.restore(to: labeled)
        try await workspace.writeText("/note", "four")
        let latest = try await workspace.createCheckpoint()

        let report = try await workspace.compact(
            retaining: .latest(1, preservingLabeled: true, preserving: [selected.id])
        )
        #expect(report.removedCheckpointIDs == [removed.id])
        #expect(report.rebasedCheckpointIDs == [latest.id])
        let retained = try await workspace.checkpoints()
        #expect(Set(retained.map(\.id)) == [labeled.id, selected.id, latest.id])
        #expect(retained.first(where: { $0.id == latest.id })?.parentID == selected.id)
    }

    @Test
    func `retained rollback keeps its provenance and recomputes its summary`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/note", "one")
        let source = try await workspace.createCheckpoint()
        try await workspace.writeText("/note", "two")
        let middle = try await workspace.createCheckpoint()
        let rollback = try await workspace.restore(to: source)
        #expect(rollback.summary.changedPathCount == 1)

        let report = try await workspace.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(report.removedCheckpointIDs == [middle.id])
        #expect(report.rebasedCheckpointIDs == [rollback.id])
        let retained = try await workspace.checkpoints()
        #expect(Set(retained.map(\.id)) == [source.id, rollback.id])
        let rebased = try #require(retained.first(where: { $0.id == rollback.id }))
        #expect(rebased.parentID == source.id)
        #expect(rebased.summary.changedPathCount == 0)
    }

    @Test
    func `fork retention deterministically keeps the latest and explicitly selected tips`() async throws {
        let workspaceID = UUID()
        let store = InMemoryCheckpointStore()
        let seed = try await store.saveRevision(
            Self.snapshot(text: "seed"),
            draft: Self.draft(workspaceID: workspaceID, parentID: nil)
        )
        let firstTip = try await store.saveRevision(
            Self.snapshot(text: "first"),
            draft: Self.draft(workspaceID: workspaceID, parentID: seed.id)
        )
        let secondTip = try await store.saveRevision(
            Self.snapshot(text: "second"),
            draft: Self.draft(workspaceID: workspaceID, parentID: seed.id)
        )
        let tips = [firstTip, secondTip].sorted(by: Checkpoint.orderedBefore)
        let selected = try #require(tips.first)
        let latest = try #require(tips.last)

        let result = try await store.compact(
            workspaceId: workspaceID,
            retaining: .latest(1, preservingLabeled: false, preserving: [selected.id]),
            dryRun: false
        )
        #expect(result.report.removedCheckpointIDs == [seed.id])
        #expect(Set(result.report.rebasedCheckpointIDs) == [selected.id, latest.id])
        #expect(Set(result.checkpoints.map(\.id)) == [selected.id, latest.id])
        #expect(result.checkpoints.allSatisfy { $0.parentID == nil })
    }

    @Test
    func `all retention sweeps orphan manifests and blobs`() async throws {
        let root = try TestSupport.temporaryDirectory("CompactionOrphans")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let workspace = Workspace(workspaceID: workspaceID, persistence: .directory(root))
        try await workspace.writeText("/note", "kept")
        _ = try await workspace.createCheckpoint()

        let workspaceRoot = root.appendingPathComponent(workspaceID.uuidString)
        let orphanManifest = workspaceRoot.appendingPathComponent("snapshots")
            .appendingPathComponent("\(UUID().uuidString).json")
        let orphanBlob = workspaceRoot.appendingPathComponent("blobs").appendingPathComponent("orphan")
        try Data("{}".utf8).write(to: orphanManifest)
        try Data("garbage".utf8).write(to: orphanBlob)

        let report = try await workspace.compact(retaining: .all)
        #expect(report.removedCheckpointCount == 0)
        #expect(report.removedSnapshotCount == 1)
        #expect(report.removedBlobCount == 1)
        #expect(report.reclaimedBytes == UInt64(Data("garbage".utf8).count))
        #expect(!FileManager.default.fileExists(atPath: orphanManifest.path))
        #expect(!FileManager.default.fileExists(atPath: orphanBlob.path))
        #expect(try await workspace.readText("/note") == "kept")
    }

    @Test
    func `missing retained content aborts compaction before deletion`() async throws {
        let root = try TestSupport.temporaryDirectory("CompactionCorrupt")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let workspace = Workspace(workspaceID: workspaceID, persistence: .directory(root))
        try await workspace.writeText("/note", "kept")
        _ = try await workspace.createCheckpoint()

        let workspaceRoot = root.appendingPathComponent(workspaceID.uuidString)
        let orphan = workspaceRoot.appendingPathComponent("blobs").appendingPathComponent("orphan")
        try Data("orphan".utf8).write(to: orphan)
        let keptHash = SHA256.hexDigest(of: Data("kept".utf8))
        try FileManager.default.removeItem(
            at: workspaceRoot.appendingPathComponent("blobs").appendingPathComponent(keptHash)
        )

        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.compact(retaining: .all)
        }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(try await workspace.checkpoints().count == 1)
    }

    @Test
    func `checkpoint commits and compaction serialize across store instances`() async throws {
        let root = try TestSupport.temporaryDirectory("CompactionConcurrent")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let first = FileCheckpointStore(rootDirectory: root)
        let second = FileCheckpointStore(rootDirectory: root)
        let compactor = FileCheckpointStore(rootDirectory: root)
        let seedSnapshot = Self.snapshot(text: "seed")
        let seed = try await first.saveRevision(
            seedSnapshot,
            draft: Self.draft(workspaceID: workspaceID, parentID: nil)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                if index.isMultiple(of: 3) {
                    group.addTask {
                        _ = try await compactor.compact(
                            workspaceId: workspaceID,
                            retaining: .latest(1, preservingLabeled: false),
                            dryRun: false
                        )
                    }
                } else {
                    let store = index.isMultiple(of: 2) ? first : second
                    group.addTask {
                        _ = try await store.saveRevision(
                            Self.snapshot(text: "value-\(index)"),
                            draft: Self.draft(workspaceID: workspaceID, parentID: seed.id)
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        _ = try await compactor.compact(workspaceId: workspaceID, retaining: .all, dryRun: false)
        let reader = FileCheckpointStore(rootDirectory: root)
        let checkpoints = try await reader.listCheckpoints(workspaceId: workspaceID)
        let statistics = try await reader.storageStatistics(workspaceId: workspaceID)
        #expect(!checkpoints.isEmpty)
        #expect(statistics.checkpointCount == checkpoints.count)
        #expect(statistics.snapshotCount == checkpoints.count)
        for checkpoint in checkpoints {
            #expect(try await reader.loadSnapshot(id: checkpoint.snapshotId, workspaceId: workspaceID) != nil)
        }
    }

    @Test
    func `workspace instances reconcile checkpoints removed by another instance`() async throws {
        let root = try TestSupport.temporaryDirectory("CompactionReconcile")
        defer { TestSupport.remove(root) }
        let workspaceID = UUID()
        let writer = Workspace(workspaceID: workspaceID, persistence: .directory(root))
        try await writer.writeText("/note", "one")
        _ = try await writer.createCheckpoint()
        try await writer.writeText("/note", "two")
        let latest = try await writer.createCheckpoint()

        let reader = Workspace(workspaceID: workspaceID, persistence: .directory(root))
        #expect(try await reader.checkpoints().count == 2)
        _ = try await writer.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(try await reader.checkpoints().map(\.id) == [latest.id])
    }

    @Test
    func `invalid retention is rejected without creating storage`() async throws {
        let workspace = Workspace()
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.compact(retaining: .latest(0))
        }
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.compact(retaining: .latest(1, preserving: [UUID()]))
        }
        #expect(try await workspace.storageStatistics() == .empty)
    }

    private static func snapshot(text: String) -> Snapshot {
        Snapshot(
            rootPath: .root,
            entry: .directory(
                .init(
                    path: .root,
                    permissions: .defaultDirectory,
                    children: [
                        .file(.init(path: "/note", data: Data(text.utf8), permissions: .defaultFile))
                    ]
                )
            )
        )
    }

    private static func draft(workspaceID: UUID, parentID: UUID?) -> CheckpointDraft {
        CheckpointDraft(
            workspaceID: workspaceID,
            label: nil,
            preferredParentID: parentID,
            origin: .manual,
            mutationCursor: 0
        )
    }
}
