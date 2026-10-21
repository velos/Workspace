import Foundation
import Testing
@testable import Workspace

@Suite("History durability")
struct HistoryDurabilityTests {
    @Test(arguments: ["manual", "transaction", "restore", "saved snapshot", "compaction rebase"])
    func `checkpoint publishers sync history before exposing metadata`(publisher: String) async throws {
        let root = try TestSupport.temporaryDirectory("HistorySyncOrdering")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: .directory(root))
        try await workspace.writeText("/a", "one")
        let first = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "two")
        _ = try await workspace.createCheckpoint()
        let backingStore = await workspace.store
        let store = try #require(backingStore as? FileCheckpointStore)
        if publisher == "compaction rebase" {
            // Two sibling survivors both lose their parent, requiring two publications.
            _ = try await store.saveRevision(try await Snapshot.capture(from: workspace.fileSystem),
                draft: .init(workspaceID: workspace.workspaceID, preferredParentID: first.id, origin: .manual))
        }
        let recorder = StoreIORecorder()
        let checkpointDirectory = root.appendingPathComponent(workspace.workspaceID.uuidString).appendingPathComponent("checkpoints")
        let baseline = try FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path).filter { $0.hasSuffix(".json") }.sorted()
        await store.setIOHook { event in
            recorder.record(event)
            if event == .checkpointWillPublish {
                let visible = try FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path).filter { $0.hasSuffix(".json") }.sorted()
                #expect(visible == baseline)
                #expect(recorder.events.first == .mutationLogSynced)
                #expect(recorder.events.dropFirst().allSatisfy { $0 == .checkpointWillPublish })
            }
        }
        // Appends remain outside the sync barrier.
        try await workspace.writeText("/a", "three")
        #expect(recorder.events.isEmpty)
        switch publisher {
        case "manual": _ = try await workspace.createCheckpoint()
        case "transaction":
            let transaction = try await workspace.beginTransaction()
            try await transaction.writeText("/a", "committed")
            _ = try await transaction.commit()
        case "restore": _ = try await workspace.restore(to: first)
        case "saved snapshot":
            _ = try await store.saveRevision(try await Snapshot.capture(from: workspace.fileSystem),
                draft: .init(workspaceID: workspace.workspaceID, preferredParentID: first.id, origin: .manual))
        default: _ = try await workspace.compact(retaining: .latest(2, preservingLabeled: false))
        }
        #expect(recorder.events.prefix(2) == [.mutationLogSynced, .checkpointWillPublish])
        #expect(recorder.events.filter { $0 == .mutationLogSynced }.count == 1)
        #expect(recorder.events.filter { $0 == .checkpointWillPublish }.count == (publisher == "compaction rebase" ? 2 : 1))
        if publisher != "compaction rebase" { #expect(recorder.events.count == 2) }
    }

    @Test(arguments: ["manual", "transaction", "restore"])
    func `a failed history durability barrier prevents publication and compensates mutations`(publisher: String) async throws {
        let root = try TestSupport.temporaryDirectory("HistorySyncFailure")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: .directory(root))
        try await workspace.writeText("/a", "one")
        let first = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "two")
        let before = try await workspace.history()
        let backingStore = await workspace.store
        let store = try #require(backingStore as? FileCheckpointStore)
        let recorder = StoreIORecorder()
        await store.setIOHook { event in
            recorder.record(event)
            if event == .mutationLogSynced { throw TestFileSystemError.injected }
        }
        await #expect(throws: TestFileSystemError.self) {
            switch publisher {
            case "manual": _ = try await workspace.createCheckpoint()
            case "transaction":
                let transaction = try await workspace.beginTransaction()
                try await transaction.writeText("/a", "committed")
                _ = try await transaction.commit()
            default: _ = try await workspace.restore(to: first)
            }
        }
        #expect(recorder.events == [.mutationLogSynced])
        #expect(try await workspace.readText("/a") == "two")
        let reader = Workspace(workspaceID: workspace.workspaceID, persistence: .directory(root))
        #expect(try await reader.checkpoints().map(\.id) == [first.id])
        #expect(try await reader.history() == before)
    }

    @Test
    func `interrupted history replacement preserves the old log and permits retry`() async throws {
        let root = try TestSupport.temporaryDirectory("InterruptedHistoryRewrite")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        try await writer.writeText("/a", "one")
        _ = try await writer.createCheckpoint()
        try await writer.writeText("/a", "two")
        _ = try await writer.createCheckpoint()
        try await writer.writeText("/a", "three")
        let before = try await reader.history()
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let bytes = try Data(contentsOf: log)
        let backingStore = await writer.store
        let store = try #require(backingStore as? FileCheckpointStore)
        // Fail after the replacement is synced and the new epoch is durable, before rename.
        await store.setIOHook { event in
            if event == .mutationRewriteWillReplace { throw TestFileSystemError.injected }
        }
        await #expect(throws: TestFileSystemError.self) {
            _ = try await writer.compact(retaining: .latest(1, preservingLabeled: false))
        }
        #expect(try Data(contentsOf: log) == bytes)
        #expect(try await reader.history() == before)
        #expect(try await reader.history(before: nil, limit: 9) == Array(before.reversed()))
        // A restart ignores an abandoned partially written replacement from a killed process.
        let abandoned = log.deletingLastPathComponent().appendingPathComponent(".pending-interrupted-mutations.jsonl")
        try Data("{partial".utf8).write(to: abandoned)
        let restarted = Workspace(workspaceID: id, persistence: .directory(root))
        let applied = try await restarted.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(applied.removedMutationCount == 2)
        #expect(try await reader.history().map(\.sequence) == [3])
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        try await restarted.writeText("/b", "next")
        #expect(try await reader.history().map(\.sequence) == [3, 4])
    }
}

private final class StoreIORecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FileCheckpointStore.IOEvent] = []
    var events: [FileCheckpointStore.IOEvent] { lock.withLock { recorded } }
    func record(_ event: FileCheckpointStore.IOEvent) {
        guard event != .mutationDecoded, event != .sequenceProbed else { return }
        lock.withLock { recorded.append(event) }
    }
}
