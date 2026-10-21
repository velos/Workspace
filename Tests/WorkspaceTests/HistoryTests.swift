import Foundation
import Testing
@testable import Workspace

@Suite("Mutation history")
struct HistoryTests {
    @Test
    func `cursor pages seek with logarithmic probes and decode only the page`() async throws {
        let root = try TestSupport.temporaryDirectory("HistorySeek")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        for index in 1...1000 {
            try await store.appendMutation(Mutation(sequence: 0, workspaceID: id, operation: .edit,
                changes: .init(changes: [.init(path: WorkspacePath(normalizing: "/file-\(index)"), kind: .file, effect: .created)])))
        }
        let counts = HistoryDecodeCounts()
        await store.setIOHook { counts.record($0) }
        for (query, expected) in [
            (MutationQuery.after(990, limit: 5), Array(991...995)),
            (.before(11, limit: 5), Array((6...10).reversed())),
            (.before(996, limit: 5), Array((991...995).reversed()))
        ] {
            counts.reset()
            let page = try await store.listMutations(workspaceId: id, query: query)
            #expect(page.records.map(\.sequence) == expected)
            #expect(counts.full == 5)
            #expect(counts.probes <= 24)
        }
    }

    @Test(arguments: [false, true])
    func `compaction uses the smallest retained cursor even when creation order disagrees`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryCursorOrder")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store: any CheckpointStore = diskBacked ? FileCheckpointStore(rootDirectory: root) : InMemoryCheckpointStore()
        for _ in 1...3 {
            try await store.appendMutation(Mutation(sequence: 0, workspaceID: id, operation: .edit, changes: .init(changes: [])))
        }
        let files = InMemoryFileSystem()
        let firstSnapshot = try await Snapshot.capture(from: files)
        let secondSnapshot = try await Snapshot.capture(from: files)
        let draft = CheckpointDraft(workspaceID: id, preferredParentID: nil, origin: .manual)
        if let memory = store as? InMemoryCheckpointStore {
            _ = try await memory.persistRevision(firstSnapshot, draft: draft, mutationCursor: 3)
            _ = try await memory.persistRevision(secondSnapshot, draft: draft, mutationCursor: 1)
        } else {
            _ = try await store.saveRevision(firstSnapshot, draft: draft)
            var second = try await store.saveRevision(secondSnapshot, draft: draft)
            second.mutationCursor = 1
            let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("checkpoints").appendingPathComponent(second.id.uuidString + ".json")
            try JSONEncoder().encode(second).write(to: url)
        }
        let retained = try await store.listCheckpoints(workspaceId: id)
        #expect(retained.map(\.mutationCursor) == [3, 1])
        for dryRun in [true, false] {
            let result = try await store.compact(workspaceId: id, retaining: .all, dryRun: dryRun)
            #expect(result.report.removedMutationCount == 1)
            #expect(try await store.listMutations(workspaceId: id).map(\.sequence) == (dryRun ? [1, 2, 3] : [2, 3]))
        }
    }

    @Test(arguments: [false, true])
    func `corrupt middle history prevents compaction from deleting any data`(withCheckpoints: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryPreflight")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: .directory(root))
        for index in 1...3 {
            try await workspace.writeText("/a", "version \(index)")
            if withCheckpoints { _ = try await workspace.createCheckpoint() }
        }
        let directory = root.appendingPathComponent(workspace.workspaceID.uuidString)
        let log = directory.appendingPathComponent("mutations.jsonl")
        var lines = try Data(contentsOf: log).split(separator: 0x0A).map { Data($0) }
        lines[1] = Data("corrupt middle record".utf8)
        var damaged = Data()
        for line in lines { damaged.append(line); damaged.append(0x0A) }
        try damaged.write(to: log)
        func contents() throws -> [String: Data] {
            let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
            var result: [String: Data] = [:]
            for case let url as URL in enumerator {
                if url.pathExtension != "lock",
                   try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[url.path] = try Data(contentsOf: url)
                }
            }
            return result
        }
        let before = try contents()
        await #expect(throws: DecodingError.self) {
            _ = try await workspace.compact(retaining: .latest(1, preservingLabeled: false))
        }
        #expect(try contents() == before)
    }

    @Test(arguments: [false, true])
    func `compaction prunes through the oldest retained cursor and reports exact bytes`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryCompaction")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: diskBacked ? .directory(root) : .memory)
        try await writer.writeText("/a", "one")
        let first = try await writer.createCheckpoint()
        try await writer.writeText("/a", "two")
        _ = try await writer.createCheckpoint()
        try await writer.writeText("/a", "three")
        _ = try await writer.createCheckpoint()
        try await writer.writeText("/a", "uncheckpointed")
        let history = try await writer.history()
        let reader = diskBacked ? Workspace(workspaceID: id, persistence: .directory(root)) : writer
        #expect(try await reader.history().map(\.sequence) == [1, 2, 3, 4])
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let original = diskBacked ? try Data(contentsOf: log) : Data()
        let preview = try await writer.compact(retaining: .latest(2, preservingLabeled: false), dryRun: true)
        #expect(preview.removedMutationCount == 2)
        #expect(preview.removedMutationBytes > 0)
        #expect(try await writer.history() == history)
        if diskBacked {
            #expect(try Data(contentsOf: log) == original)
            let removedBytes = original.split(separator: 0x0A).prefix(2).reduce(0) { $0 + $1.count + 1 }
            #expect(preview.removedMutationBytes == UInt64(removedBytes))
        }
        let applied = try await writer.compact(retaining: .latest(2, preservingLabeled: false))
        #expect(applied.removedMutationCount == preview.removedMutationCount)
        #expect(applied.removedMutationBytes == preview.removedMutationBytes)
        #expect(applied.removedCheckpointIDs == [first.id])
        #expect(try await reader.history().map(\.sequence) == [3, 4])
        #expect(try await reader.history(after: 0, limit: 9).map(\.sequence) == [3, 4])
        #expect(try await reader.history(before: nil, limit: 9).map(\.sequence) == [4, 3])
        #expect(try await reader.history(before: 3, limit: 9).isEmpty)
        if diskBacked { #expect(try Data(contentsOf: log).count == original.count - Int(applied.removedMutationBytes)) }

        // Pruning all records must invalidate a populated cache and preserve the high-water mark.
        _ = try await writer.createCheckpoint()
        _ = try await writer.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(try await reader.history().isEmpty)
        let reopened = diskBacked ? Workspace(workspaceID: id, persistence: .directory(root)) : writer
        try await reopened.writeText("/b", "next")
        #expect(try await reader.history().map(\.sequence) == [5])
    }

    @Test(arguments: [false, true])
    func `compaction with no checkpoints keeps history and all retention uses its oldest checkpoint`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryWithoutCheckpoints")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskBacked ? .directory(root) : .memory)
        try await workspace.writeText("/a", "one")
        for dryRun in [true, false] {
            let report = try await workspace.compact(retaining: .all, dryRun: dryRun)
            #expect(report.removedMutationCount == 0)
            #expect(report.removedMutationBytes == 0)
            #expect(try await workspace.history().map(\.sequence) == [1])
        }
        _ = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "two")
        _ = try await workspace.createCheckpoint()
        let report = try await workspace.compact(retaining: .all)
        #expect(report.removedCheckpointCount == 0)
        #expect(report.removedMutationCount == 1)
        #expect(try await workspace.history().map(\.sequence) == [2])
    }

    @Test(arguments: ["torn tail", "missing newline", "blank lines"])
    func `dry run history bytes match the actual rewrite without repairing the source`(tail: String) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryRewriteBytes")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: .directory(root))
        try await workspace.writeText("/a", "checkpointed")
        _ = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "checkpointed again")
        _ = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "kept")
        let directory = root.appendingPathComponent(workspace.workspaceID.uuidString)
        let log = directory.appendingPathComponent("mutations.jsonl")
        let sidecar = directory.appendingPathComponent("mutations.sequence.json")
        var bytes = try Data(contentsOf: log)
        switch tail {
        case "torn tail": bytes.append(Data([0x7B, 0x22, 0xE2, 0x82]))
        case "missing newline": bytes.removeLast()
        default:
            let lines = bytes.split(separator: 0x0A)
            bytes = Data([0x0A, 0x0A])
            for line in lines { bytes.append(line); bytes.append(contentsOf: [0x0A, 0x0A]) }
        }
        try bytes.write(to: log)
        let originalState = try Data(contentsOf: sidecar)
        for cursor in [0, 1, 2, 3, 4] {
            for limit in [1, 2, 10] {
                #expect(try await workspace.history(after: cursor, limit: limit).map(\.sequence) == Array([1, 2, 3].filter { $0 > cursor }.prefix(limit)))
                #expect(try await workspace.history(before: cursor, limit: limit).map(\.sequence) == Array([3, 2, 1].filter { $0 < cursor }.prefix(limit)))
            }
        }
        #expect(try await workspace.history(before: nil, limit: 10).map(\.sequence) == [3, 2, 1])
        let projected = try await workspace.compact(retaining: .latest(1, preservingLabeled: false), dryRun: true)
        #expect(projected.removedMutationCount == 2)
        #expect(try Data(contentsOf: log) == bytes)
        #expect(try Data(contentsOf: sidecar) == originalState)
        let applied = try await workspace.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(applied.removedMutationCount == 2)
        #expect(applied.removedMutationBytes == projected.removedMutationBytes)
        #expect(try Data(contentsOf: log).count == bytes.count - Int(applied.removedMutationBytes))
        #expect(try await workspace.history().map(\.sequence) == [3])
    }

    @Test(arguments: [false, true])
    func `exclusive pages preserve ordering gaps and boundaries`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryPages")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskBacked ? .directory(root) : .memory)
        #expect(try await workspace.history(after: 0, limit: 2).isEmpty)
        #expect(try await workspace.history(before: nil, limit: 2).isEmpty)
        for index in 1...7 { try await workspace.writeText("/a", "\(index)") }
        try await workspace.store.removeMutation(sequence: 3, workspaceId: workspace.workspaceID)
        try await workspace.store.removeMutation(sequence: 6, workspaceId: workspace.workspaceID)
        let all = try await workspace.history()
        #expect(all.map(\.sequence) == [1, 2, 4, 5, 7])
        for cursor in [Int.min, 0, 1, 2, 3, 5, 7, 8, Int.max] {
            for limit in [0, 1, 2, 20] {
                let ascending = try await workspace.history(after: cursor, limit: limit)
                let descending = try await workspace.history(before: cursor, limit: limit)
                #expect(ascending == Array(all.filter { $0.sequence > cursor }.prefix(max(0, limit))))
                #expect(descending == Array(all.reversed().filter { $0.sequence < cursor }.prefix(max(0, limit))))
            }
        }
        let invalidQueries: [MutationQuery] = [.after(3, limit: -1), .before(3, limit: -1), .before(nil, limit: -1)]
        for query in invalidQueries {
            await #expect {
                switch query {
                case let .after(cursor, limit): _ = try await workspace.history(after: cursor, limit: limit)
                case let .before(cursor, limit): _ = try await workspace.history(before: cursor, limit: limit)
                }
            } throws: { error in
                if case WorkspaceError.unsupported = error { return true }
                return false
            }
        }
        #expect(try await workspace.history(before: nil, limit: 3).map(\.sequence) == [7, 5, 4])
        #expect(try await workspace.history(after: 2, limit: 2).map(\.sequence) == [4, 5])
    }

    @Test
    func `directory pages stop before decoding unrelated log regions even on a cold workspace`() async throws {
        let root = try TestSupport.temporaryDirectory("HistoryStreaming")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        // Large UTF-8 records cross the scanner's chunk boundaries in both directions.
        for index in 1...5 {
            let path = WorkspacePath(normalizing: "/\(index)" + String(repeating: "🎉", count: 20000))
            try await store.appendMutation(Mutation(sequence: 0, workspaceID: id, operation: .edit,
                changes: .init(changes: [.init(path: path, kind: .file, effect: .created)])))
        }
        let workspace = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await workspace.history(after: 2, limit: 1).map(\.sequence) == [3])
        #expect(try await workspace.history(before: 4, limit: 1).map(\.sequence) == [3])
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        var lines = try Data(contentsOf: log).split(separator: 0x0A).map { Data($0) }
        lines[2] = Data("corrupt middle record".utf8)
        var damaged = Data()
        for line in lines { damaged.append(line); damaged.append(0x0A) }
        try damaged.write(to: log)
        #expect(try await workspace.history(after: 0, limit: 2).map(\.sequence) == [1, 2])
        #expect(try await workspace.history(before: nil, limit: 2).map(\.sequence) == [5, 4])
        await #expect(throws: DecodingError.self) { _ = try await workspace.history(after: 0, limit: 3) }
        await #expect(throws: DecodingError.self) { _ = try await workspace.history(before: nil, limit: 3) }
        await #expect(throws: DecodingError.self) { _ = try await workspace.history() }
    }

    @Test
    func `pages agree with full history across concurrent appends pruning and retractions`() async throws {
        let root = try TestSupport.temporaryDirectory("ConcurrentHistoryPages")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        for index in 1...5 { try await writer.writeText("/a", "\(index)") }
        _ = try await writer.createCheckpoint()
        _ = try await reader.history()
        let append = Task {
            for index in 6...30 { try await writer.writeText("/a", "\(index)") }
        }
        // Use a separate store so pruning and retraction can contend with appends.
        let other = FileCheckpointStore(rootDirectory: root)
        async let prune = other.compact(workspaceId: id, retaining: .all, dryRun: false)
        async let retract: Void = other.removeMutation(sequence: 4, workspaceId: id)
        for _ in 0..<20 {
            let forward = try await reader.history(after: 5, limit: 3).map(\.sequence)
            let backward = try await reader.history(before: nil, limit: 3).map(\.sequence)
            #expect(forward == forward.sorted())
            #expect(backward == backward.sorted(by: >))
            #expect(Set(forward).count == forward.count)
            #expect(Set(backward).count == backward.count)
        }
        try await append.value
        _ = try await prune
        try await retract
        var collected: [Mutation] = []
        while true {
            let page = try await reader.history(after: collected.last?.sequence ?? 0, limit: 4)
            if page.isEmpty { break }
            collected += page
        }
        #expect(collected.map(\.sequence) == Array(6...30))
        #expect(try await reader.history() == collected)
        var newest: [Mutation] = []
        while true {
            let page = try await reader.history(before: newest.last?.sequence, limit: 4)
            if page.isEmpty { break }
            newest += page
        }
        #expect(newest == Array(collected.reversed()))
    }

    @Test(arguments: [false, true])
    func `paged history waits for this workspace operation gate`(newestFirst: Bool) async throws {
        let files = HookableFileSystem()
        let workspace = Workspace(fileSystem: files)
        let entered = TestSignal()
        let resume = TestSignal()
        await files.onWrite { _ in await entered.signal(); await resume.wait() }
        let write = Task { try await workspace.writeText("/a", "a") }
        await entered.wait()
        let read = Task {
            if newestFirst { return try await workspace.history(before: nil, limit: 1) }
            return try await workspace.history(after: 0, limit: 1)
        }
        for _ in 0..<100 { await Task.yield() }
        await resume.signal()
        _ = try await write.value
        #expect(try await read.value.map(\.sequence) == [1])
    }
}

private final class HistoryDecodeCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var fullCount = 0
    private var probeCount = 0
    var full: Int { lock.withLock { fullCount } }
    var probes: Int { lock.withLock { probeCount } }
    func reset() { lock.withLock { fullCount = 0; probeCount = 0 } }
    func record(_ event: FileCheckpointStore.IOEvent) {
        lock.withLock {
            if event == .mutationDecoded { fullCount += 1 }
            if event == .sequenceProbed { probeCount += 1 }
        }
    }
}
