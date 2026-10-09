import Foundation
import Testing
@testable import Workspace

@Suite("Persistence")
struct PersistenceTests {
    @Test
    func `cancellation after the filesystem write still persists its mutation`() async throws {
        let root = try TestSupport.temporaryDirectory("CancelledPersistence")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let files = ReadCountingFileSystem(base: InMemoryFileSystem(), cancelAfterWrite: true)
        let workspace = Workspace(workspaceID: id, fileSystem: files, persistence: .directory(root))
        _ = try await workspace.history()
        let write = Task { try await workspace.writeText("/a", "a") }

        #expect(try await write.value.touchedPaths == ["/a"])
        #expect(try await workspace.readText("/a") == "a")
        let reloaded = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await reloaded.history().map(\.sequence) == [1])
        #expect(try await reloaded.history().flatMap { $0.changes.touchedPaths } == ["/a"])
    }

    @Test
    func `checkpoint cursors exclude mutations appended after capture starts`() async throws {
        await #expect(processExitsWith: .success) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(124) }
            let root = try TestSupport.temporaryDirectory("CaptureCursor")
            defer { TestSupport.remove(root) }
            for persistence in [Workspace.Persistence.memory, .directory(root)] {
                let pause = CaptureReadPause(at: "/z")
                let files = ReadCountingFileSystem(base: InMemoryFileSystem(), capturePause: pause)
                let workspace = Workspace(fileSystem: files, persistence: persistence)
                try await workspace.writeText("/a", "before")
                try await workspace.writeText("/z", "stable")
                await pause.arm()
                let capture = Task { try await workspace.createCheckpoint() }
                await pause.waitUntilPaused()

                // /a has already been captured. Appending now must not extend this cursor.
                try await workspace.store.appendMutation(Mutation(
                    sequence: 0, workspaceID: workspace.workspaceID, operation: .edit,
                    changes: ChangeSet(changes: [.init(path: "/a", kind: .file, effect: .modified)])
                ))
                await pause.resume()
                let checkpoint = try await capture.value
                #expect(checkpoint.mutationCursor == 2)
                #expect(checkpoint.firstMutationSequence == 1)
                #expect(checkpoint.lastMutationSequence == 2)
                #expect(try await workspace.readText("/a", at: .checkpoint(checkpoint.id)) == "before")
                #expect(try await workspace.history().map(\.sequence) == [1, 2, 3])
            }
        }
    }

    @Test
    func `history merges late persistence acknowledgements without duplicates or gaps`() async throws {
        let root = try TestSupport.temporaryDirectory("LateHistoryAcknowledgement")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: .directory(root))
        _ = try await workspace.history()
        var persisted: [Mutation] = []
        for index in 1...3 {
            let path = WorkspacePath(normalizing: "/\(index)")
            try await workspace.fileSystem.writeFile(path: path, data: Data("\(index)".utf8), append: false)
            persisted.append(try await workspace.store.appendMutation(
                Mutation(
                    sequence: 0, workspaceID: workspace.workspaceID, operation: .edit,
                    changes: ChangeSet(changes: [.init(path: path, kind: .file, effect: .created)])
                )
            ))
        }

        // Apply the completion of sequence 3 first, then let history fetch the missing prefix.
        await workspace.cachePersistedMutations([persisted[2]])
        #expect(try await workspace.history().map(\.sequence) == [1, 2, 3])
        // The append continuations resume after the query has already cached their receipts.
        await workspace.cachePersistedMutations(persisted)
        #expect(try await workspace.history().map(\.sequence) == [1, 2, 3])
    }

    @Test(arguments: [false, true])
    func `history refresh advances across a permanent retraction gap`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("HistoryRetractionGap")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskBacked ? .directory(root) : .memory)
        try await workspace.writeText("/a", "a")
        try await workspace.writeText("/b", "b")
        try await workspace.store.removeMutation(sequence: 2, workspaceId: workspace.workspaceID)
        #expect(try await workspace.history().map(\.sequence) == [1])

        // The epoch is already acknowledged. The next incremental read must cross the gap.
        try await workspace.store.appendMutation(Mutation(
            sequence: 0, workspaceID: workspace.workspaceID, operation: .edit,
            changes: ChangeSet(changes: [.init(path: "/c", kind: .file, effect: .created)])
        ))
        #expect(try await workspace.history().map(\.sequence) == [1, 3])
        #expect(await workspace.historyRefreshSequence == 3)
        try await workspace.writeText("/d", "d")
        #expect(await workspace.historyRefreshSequence == 4)
        #expect(try await workspace.history().map(\.sequence) == [1, 3, 4])
    }

    @Test
    func `history invalidates cached records after another instance retracts or prunes`() async throws {
        let root = try TestSupport.temporaryDirectory("HistoryRetractionEpoch")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        for path: WorkspacePath in ["/a", "/b", "/c"] { try await writer.writeText(path, "value") }
        #expect(try await reader.history().map(\.sequence) == [1, 2, 3])
        try await writer.store.removeMutation(sequence: 2, workspaceId: id)
        #expect(try await reader.history().map(\.sequence) == [1, 3])
        try await writer.store.pruneMutations(workspaceId: id, throughSequence: 1)
        #expect(try await reader.history().map(\.sequence) == [3])
        try await writer.store.removeMutation(sequence: 3, workspaceId: id)
        #expect(try await reader.history().isEmpty)
        #expect(await reader.historyRefreshSequence == 0)
        try await writer.writeText("/d", "d")
        #expect(try await reader.history().map(\.sequence) == [4])
        #expect(try await writer.history().map(\.sequence) == [4])
    }

    @Test
    func `directory persistence reloads revisions and new mutation schema`() async throws {
        let root = try TestSupport.temporaryDirectory("Persistence")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let first = Workspace(workspaceID: id, persistence: .directory(root))
        try await first.writeText("/note", "one")
        let checkpoint = try await first.createCheckpoint(label: "saved")

        let second = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await second.checkpoint(id: checkpoint.id) == checkpoint)
        #expect(try await second.readText("/note", at: .checkpoint(checkpoint.id)) == "one")
        #expect(try await second.history().count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).appendingPathComponent("format.json").path))
    }

    @Test
    func `revision diff does not load an unchanged blob`() async throws {
        let root = try TestSupport.temporaryDirectory("LazyDiff")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let workspace = Workspace(workspaceID: id, persistence: .directory(root))
        _ = try await workspace.apply([
            .writeText("/stable", "stable"),
            .writeText("/changed", "before"),
        ])
        let before = try await workspace.createCheckpoint()
        try await workspace.writeText("/changed", "after")
        let after = try await workspace.createCheckpoint()

        let stableHash = SHA256.hexDigest(of: Data("stable".utf8))
        let stableBlob = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("blobs")
            .appendingPathComponent(stableHash)
        try FileManager.default.removeItem(at: stableBlob)

        let diff = try await workspace.diff(from: .checkpoint(before.id), to: .checkpoint(after.id))
        #expect(diff.changes.map(\.path) == ["/changed"])
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.readData(from: "/stable", at: .checkpoint(before.id))
        }
    }

    @Test
    func `directory checkpoints only reread files whose metadata changed`() async throws {
        let filesRoot = try TestSupport.temporaryDirectory("LazyCaptureFiles")
        let historyRoot = try TestSupport.temporaryDirectory("LazyCaptureHistory")
        defer {
            TestSupport.remove(filesRoot)
            TestSupport.remove(historyRoot)
        }
        let local = try LocalFileSystem(root: filesRoot)
        let files = ReadCountingFileSystem(base: local)
        let workspace = Workspace(fileSystem: files, persistence: .directory(historyRoot))

        try await workspace.writeText("/note", "first")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10)],
            ofItemAtPath: filesRoot.appendingPathComponent("note").path
        )
        await files.resetReadCount()
        _ = try await workspace.createCheckpoint()
        #expect(await files.readCount == 1)

        _ = try await workspace.createCheckpoint()
        #expect(await files.readCount == 1)

        try await workspace.writeText("/note", "second")
        await files.resetReadCount()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: filesRoot.appendingPathComponent("note").path
        )
        let changed = try await workspace.createCheckpoint()
        #expect(await files.readCount == 1)
        #expect(try await workspace.readText("/note", at: .checkpoint(changed.id)) == "second")
    }

    @Test(arguments: [Data("{\"sequence\":".utf8), Data([0x7B, 0x22, 0xE2, 0x82])])
    func `torn final JSONL record is ignored and repaired by the next append`(tail: Data) async throws {
        let root = try TestSupport.temporaryDirectory("TornLog")
        defer { TestSupport.remove(root) }
        let id = UUID()
        var workspace = Workspace(workspaceID: id, persistence: .directory(root))
        try await workspace.writeText("/a", "a")
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()

        workspace = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await workspace.history().count == 1)
        try await workspace.writeText("/b", "b")
        #expect(try await workspace.history().map(\.sequence) == [1, 2])
    }

    @Test
    func `concurrent checkpoint forks retain both tips and select a deterministic parent`() async throws {
        let root = try TestSupport.temporaryDirectory("Forks")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let a = Workspace(workspaceID: id, persistence: .directory(root))
        let b = Workspace(workspaceID: id, persistence: .directory(root))
        async let first = a.createCheckpoint(label: "a")
        async let second = b.createCheckpoint(label: "b")
        let forks = try await [first, second]
        #expect(forks.count == 2)

        let reloaded = Workspace(workspaceID: id, persistence: .directory(root))
        let listed = try await reloaded.checkpoints()
        #expect(listed.count == 2)
        let expectedHead = listed.max {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        let next = try await reloaded.createCheckpoint(label: "next")
        #expect(next.parentID == expectedHead?.id)
    }

    @Test
    func `checkpoint events are pushed across workspace instances`() async throws {
        let root = try TestSupport.temporaryDirectory("CheckpointPush")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        let stream = await reader.events(.init(includeCheckpoints: true))

        let checkpoint = try await writer.createCheckpoint(label: "pushed")
        #expect(try await reader.checkpoints().map(\.id) == [checkpoint.id])
        await reader.refreshCheckpointEvents()

        #expect(await nextPersistenceEvent(in: stream) == .checkpoint(checkpoint))
        await reader.refreshCheckpointEvents()
        #expect(await nextPersistenceEvent(in: stream, timeout: .milliseconds(100)) == nil)
    }

    @Test
    func `history refresh fills sequence gaps and checkpoint cursors use persisted mutations`() async throws {
        let root = try TestSupport.temporaryDirectory("HistoryRefresh")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await reader.history().isEmpty)
        try await writer.writeText("/a", "a")

        // Capture before querying history: the cursor must come from persistence.
        let checkpoint = try await reader.createCheckpoint()
        #expect(checkpoint.mutationCursor == 1)
        #expect(checkpoint.firstMutationSequence == 1)
        #expect(checkpoint.lastMutationSequence == 1)
        #expect(try await reader.history().map(\.sequence) == [1])

        try await writer.writeText("/b", "b")
        try await reader.writeText("/c", "c")
        #expect(try await reader.history().map(\.sequence) == [1, 2, 3])
        #expect(try await reader.history().flatMap { $0.changes.touchedPaths } == ["/a", "/b", "/c"])
        #expect(try await reader.history().map(\.sequence) == [1, 2, 3])
    }

    @Test(arguments: [false, true])
    func `malformed UTF8 in a completed JSONL record throws`(followedByTornTail: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("CorruptLog")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        try await writer.writeText("/a", "a")
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0x22, 0xE2, 0x82, 0x0A]))
        if followedByTornTail { try handle.write(contentsOf: Data("{".utf8)) }
        try handle.close()
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        await #expect(throws: (any Error).self) { _ = try await reader.history() }
    }

    @Test(arguments: [Data("{}".utf8), Data([0x7B, 0x22, 0xE2, 0x82, 0x22, 0x3A, 0x30, 0x7D])])
    func `complete corrupt records throw even without a final newline`(tail: Data) async throws {
        let root = try TestSupport.temporaryDirectory("CompleteCorruptLog")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        try await writer.writeText("/a", "a")
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        try handle.close()
        // Exercise both a full initial load and an incremental read on an already-loaded instance.
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        await #expect(throws: (any Error).self) { _ = try await reader.history() }
        await #expect(throws: (any Error).self) { _ = try await writer.history() }
        await #expect(throws: (any Error).self) { _ = try await writer.writeText("/b", "b") }
    }

    @Test
    func `a complete final mutation missing only its newline survives the next append`() async throws {
        let root = try TestSupport.temporaryDirectory("MissingLogNewline")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let writer = Workspace(workspaceID: id, persistence: .directory(root))
        try await writer.writeText("/a", "a")
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forUpdating: log)
        try handle.truncate(atOffset: handle.seekToEnd() - 1)
        try handle.close()
        let reader = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await reader.history().map(\.sequence) == [1])
        try await reader.writeText("/b", "b")
        let reloaded = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await reloaded.history().map(\.sequence) == [1, 2])
        #expect(try await reloaded.history().flatMap { $0.changes.touchedPaths } == ["/a", "/b"])
    }

    @Test
    func `racy metadata is rehashed even when size and mtime are preserved`() async throws {
        let filesRoot = try TestSupport.temporaryDirectory("RacyFiles")
        let historyRoot = try TestSupport.temporaryDirectory("RacyHistory")
        defer { TestSupport.remove(filesRoot); TestSupport.remove(historyRoot) }
        let local = try LocalFileSystem(root: filesRoot)
        let files = ReadCountingFileSystem(base: local)
        let workspace = Workspace(fileSystem: files, persistence: .directory(historyRoot))
        try await local.writeFile(path: "/note", data: Data("first".utf8), append: false)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))],
            ofItemAtPath: filesRoot.appendingPathComponent("note").path
        )
        let mtime = try #require(try await local.stat(path: "/note").modificationDate)
        let before = try await workspace.createCheckpoint()
        try await local.writeFile(path: "/note", data: Data("other".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: filesRoot.appendingPathComponent("note").path)
        #expect(try await local.stat(path: "/note").modificationDate == mtime)
        await files.resetReadCount()
        let after = try await workspace.createCheckpoint()
        #expect(await files.readCount == 1)
        #expect(try await workspace.readText("/note", at: .checkpoint(before.id)) == "first")
        #expect(try await workspace.readText("/note", at: .checkpoint(after.id)) == "other")
    }

    @Test
    func `content verification detects changes that preserve safely old metadata`() async throws {
        let filesRoot = try TestSupport.temporaryDirectory("VerifiedFiles")
        let historyRoot = try TestSupport.temporaryDirectory("VerifiedHistory")
        defer { TestSupport.remove(filesRoot); TestSupport.remove(historyRoot) }
        let local = try LocalFileSystem(root: filesRoot)
        let workspace = Workspace(fileSystem: local, persistence: .directory(historyRoot), checkpointCapture: .verifyContents)
        let mtime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 10)
        let path = filesRoot.appendingPathComponent("note").path
        try await local.writeFile(path: "/note", data: Data("first".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        _ = try await workspace.createCheckpoint()
        try await local.writeFile(path: "/note", data: Data("other".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        #expect(try await local.stat(path: "/note").modificationDate == mtime)
        let checkpoint = try await workspace.createCheckpoint()
        #expect(try await workspace.readText("/note", at: .checkpoint(checkpoint.id)) == "other")
    }

    @Test
    func `checkpoint capture and queries finish within a timeout`() async throws {
        await #expect(processExitsWith: .success) {
            // An unstructured timeout cannot recover a blocked actor. Bound the child process
            // instead, so the original synchronous-flock deadlock fails without hanging the suite.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(124) }
            let filesRoot = try TestSupport.temporaryDirectory("ConcurrentCaptureFiles")
            let historyRoot = try TestSupport.temporaryDirectory("ConcurrentCaptureHistory")
            defer { TestSupport.remove(filesRoot); TestSupport.remove(historyRoot) }
            for index in 0..<300 {
                try Data("file-\(index)".utf8).write(to: filesRoot.appendingPathComponent("\(index)"))
            }
            let workspace = Workspace(fileSystem: try LocalFileSystem(root: filesRoot), persistence: .directory(historyRoot))
            _ = try await workspace.checkpoints()
            async let capture = workspace.createCheckpoint(label: "a")
            async let queries: Void = {
                for _ in 0..<10 { _ = try await workspace.checkpoints() }
            }()
            let (checkpoint, _) = try await (capture, queries)
            #expect(try await workspace.checkpoints().map(\.id) == [checkpoint.id])
        }
    }

    @Test
    func `revision ranges reject negative lengths without trapping`() async throws {
        await #expect(processExitsWith: .success) {
            let root = try TestSupport.temporaryDirectory("RevisionRanges")
            defer { TestSupport.remove(root) }
            for persistence in [Workspace.Persistence.memory, .directory(root)] {
                let workspace = Workspace(persistence: persistence)
                try await workspace.writeText("/note", "abcdef")
                let checkpoint = try await workspace.createCheckpoint()
                for revision in [Revision.checkpoint(checkpoint.id), .current] {
                    await #expect(throws: WorkspaceError.self) {
                        _ = try await workspace.readData(from: "/note", at: revision, offset: 1, length: -1)
                    }
                    #expect(try await workspace.readData(from: "/note", at: revision, offset: 1, length: 3) == Data("bcd".utf8))
                    #expect(try await workspace.readData(from: "/note", at: revision, offset: 1, length: 0).isEmpty)
                    #expect(try await workspace.readData(from: "/note", at: revision, offset: UInt64.max, length: 3).isEmpty)
                    #expect(try await workspace.readData(from: "/note", at: revision, offset: 4, length: Int.max) == Data("ef".utf8))
                }
            }
        }
    }
}

private func nextPersistenceEvent(
    in stream: AsyncStream<WorkspaceEvent>,
    timeout: Duration = .seconds(2)
) async -> WorkspaceEvent? {
    await withTaskGroup(of: WorkspaceEvent?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private actor ReadCountingFileSystem: FileSystem {
    let base: any FileSystem
    private let capturePause: CaptureReadPause?
    private let cancelAfterWrite: Bool
    private(set) var readCount = 0

    init(base: any FileSystem, capturePause: CaptureReadPause? = nil, cancelAfterWrite: Bool = false) {
        self.base = base
        self.capturePause = capturePause
        self.cancelAfterWrite = cancelAfterWrite
    }

    func resetReadCount() { readCount = 0 }

    func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }
    func readFile(path: WorkspacePath) async throws -> Data {
        readCount += 1
        let data = try await base.readFile(path: path)
        await capturePause?.pauseAfterReading(path)
        return data
    }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await base.writeFile(path: path, data: data, append: append)
        if cancelAfterWrite { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }
    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }
}

private actor CaptureReadPause {
    let path: WorkspacePath
    private var armed = false
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(at path: WorkspacePath) { self.path = path }

    func arm() { armed = true }

    func pauseAfterReading(_ path: WorkspacePath) async {
        guard armed, !paused, path == self.path else { return }
        paused = true
        for waiter in pauseWaiters { waiter.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
