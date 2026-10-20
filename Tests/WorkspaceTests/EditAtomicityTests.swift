import Foundation
import Testing
@testable import Workspace

@Suite("Edit atomicity")
struct EditAtomicityTests {
    @Test
    func `single write does not read unrelated files`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/unrelated", data: Data("unrelated".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        try await workspace.writeText("/changed", "new")
        #expect(await fs.reads == ["/changed"])
    }

    @Test(arguments: [Workspace.RecordingPolicy.changesOnly, .off, .full(maxTextBytes: 0)])
    func `recording policy only shapes history`(policy: Workspace.RecordingPolicy) async throws {
        let workspace = Workspace(recording: policy)
        try await workspace.writeText("/a", "old\n")
        let preview = try await workspace.preview([.writeText("/a", "new\n")])
        let result = try await workspace.writeText("/a", "new\n")
        #expect(preview.changes.first?.diff != nil)
        #expect(result.changes.first?.diff != nil)
        #expect(try await workspace.history().allSatisfy { $0.changes.changes.allSatisfy { $0.diff == nil } })
    }

    @Test
    func `rollback works without optional permissions support`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("old".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        await #expect(throws: TestFileSystemError.self) {
            try await workspace.apply([.writeText("/a", "new"), .writeText("/fail", "fail")])
        }
        #expect(try await workspace.readText("/a") == "old")
        #expect(try await workspace.history().isEmpty)
    }

    @Test
    func `local restore preserves symlink targets modes and dangling links`() async throws {
        let root = try TestSupport.temporaryDirectory()
        let outside = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root); TestSupport.remove(outside) }
        let fs = try LocalFileSystem(root: root)
        try await fs.writeFile(path: "/a", data: Data("old".utf8), append: false)
        try await fs.setPermissions(path: "/a", permissions: POSIXPermissions(0o600))
        try await fs.createSymlink(path: "/link", target: "a")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: outside.path)
        let workspace = Workspace(fileSystem: fs)
        let checkpoint = try await workspace.createCheckpoint()
        try await workspace.writeText("/a", "changed")
        _ = try await workspace.restore(to: checkpoint)
        #expect(try await fs.stat(path: "/a").permissions == POSIXPermissions(0o600))
        #expect(try await fs.readSymlink(path: "/dangling") == "missing")
        #expect(try await fs.readSymlink(path: "/outside") == outside.path)
        #expect(try await workspace.readText("/a") == "old")
    }

    @Test
    func `external local file survives failed edit`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let fs = HookableFileSystem(base: local)
        await fs.onWrite { path in
            if path == "/a" {
                try Data("external".utf8).write(to: root.appendingPathComponent("external"))
            }
        }
        let workspace = Workspace(fileSystem: fs)
        await #expect(throws: TestFileSystemError.self) {
            try await workspace.apply([.writeText("/a", "new"), .writeText("/fail", "fail")])
        }
        #expect(try await local.readFile(path: "/external") == Data("external".utf8))
        #expect(!(await workspace.exists("/a")))
    }

    @Test
    func `persistence initialization fails before writing`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let storeURL = root.appendingPathComponent("file")
        try Data().write(to: storeURL)
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs, persistence: .directory(storeURL))
        await #expect(throws: (any Error).self) { try await workspace.writeText("/a", "new") }
        #expect(await fs.writes.isEmpty)
        #expect(!(await workspace.exists("/a")))
    }

    @Test
    func `wrapped access denial during capture is never treated as absence`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("original".utf8), append: false)
        let denial = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.EACCES.rawValue))]
        )
        await fs.failStat(denial)
        let workspace = Workspace(fileSystem: fs)
        await #expect(throws: denial) { try await workspace.writeText("/a", "new") }
        #expect(await fs.writes.isEmpty)
        #expect(try await fs.base.readFile(path: "/a") == Data("original".utf8))
    }

    @Test
    func `post mutation capture failure rolls back`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("old".utf8), append: false)
        await fs.onWrite { path in if path == "/a" { await fs.failNextRead() } }
        let workspace = Workspace(fileSystem: fs)
        await #expect(throws: TestFileSystemError.self) { try await workspace.writeText("/a", "new") }
        #expect(try await workspace.readText("/a") == "old")
        #expect(try await workspace.history().isEmpty)
    }

    @Test
    func `concurrent successful edit survives atomic rollback with consistent history and events`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("original".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        let events = await workspace.events()
        let entered = TestSignal()
        let resume = TestSignal()
        await fs.onWrite { _ in
            await entered.signal()
            await resume.wait()
        }
        let failing = Task {
            await #expect(throws: TestFileSystemError.self) {
                try await workspace.apply([.writeText("/a", "temporary"), .writeText("/fail", "fail")])
            }
        }
        await entered.wait()
        let successful = Task { try await workspace.appendText("/a", "-success") }
        // Give the second operation an opportunity to run during the first
        // operation's deliberately suspended filesystem call.
        for _ in 0..<100 { await Task.yield() }
        await resume.signal()
        _ = await failing.value
        let changes = try await successful.value
        #expect(try await workspace.readText("/a") == "original-success")
        let history = try await workspace.history()
        #expect(history.count == 1)
        #expect(history.first?.changes == changes)
        #expect(await nextEditEvent(in: events) == .changes(changes))
    }

    @Test
    func `journal expands overlapping roots and resolves replace after preceding edits`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let workspace = Workspace(fileSystem: try LocalFileSystem(root: root))
        try await workspace.writeText("/dir/a", "old")
        await #expect(throws: (any Error).self) {
            try await workspace.apply([
                .writeText("/dir/a", "changed"), .remove("/dir"),
                .writeText("/dir/new/deep", "created"),
                .replace(files: .init(root: "/dir"), pattern: .literal("created"), with: "replaced"),
                .writeText("/dir/new/deep/invalid", "fail")
            ])
        }
        #expect(try await workspace.readText("/dir/a") == "old")
        #expect(!(await workspace.exists("/dir/new")))
        let result = try await workspace.apply([
            .writeText("/new/deep/a", "one"),
            .replace(files: .init(root: "/new"), pattern: .literal("one"), with: "two")
        ])
        #expect(try await workspace.readText("/new/deep/a") == "two")
        #expect(result.changes.touchedPaths == ["/new", "/new/deep", "/new/deep/a"])
    }

    @Test(arguments: EditOperation.allCases)
    func `recording failure restores parent for every mutation path`(operation: EditOperation) async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let workspace = Workspace(persistence: .directory(storage))
        try await workspace.writeText("/a", "checkpoint")
        let checkpoint = try await workspace.createCheckpoint()
        let archive = try await workspace.archive(at: "/a")
        try await workspace.writeText("/a", "original")
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "transaction")
        let before = try await workspace.history()
        let log = storage.appendingPathComponent(workspace.workspaceID.uuidString).appendingPathComponent("mutations.jsonl")
        let originalLog = try Data(contentsOf: log)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            switch operation {
            case .edit: _ = try await workspace.writeText("/a", "edit")
            case .archive: _ = try await workspace.restore(archive)
            case .checkpoint: _ = try await workspace.restore(to: checkpoint)
            case .transaction: _ = try await transaction.commit()
            }
        }
        #expect(try await workspace.readText("/a") == "original")
        // history() now reads persistence on every call. Restore the readable baseline
        // before checking that the failed operation did not alter cached history.
        try FileManager.default.removeItem(at: log)
        try originalLog.write(to: log)
        #expect(try await workspace.history() == before)
    }

    @Test
    func `checkpoint persistence failure retracts history and restores filesystem`() async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs, persistence: .directory(storage))
        try await workspace.writeText("/a", "original")
        let checkpoint = try await workspace.createCheckpoint()
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "new")
        let before = try await workspace.history()
        let manifest = storage.appendingPathComponent(workspace.workspaceID.uuidString)
            .appendingPathComponent("snapshots").appendingPathComponent("\(checkpoint.snapshotId.uuidString).json")
        // Remove the manifest only after merge reads, when commit starts writing.
        // This still targets persistence compensation rather than lazy base loading.
        await fs.onWrite { _ in try FileManager.default.removeItem(at: manifest) }
        await #expect(throws: (any Error).self) { try await transaction.commit() }
        #expect(try await workspace.readText("/a") == "original")
        #expect(try await workspace.history() == before)
        let reopened = Workspace(workspaceID: workspace.workspaceID, persistence: .directory(storage))
        #expect(try await reopened.history() == before)
        try await reopened.writeText("/b", "after failure")
        #expect(try await reopened.history().map(\.sequence) == [1, 3])
    }

    @Test(arguments: [EditOperation.transaction, .checkpoint, .archive])
    func `parent restoration serializes against concurrent apply`(operation: EditOperation) async throws {
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs)
        try await workspace.writeText("/a", "target")
        let checkpoint = try await workspace.createCheckpoint()
        let archive = try await workspace.archive(at: "/a")
        try await workspace.writeText("/a", "original")
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "target")
        let events = await workspace.events(.init(includeCheckpoints: false))
        let entered = TestSignal()
        let resume = TestSignal()
        await fs.onWrite { _ in
            await entered.signal()
            await resume.wait()
        }
        let restoring = Task {
            switch operation {
            case .transaction: _ = try await transaction.commit()
            case .checkpoint: _ = try await workspace.restore(to: checkpoint)
            case .archive: _ = try await workspace.restore(archive)
            case .edit: Issue.record("restoration operation required")
            }
        }
        await entered.wait()
        let concurrent = Task { try await workspace.appendText("/a", "-success") }
        // Give the second operation an opportunity to run during the first
        // operation's deliberately suspended filesystem call.
        for _ in 0..<100 { await Task.yield() }
        await resume.signal()
        try await restoring.value
        let appended = try await concurrent.value
        #expect(try await workspace.readText("/a") == "target-success")
        let history = try await workspace.history()
        let expectedOperation: Mutation.Operation = switch operation {
        case .transaction: .transaction
        case .checkpoint: .rollback
        case .archive: .archiveRestore
        case .edit: .edit
        }
        #expect(history.map(\.operation) == [.edit, .edit, expectedOperation, .edit])
        #expect(await nextEditEvent(in: events) == .changes(history[2].changes))
        #expect(await nextEditEvent(in: events) == .changes(appended))
    }

    @Test
    func `read only first use leaves persistence uninitialized`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let storage = root.appendingPathComponent("not-created")
        let workspace = Workspace(persistence: .directory(storage))
        #expect(try await workspace.history().isEmpty)
        #expect(try await workspace.checkpoints().isEmpty)
        let transaction = try await workspace.beginTransaction()
        try await transaction.discard()
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        try await workspace.writeText("/a", "new")
        #expect(FileManager.default.fileExists(atPath: storage.path))
        #expect(try await workspace.history().count == 1)
    }

    @Test
    func `default result diff limit is independent of history limit`() async throws {
        let size = try #require(DiffOptions.default.maxTextBytes) + 1
        let content = String(repeating: "x", count: size)
        let workspace = Workspace(recording: .full(maxTextBytes: size))
        let events = await workspace.events(.init(includeCheckpoints: false))
        let preview = try await workspace.preview([.writeText("/large", content)])
        let result = try await workspace.writeText("/large", content)
        #expect(result == preview)
        #expect(result.changes.first?.diff == nil)
        #expect(result.textDiffOmissions == [.init(path: "/large", reason: .sizeLimitExceeded)])
        #expect(await nextEditEvent(in: events) == .changes(result))
        #expect(try await workspace.history().first?.changes.changes.first?.diff != nil)
        let checkpoint = try await workspace.createCheckpoint()
        let archive = try await workspace.archive(at: "/large")
        try await workspace.writeText("/large", "")
        _ = await nextEditEvent(in: events)
        let restored = try await workspace.restore(archive)
        #expect(restored.textDiffOmissions == result.textDiffOmissions)
        #expect(restored.changes.first?.diff == nil)
        #expect(await nextEditEvent(in: events) == .changes(restored))
        try await workspace.writeText("/large", "")
        _ = await nextEditEvent(in: events)
        _ = try await workspace.restore(to: checkpoint)
        guard case let .changes(rollback)? = await nextEditEvent(in: events) else {
            Issue.record("expected rollback change event")
            return
        }
        #expect(rollback.textDiffOmissions == result.textDiffOmissions)
        #expect(rollback.changes.first?.diff == nil)
    }

    @Test
    func `rollback failure carries both errors`() async throws {
        let fs = HookableFileSystem()
        await fs.failRemovals()
        let workspace = Workspace(fileSystem: fs)
        do {
            try await workspace.apply([.writeText("/a", "new"), .writeText("/fail", "fail")])
            Issue.record("expected rollback failure")
        } catch let error as WorkspaceRollbackError {
            #expect(error.originalError is TestFileSystemError)
            #expect(error.rollbackError is TestFileSystemError)
            #expect(error.description == "injected; restoring the previous state also failed: injected")
        }
    }
}

enum EditOperation: CaseIterable, Sendable {
    case edit, archive, checkpoint, transaction
}

func nextEditEvent(
    in stream: AsyncStream<WorkspaceEvent>, timeout: Duration = .seconds(2)
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
