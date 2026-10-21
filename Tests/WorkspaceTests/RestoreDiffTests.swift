import Foundation
import Testing
@testable import Workspace

@Suite("Scoped checkpoint restore and diff", .serialized)
struct RestoreDiffTests {
    @Test(arguments: [false, true])
    func `native walks collect checkpoint metadata without per child stats`(local: Bool) async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let base: any FileSystem = local ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        try await base.createDirectory(path: "/dir", recursive: true)
        try await base.writeFile(path: "/dir/a", data: Data("old".utf8), append: false)
        try await base.createSymlink(path: "/dangling", target: "../outside")
        let expected = try await Snapshot.capture(from: base)
        let expectedMetadata = try await MetadataIndex.capture(from: base)
        let fs = HookableFileSystem(base: base, scopedWalk: true)
        let store = InMemoryCheckpointStore()
        let id = UUID()
        let checkpoint = try await store.captureRevision(from: fs, draft: .init(
            workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
        #expect(await fs.statCount <= 1)
        #expect(await fs.walks.count == 1)
        let captured = try #require(try await store.loadCapturedRevision(id: checkpoint.snapshotId, workspaceId: id))
        #expect(captured.metadata.entries == expectedMetadata.entries)
        #expect(captured.metadata.exactTimestamps == expectedMetadata.exactTimestamps)
        #expect(try await store.loadSnapshot(id: checkpoint.snapshotId, workspaceId: id)?.entry == expected.entry)
    }

    @Test
    func `evicted capture metadata falls back to reading contents`() async throws {
        let fs = CoarseFileSystem(mode: .coarse, timestamp: Date(timeIntervalSince1970: 1_000))
        try await fs.writeFile(path: "/a", data: Data("old".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        var checkpoints: [Checkpoint] = []
        for _ in 0..<8 { checkpoints.append(try await workspace.createCheckpoint()) }
        let store = await workspace.store
        var retained = 0
        for checkpoint in checkpoints {
            let revision = try #require(try await store.loadCapturedRevision(
                id: checkpoint.snapshotId, workspaceId: workspace.workspaceID))
            if !revision.metadata.entries.isEmpty { retained += 1 }
        }
        #expect(retained > 0 && retained <= 4)
        let oldest = checkpoints[0]
        let evicted = try #require(try await store.loadCapturedRevision(
            id: oldest.snapshotId, workspaceId: workspace.workspaceID))
        #expect(evicted.metadata.entries.isEmpty)
        try await fs.writeFile(path: "/a", data: Data("new".utf8), append: false)
        #expect(try await workspace.diff(from: .checkpoint(oldest.id), to: .current).touchedPaths == ["/a"])
        _ = try await workspace.restore(to: oldest)
        #expect(try await fs.readFile(path: "/a") == Data("old".utf8))
    }

    @Test
    func `current to current diff needs no filesystem access`() async throws {
        let fs = HookableFileSystem()
        let workspace = Workspace(fileSystem: fs)
        await fs.failStat(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        #expect(try await workspace.diff(from: .current, to: .current).isEmpty)
        #expect(await fs.statCount == 0)
        #expect(await fs.reads.isEmpty)
        #expect(await fs.listings.isEmpty)
        #expect(await fs.walks.isEmpty)
    }

    // Extend the edit matrix with structural and byte-identity cases specific to
    // restoring a prior tree. The reference always captures and restores whole trees.
    static let scenarios = EditPathTests.scenarios + [
        .init(description: "file to directory", edits: [.remove("/dir/a"), .createDirectory("/dir/a/sub"), .writeText("/dir/a/sub/new", "new")]),
        .init(description: "directory to file", edits: [.remove("/dir/sub"), .writeText("/dir/sub", "new")]),
        .init(description: "directory to link", edits: [.remove("/dir/sub"), .createSymbolicLink("/dir/sub", target: "../outside")]),
        .init(description: "link to directory", edits: [.remove("/dangling"), .createDirectory("/dangling/sub")]),
        .init(description: "out of root link", edits: [.remove("/link"), .createSymbolicLink("/link", target: "../../outside")]),
        .init(description: "byte distinct targets", edits: [.remove("/link"), .createSymbolicLink("/link", target: "cafe\u{301}")]),
        .init(description: "byte distinct names", edits: [.writeText("/cafe\u{301}", "nfd"), .writeText("/Case", "upper")]),
        .init(description: "binary mode only", edits: [.setPermissions("/binary", POSIXPermissions(0o600))]),
        .init(description: "directory modes", edits: [.setPermissions("/dir/sub", POSIXPermissions(0o500)), .setPermissions("/dir", POSIXPermissions(0o500))]),
        .init(description: "no change", edits: []),
    ]
    static let cases = [false, true].flatMap { local in
        [false, true].flatMap { disk in
            scenarios.filter { local || !$0.memoryRejects }.map { (local, disk, $0) }
        }
    }

    @Test(arguments: cases)
    func `restore diff tree checkpoint and history equal whole tree reference`(
        local: Bool, disk: Bool, scenario: EditPathTests.Scenario
    ) async throws {
        let root = try TestSupport.temporaryDirectory()
        let referenceRoot = try TestSupport.temporaryDirectory()
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root); TestSupport.remove(referenceRoot); TestSupport.remove(storage) }
        let fs: any FileSystem = local ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        let reference: any FileSystem = local ? try LocalFileSystem(root: referenceRoot) : InMemoryFileSystem()
        try await fs.createDirectory(path: "/mnt/data", recursive: true)
        try await fs.createDirectory(path: "/dir/sub", recursive: true)
        try await fs.writeFile(path: "/dir/a", data: Data("alpha".utf8), append: false)
        try await fs.writeFile(path: "/dir/sub/b", data: Data("beta".utf8), append: false)
        try await fs.writeFile(path: "/binary", data: Data([0, 1, 2]), append: false)
        for (path, target) in [("/dirlink", "dir"), ("/dir/link", "a"), ("/link", "dir/a"),
                               ("/dangling", "nowhere"), ("/chain", "dangling")] {
            try await fs.createSymlink(path: WorkspacePath(path), target: target)
        }
        let persistence: Workspace.Persistence = disk ? .directory(storage) : .memory
        var workspace = Workspace(fileSystem: fs, persistence: persistence)
        let target = try await Snapshot.capture(from: fs)
        let checkpoint = try await workspace.createCheckpoint()
        if !scenario.edits.isEmpty { _ = try await workspace.apply(scenario.edits) }
        let before = try await Snapshot.capture(from: fs)
        let history = try await workspace.history()
        if disk {
            workspace = Workspace(workspaceID: workspace.workspaceID, fileSystem: fs, persistence: persistence)
        }
        let expectedDiff = try await ChangeSet.compare(before: RevisionIndex(snapshot: target), after: RevisionIndex(snapshot: before),
            maxTextBytes: DiffOptions.default.maxTextBytes,
            loadBefore: { path in try #require(Workspace.snapshotEntry(at: path, in: target.entry)?.fileBytes) },
            loadAfter: { path in try #require(Workspace.snapshotEntry(at: path, in: before.entry)?.fileBytes) })
        #expect(try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current) == expectedDiff)
        try await Snapshot.restore(before, to: reference)
        try await Snapshot.restore(target, to: reference)
        let expectedTree = try await Snapshot.capture(from: reference)
        let expectedChanges = ChangeSet.compare(before: before, after: expectedTree, maxTextBytes: DiffOptions.default.maxTextBytes)
        let restored = try await workspace.restore(to: checkpoint)
        #expect(try await Snapshot.capture(from: fs).entry == expectedTree.entry)
        let persisted = try await workspace.revisionSnapshot(.checkpoint(restored.id))
        #expect(persisted.entry == expectedTree.entry)
        let actualHistory = try await workspace.history()
        #expect(Array(actualHistory.prefix(history.count)) == history)
        #expect(actualHistory.count == history.count + (expectedChanges.isEmpty ? 0 : 1))
        if !expectedChanges.isEmpty {
            #expect(actualHistory.last?.changes == expectedChanges)
            #expect(actualHistory.last?.operation == .rollback)
        }
        #expect(restored.origin == .rollback(from: checkpoint.id))
        #expect(restored.summary == ChangeSet.compare(before: target, after: expectedTree,
                                                     maxTextBytes: DiffOptions.default.maxTextBytes).summary)
    }

    @Test(arguments: [false, true], [Workspace.RecordingPolicy.full(maxTextBytes: 0), .changesOnly, .off])
    func `restore respects recording policy independently of its changes`(disk: Bool, recording: Workspace.RecordingPolicy) async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let fs = InMemoryFileSystem()
        try await fs.writeFile(path: "/a", data: Data("before".utf8), append: false)
        let workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(storage) : .memory, recording: recording)
        let checkpoint = try await workspace.createCheckpoint()
        try await fs.writeFile(path: "/a", data: Data("after".utf8), append: false)
        let before = try await Snapshot.capture(from: fs)
        _ = try await workspace.restore(to: checkpoint)
        let after = try await Snapshot.capture(from: fs)
        let changes = ChangeSet.compare(before: before, after: after, maxTextBytes: DiffOptions.default.maxTextBytes)
        let history = try await workspace.history()
        if recording == .off { #expect(history.isEmpty) }
        else if case let .full(limit) = recording {
            #expect(history.last?.changes == ChangeSet.compare(before: before, after: after, maxTextBytes: limit))
        } else {
            #expect(history.last?.changes.changes.map(\.path) == changes.changes.map(\.path))
            #expect(history.last?.changes.changes.allSatisfy { $0.diff == nil } == true)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `coarse metadata uses the capture window and verification policy after reopening`(disk: Bool, noIdentity: Bool) async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        for recent in [false, true] {
            for verify in [false, true] {
                for changePermissions in [false, true] {
                    let fs = CoarseFileSystem(mode: noIdentity ? .coarse : .racy,
                        timestamp: recent ? Date().addingTimeInterval(60) : Date(timeIntervalSince1970: 1_000))
                    try await fs.writeFile(path: "/a", data: Data("old".utf8), append: false)
                    let policy: Workspace.CheckpointCapturePolicy = verify ? .verifyContents : .trustMetadata
                    var workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(storage) : .memory, checkpointCapture: policy)
                    let checkpoint = try await workspace.createCheckpoint()
                    if disk {
                        workspace = Workspace(workspaceID: workspace.workspaceID, fileSystem: fs,
                                              persistence: .directory(storage), checkpointCapture: policy)
                    }
                    try await fs.writeFile(path: "/a", data: Data("new".utf8), append: false)
                    if changePermissions { try await fs.setPermissions(path: "/a", permissions: POSIXPermissions(0o600)) }
                    let before = try await Snapshot.capture(from: fs)
                    let expectedDetection = recent || verify || changePermissions
                    #expect(try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current).isEmpty == !expectedDetection)
                    _ = try await workspace.restore(to: checkpoint)
                    #expect(try await fs.readFile(path: "/a") == Data((expectedDetection ? "old" : "new").utf8))
                    let history = try await workspace.history()
                    #expect(history.isEmpty == !expectedDetection)
                    if expectedDetection {
                        let after = try await Snapshot.capture(from: fs)
                        #expect(history.last?.changes == ChangeSet.compare(before: before, after: after,
                                                                          maxTextBytes: DiffOptions.default.maxTextBytes))
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func `identity replacement invalidates safely old matching metadata`(disk: Bool) async throws {
        let root = try TestSupport.temporaryDirectory()
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root); TestSupport.remove(storage) }
        let fs = try LocalFileSystem(root: root)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let url = root.appendingPathComponent("a")
        try await fs.writeFile(path: "/a", data: Data("old".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        var workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(storage) : .memory)
        let checkpoint = try await workspace.createCheckpoint()
        let oldIdentity = try await fs.stat(path: "/a").identity
        // Atomic replacement supplies a distinct inode, keeping the original
        // alive at another name so immediate inode reuse cannot mask the test.
        try await fs.move(from: "/a", to: "/old-inode")
        try await fs.writeFile(path: "/a", data: Data("new".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)
        #expect(try await fs.stat(path: "/a").identity != oldIdentity)
        if disk {
            workspace = Workspace(workspaceID: workspace.workspaceID, fileSystem: fs, persistence: .directory(storage))
        }
        #expect(try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current).touchedPaths.contains("/a"))
        _ = try await workspace.restore(to: checkpoint)
        #expect(try await fs.readFile(path: "/a") == Data("old".utf8))
    }

    @Test(arguments: [false, true])
    func `unchanged files need no content access for diff restore or publication`(disk: Bool) async throws {
        let root = try TestSupport.temporaryDirectory()
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root); TestSupport.remove(storage) }
        let base = try LocalFileSystem(root: root)
        for name in ["changed", "untouched"] {
            try await base.writeFile(path: WorkspacePath("/" + name), data: Data("old".utf8), append: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                                 ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let fs = HookableFileSystem(base: base, forwardsPermissions: true)
        var workspace = Workspace(fileSystem: fs, persistence: disk ? .directory(storage) : .memory)
        let checkpoint = try await workspace.createCheckpoint()
        if disk {
            workspace = Workspace(workspaceID: workspace.workspaceID, fileSystem: fs, persistence: .directory(storage))
        }
        try await base.writeFile(path: "/changed", data: Data("new".utf8), append: false)
        await fs.denyReads(at: "/untouched")
        let readCount = await fs.reads.count
        #expect(try await workspace.diff(from: .checkpoint(checkpoint.id), to: .current).touchedPaths == ["/changed"])
        _ = try await workspace.restore(to: checkpoint)
        #expect(await fs.reads.dropFirst(readCount).allSatisfy { $0 == "/changed" })
        #expect(await fs.writes == ["/changed"])
        #expect(try await base.readFile(path: "/changed") == Data("old".utf8))
    }

    @Test(arguments: [false, true])
    func `sparse restore grants directory access only after denial`(local: Bool) async throws {
        let root = try TestSupport.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("d").path)
            TestSupport.remove(root)
        }
        let base: any FileSystem = local ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        try await base.createDirectory(path: "/d", recursive: true)
        try await base.writeFile(path: "/d/a", data: Data("old".utf8), append: false)
        try await base.setPermissions(path: "/d", permissions: POSIXPermissions(0o500))
        let fs = HookableFileSystem(base: base, forwardsPermissions: true)
        let workspace = Workspace(fileSystem: fs)
        let checkpoint = try await workspace.createCheckpoint()
        try await base.setPermissions(path: "/d", permissions: POSIXPermissions(0o700))
        try await base.writeFile(path: "/d/a", data: Data("new".utf8), append: false)
        try await base.setPermissions(path: "/d", permissions: POSIXPermissions(0o500))
        _ = try await workspace.restore(to: checkpoint)
        #expect(try await base.readFile(path: "/d/a") == Data("old".utf8))
        #expect(try await base.stat(path: "/d").permissions == POSIXPermissions(0o500))
        if local && geteuid() != 0 {
            #expect(await fs.permissionWrites.map(\.permissions) == [POSIXPermissions(0o700), POSIXPermissions(0o500)])
        } else {
            #expect(await fs.permissionWrites.isEmpty)
        }
    }

    @Test
    func `restore keeps cached text for unaffected observation paths`() async throws {
        let fs = SignallingFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("old".utf8), append: false)
        try await fs.base.writeFile(path: "/unrelated", data: Data("before".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        let checkpoint = try await workspace.createCheckpoint()
        let events = await workspace.events(.init(includeCheckpoints: false))
        try await fs.base.writeFile(path: "/a", data: Data("new".utf8), append: false)
        _ = try await workspace.restore(to: checkpoint)
        guard case .changes? = await nextEditEvent(in: events) else {
            Issue.record("missing restore event"); return
        }
        try await fs.base.writeFile(path: "/unrelated", data: Data("after".utf8), append: false)
        fs.signal(.paths(["/unrelated": .entry]))
        guard case let .changes(changes)? = await nextEditEvent(in: events) else {
            Issue.record("missing unrelated external event"); return
        }
        #expect(changes.touchedPaths == ["/unrelated"])
        #expect(changes.textDiffOmissions.isEmpty)
        #expect(changes.changes.first?.diff == TextDiff.lineBased(from: "before", to: "after"))
    }

    @Test(arguments: [false, true])
    func `sparse restore failure recovers prior tree and preserves rollback error`(rollbackFails: Bool) async throws {
        let base = InMemoryFileSystem()
        for path: WorkspacePath in ["/a", "/b", "/unrelated"] {
            try await base.writeFile(path: path, data: Data("old".utf8), append: false)
        }
        let fs = HookableFileSystem(base: base, forwardsPermissions: true)
        let workspace = Workspace(fileSystem: fs)
        let checkpoint = try await workspace.createCheckpoint()
        for path: WorkspacePath in ["/a", "/b"] {
            try await base.writeFile(path: path, data: Data("new".utf8), append: false)
        }
        let before = try await Snapshot.capture(from: base)
        await fs.onWrite { _ in
            await fs.onWrite { _ in
                if rollbackFails { await fs.onWrite { _ in throw TestFileSystemError.injected } }
                throw TestFileSystemError.injected
            }
        }
        do {
            _ = try await workspace.restore(to: checkpoint)
            Issue.record("expected restore failure")
        } catch {
            #expect((error is WorkspaceRollbackError) == rollbackFails)
        }
        if !rollbackFails { #expect(try await Snapshot.capture(from: base).entry == before.entry) }
        #expect(try await workspace.history().isEmpty)
        #expect(try await workspace.checkpoints().count == 1)
        #expect(await fs.writes.allSatisfy { $0 != "/unrelated" })
    }
}

private extension Snapshot.Entry {
    var fileBytes: Data? {
        if case let .file(file) = self { return file.data }
        return nil
    }
}
