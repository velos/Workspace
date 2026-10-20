import Foundation
import Testing
@testable import Workspace
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Exact path identity")
struct PathIdentityRegressionTests {
    private let nfc: WorkspacePath = "/caf\u{e9}"
    private let nfd: WorkspacePath = "/cafe\u{301}"

    // Foundation URL file writes can normalize the last component on macOS.
    private func seed(_ root: URL, _ name: String, data: Data = Data([1, 2])) throws {
        let fd = open(root.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
    }

    private func expectPOSIX(_ code: Int32, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected POSIX error \(code), operation succeeded")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(code))
        }
    }

    @Test
    func pathsAndDirectoryKeysKeepCanonicalTwinsDistinct() async throws {
        #expect(nfc != nfd)
        #expect(Set([nfc, nfd]).count == 2)
        #expect([nfc, nfd].sorted() == [nfd, nfc])
        #expect(!nfd.appending("x").isWithin(nfc))
        let memory = InMemoryFileSystem()
        for (path, data) in [(nfc, Data([1])), (nfd, Data([2]))] {
            try await memory.createFile(path: path, data: data)
        }
        #expect(try await memory.listDirectory(path: .root).count == 2)
        #expect(try await memory.readFile(path: nfc) == Data([1]))
        #expect(try await memory.readFile(path: nfd) == Data([2]))
        let mounted = MountedFileSystem(base: memory)
        #expect(try await mounted.listDirectory(path: .root).count == 2)
        let overlay = OverlayFileSystem(over: memory)
        #expect(try await overlay.listDirectory(path: .root).count == 2)
        try await overlay.remove(path: nfc, recursive: false)
        #expect(try await overlay.readFile(path: nfd) == Data([2]))
    }

    @Test(arguments: [false, true])
    func allowRulesDoNotGrantCanonicalTwin(mounted: Bool) async throws {
        let memory = InMemoryFileSystem()
        let base: any FileSystem = mounted
            ? MountedFileSystem(mounts: [.init(mountPoint: nfd, fileSystem: memory)]) : memory
        try await base.createDirectory(path: nfd, recursive: true)
        try await base.writeFile(path: nfd.appending("secret"), data: Data([42]), append: false)
        let fs = AuthorizedFileSystem(base: base, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile], pathPrefix: nfc, effect: .allow),
        ]))
        await #expect(throws: WorkspaceError.self) { _ = try await fs.readFile(path: nfd.appending("secret")) }
    }

    @Test
    func quotasCountBothCanonicalTwins() async throws {
        // Raw disk fixtures let the old accounting dictionary demonstrate its own
        // collapse, independently of the old in-memory directory dictionary.
        #if canImport(Glibc)
        let root = try TestSupport.temporaryDirectory("IdentityQuota")
        defer { TestSupport.remove(root) }
        try seed(root, nfc.name)
        try seed(root, nfd.name)
        let base: any FileSystem = try LocalFileSystem(root: root)
        #else
        let base: any FileSystem = InMemoryFileSystem()
        try await base.writeFile(path: nfc, data: Data([1, 2]), append: false)
        try await base.writeFile(path: nfd, data: Data([3, 4]), append: false)
        #endif
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 4))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 5, limit: 4)) {
            try await fs.writeFile(path: "/extra", data: Data([5]), append: false)
        }
        #expect(!(await base.exists(path: "/extra")))
    }

    @Test(arguments: [false, true])
    func checkpointsArchivesAndDiffsKeepBothNames(diskStore: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("IdentityHistory")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskStore ? .directory(root) : .memory)
        try await workspace.writeData(Data([1]), to: nfc)
        try await workspace.writeData(Data([2]), to: nfd)
        let before = try await workspace.createCheckpoint()
        #expect(try await workspace.readData(from: nfc, at: .checkpoint(before.id)) == Data([1]))
        #expect(try await workspace.readData(from: nfd, at: .checkpoint(before.id)) == Data([2]))
        let archive = try await workspace.archive(from: .checkpoint(before.id))
        let restored = Workspace()
        try await restored.restore(archive)
        #expect(try await restored.list(.root).count == 2)
        try await workspace.writeData(Data([3]), to: nfd)
        let after = try await workspace.createCheckpoint()
        let diff = try await workspace.diff(from: .checkpoint(before.id), to: .checkpoint(after.id))
        #expect(diff.touchedPaths.count == 1)
        #expect(diff.touchedPaths.first?.string.utf8.elementsEqual(nfd.string.utf8) == true)
        try await workspace.remove(nfd)
        try await restored.restore(workspace.archive())
        let remaining = try await restored.list(.root)
        #expect(remaining.count == 1)
        #expect(remaining.first?.info.path.string.utf8.elementsEqual(nfc.string.utf8) == true)
    }

    @Test
    func parentedCanonicalTwinSavesInMemory() async {
        await #expect(processExitsWith: .success) {
            try await PathIdentityRegressionTests.checkParentedCanonicalTwinSaves(diskStore: false)
        }
    }

    @Test
    func parentedCanonicalTwinSavesInDirectory() async {
        await #expect(processExitsWith: .success) {
            try await PathIdentityRegressionTests.checkParentedCanonicalTwinSaves(diskStore: true)
        }
    }

    private static func checkParentedCanonicalTwinSaves(diskStore: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("IdentityParentedSaves")
        defer { TestSupport.remove(root) }
        let store: any CheckpointStore = diskStore
            ? FileCheckpointStore(rootDirectory: root) : InMemoryCheckpointStore()
        let workspaceID = UUID()
        try await store.prepare(workspaceId: workspaceID)
        let nfc: WorkspacePath = "/caf\u{e9}"
        let nfd: WorkspacePath = "/cafe\u{301}"
        // Supply snapshots directly: the old InMemoryFileSystem collapses these
        // names before capture and would mask the checkpoint-store crash.
        let contents: [[(WorkspacePath, UInt8)]] = [
            [(nfd, 1), (nfc, 2)],
            [(nfd, 3), (nfc, 4)],
            [(nfd, 5)],
        ]
        var checkpoints: [Checkpoint] = []
        for files in contents {
            let snapshot = Snapshot(rootPath: .root, entry: .directory(.init(
                path: .root, permissions: .defaultDirectory,
                children: files.map { path, byte in
                    .file(.init(path: path, data: Data([byte]), permissions: .defaultFile))
                }
            )))
            let parentID = checkpoints.last?.id
            let checkpoint = try await store.saveRevision(snapshot, draft: .init(
                workspaceID: workspaceID, label: nil, preferredParentID: parentID, origin: .manual
            ))
            #expect(checkpoint.parentID == parentID)
            checkpoints.append(checkpoint)
        }

        // Reopen directory persistence so the assertions exercise serialized
        // manifests and blobs, as well as the in-memory store's materialized tree.
        let reader: any CheckpointStore = diskStore
            ? FileCheckpointStore(rootDirectory: root) : store
        let restored = InMemoryFileSystem()
        var previousSnapshot: Snapshot?
        var previousIndex: RevisionIndex?
        for (offset, checkpoint) in checkpoints.enumerated() {
            let snapshot = try #require(await reader.loadSnapshot(
                id: checkpoint.snapshotId, workspaceId: workspaceID
            ))
            let index = try #require(await reader.loadRevisionIndex(
                id: checkpoint.snapshotId, workspaceId: workspaceID
            ))
            if let previousSnapshot, let previousIndex {
                let snapshotDiff = ChangeSet.compare(
                    before: previousSnapshot, after: snapshot, maxTextBytes: 0
                )
                let indexDiff = try await ChangeSet.compare(
                    before: previousIndex, after: index, maxTextBytes: 0,
                    loadBefore: { _ in throw POSIXError(.EIO) },
                    loadAfter: { _ in throw POSIXError(.EIO) }
                )
                // Compare bytes explicitly so baseline String equality cannot
                // conceal a dropped twin or incorrect ordering.
                let expected = [nfd, nfc].map { Array($0.string.utf8) }
                #expect(snapshotDiff.changes.map { Array($0.path.string.utf8) } == expected)
                #expect(indexDiff.changes.map { Array($0.path.string.utf8) } == expected)
            }
            try await Snapshot.restore(snapshot, to: restored)
            let entries = try await restored.listDirectory(path: .root)
            #expect(entries.map { Array($0.name.utf8) } == contents[offset].map { Array($0.0.name.utf8) })
            for (path, byte) in contents[offset] {
                #expect(try await restored.readFile(path: path) == Data([byte]))
            }
            previousSnapshot = snapshot
            previousIndex = index
        }
    }

    @Test(arguments: [false, true])
    func symlinkTargetChangesAreByteExact(diskStore: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("IdentitySymlink")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskStore ? .directory(root) : .memory)
        try await workspace.createDirectory(nfc)
        try await workspace.createDirectory(nfd)
        try await workspace.writeData(Data([1]), to: nfc.appending("\u{301}file"))
        try await workspace.writeData(Data([2]), to: nfd.appending("\u{301}file"))
        try await workspace.createSymbolicLink("/alias", target: nfc.string)
        let before = try await workspace.createCheckpoint()
        try await workspace.remove("/alias")
        let changed = try await workspace.createSymbolicLink("/alias", target: nfd.string)
        #expect(changed.touchedPaths == ["/alias"])
        let after = try await workspace.createCheckpoint()
        #expect(try await workspace.diff(from: .checkpoint(before.id), to: .checkpoint(after.id)).touchedPaths == ["/alias"])
        for (checkpoint, byte) in [(before, UInt8(1)), (after, UInt8(2))] {
            #expect(try await workspace.readData(from: "/alias/\u{301}file", at: .checkpoint(checkpoint.id)) == Data([byte]))
        }
    }

    #if canImport(Darwin)
    private func caseInsensitive(_ root: URL) throws -> Bool {
        try seed(root, "case-probe")
        let insensitive = access(root.path + "/CASE-PROBE", F_OK) == 0
        if !insensitive { print("SKIP: exact-spelling case tests require a case-insensitive volume: \(root.path)") }
        return insensitive
    }

    @Test
    func caseAliasCannotBypassDenyRule() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityAuthorization")
        defer { TestSupport.remove(root) }
        guard try caseInsensitive(root) else { return }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/private", recursive: true)
        try await local.writeFile(path: "/private/secret", data: Data([42]), append: false)
        let fs = AuthorizedFileSystem(base: local, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile], pathPrefix: "/private", effect: .deny(message: nil)),
        ], defaultEffect: .allow))
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: "/PRIVATE/secret") }
        try await local.createSymlink(path: "/alias", target: "private/secret")
        #expect(try await local.resolveRealPath(path: "/alias") == "/private/secret")
        await #expect(throws: WorkspaceError.self) { _ = try await fs.readFile(path: "/alias") }
    }

    @Test
    func caseVariantOperationsRejectAliases() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityCase")
        defer { TestSupport.remove(root) }
        guard try caseInsensitive(root) else { return }
        let fs = try LocalFileSystem(root: root)
        try await fs.writeFile(path: "/file", data: Data([7]), append: false)
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: "/FILE") }
        await expectPOSIX(ENOENT) { _ = try await fs.stat(path: "/FILE") }
        await expectPOSIX(ENOENT) { _ = try await fs.resolveRealPath(path: "/FILE") }
        await expectPOSIX(EEXIST) { try await fs.writeFile(path: "/FILE", data: Data([9]), append: false) }
        await expectPOSIX(EEXIST) { try await fs.writeFile(path: "/FILE", data: Data([9]), append: true) }
        await expectPOSIX(EEXIST) { try await fs.createFile(path: "/FILE", data: Data([9])) }
        await expectPOSIX(EEXIST) { try await fs.move(from: "/file", to: "/FILE") }
        await expectPOSIX(ENOENT) { try await fs.move(from: "/FILE", to: "/moved") }
        try await fs.remove(path: "/FILE", recursive: false) // missing removal is a no-op
        #expect(try await fs.readFile(path: "/file") == Data([7]))
        try await fs.createDirectory(path: "/dir", recursive: false)
        await expectPOSIX(EEXIST) { try await fs.createDirectory(path: "/DIR", recursive: true) }
        await expectPOSIX(EEXIST) { try await fs.writeFile(path: "/DIR/new", data: Data([1]), append: false) }
        await expectPOSIX(EEXIST) { try await fs.copy(from: "/file", to: "/FILE", recursive: false) }
        await expectPOSIX(ENOENT) { try await fs.createHardLink(path: "/link", target: "/FILE") }
        #expect(try await fs.listDirectory(path: "/dir").isEmpty)
    }

    @Test(arguments: [false, true])
    func middleAncestorAliasIsRejectedAcrossOpenPaths(relocateRoot: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("IdentityAncestors")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard try caseInsensitive(root) else { return }
        let fs = try LocalFileSystem(root: root)
        try await fs.createFile(path: "/one/middle/three/file", data: Data([42]))
        // Prime the alias before testing both metadata and open-based operations.
        let aliasFD = open(root.path + "/one/MIDDLE/three/file", O_RDONLY)
        #expect(aliasFD >= 0)
        close(aliasFD)
        if relocateRoot {
            // The pinned root remains usable, but its old F_GETPATH prefix no
            // longer matches. This forces per-component spelling verification.
            try FileManager.default.moveItem(at: root, to: container.appendingPathComponent("relocated"))
        }
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: "/one/MIDDLE/three/file") }
        await expectPOSIX(ENOENT) { _ = try await fs.stat(path: "/one/MIDDLE/three/file") }
        await expectPOSIX(ENOENT) { _ = try await fs.listDirectory(path: "/one/MIDDLE/three") }
        await expectPOSIX(ENOENT) { _ = try await fs.resolveRealPath(path: "/one/MIDDLE/three/file") }
        var aliasedVisits = 0
        try await fs.walk(at: "/one/MIDDLE/three") { _, _, _ in aliasedVisits += 1 }
        #expect(aliasedVisits == 0) // Walk treats an ENOENT root as missing.
        await expectPOSIX(EEXIST) {
            try await fs.writeFile(path: "/one/MIDDLE/three/new", data: Data([9]), append: false)
        }
        try await fs.createSymlink(path: "/relative", target: "one/MIDDLE/../middle/three/file")
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: "/relative") }
        #expect(try await fs.readFile(path: "/one/middle/three/file") == Data([42]))
        var storedFiles: [WorkspacePath] = []
        try await fs.walk(at: "/one/middle/three") { info, read, _ in
            if info.kind == .file {
                storedFiles.append(info.path)
                let data = try await read(nil)
                #expect(data == Data([42]))
            }
        }
        #expect(storedFiles == ["/one/middle/three/file"])
        #expect(!(await fs.exists(path: "/one/middle/three/new")))
    }

    @Test
    func longAPFSPathsFallBackWithoutConfusingHardLinkNames() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityLongPath")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        let component = String(repeating: "d", count: 180)
        let parent = try WorkspacePath("/" + Array(repeating: component, count: 7).joined(separator: "/"))
        let path = parent.appending("file")
        try await fs.createFile(path: path, data: Data([42]))
        try await fs.createHardLink(path: "/other-name", target: path)
        // Opening the other hard link must not make F_GETPATH on a final file fd
        // an apparent spelling mismatch. Directory paths also exceed MAXPATHLEN.
        #expect(try await fs.readFile(path: "/other-name") == Data([42]))
        #expect(try await fs.readFile(path: path) == Data([42]))
        #expect(try await fs.resolveRealPath(path: path) == path)
        try await fs.remove(path: .root.appending(component), recursive: true)
        #expect(try await fs.readFile(path: "/other-name") == Data([42]))
    }

    @Test
    func apfsRejectsNormalizationAliases() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityNormalization")
        defer { TestSupport.remove(root) }
        try seed(root, nfc.name)
        guard access(root.path + nfd.string, F_OK) == 0 else {
            print("SKIP: normalization-alias test requires a normalization-insensitive volume")
            return
        }
        let fs = try LocalFileSystem(root: root)
        #expect(try await fs.readFile(path: nfc) == Data([1, 2]))
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: nfd) }
        await expectPOSIX(EEXIST) { try await fs.writeFile(path: nfd, data: Data([9]), append: false) }
        await expectPOSIX(EEXIST) { try await fs.createFile(path: nfd, data: Data([9])) }
        #expect(try await fs.resolveRealPath(path: nfc).string.utf8.elementsEqual(nfc.string.utf8))
        #expect(try await fs.listDirectory(path: .root).map(\.name).first?.utf8.elementsEqual(nfc.name.utf8) == true)
        try await fs.remove(path: nfc, recursive: false)
        try await fs.createFile(path: nfd, data: Data([3]))
        #expect(try await fs.readFile(path: nfd) == Data([3]))
        #expect(try await fs.listDirectory(path: .root).first?.name.utf8.elementsEqual(nfd.name.utf8) == true)
        await expectPOSIX(ENOENT) { _ = try await fs.readFile(path: nfc) }
    }
    #endif

    #if canImport(Glibc)
    @Test
    func linuxRejectsUndecodableDirectoryNames() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityInvalidUTF8")
        defer { TestSupport.remove(root) }
        let bytes = Array((root.path + "/").utf8) + [0xFF, 0]
        let fd = bytes.withUnsafeBytes {
            open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        close(fd)
        try seed(root, "\u{fffd}")
        let fs = try LocalFileSystem(root: root)
        await #expect(throws: WorkspaceError.self) { _ = try await fs.listDirectory(path: .root) }
    }

    @Test
    func linuxLocalAllowRuleDoesNotGrantCanonicalTwin() async throws {
        let root = try TestSupport.temporaryDirectory("IdentityLinux")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: nfc, recursive: true)
        try await local.createDirectory(path: nfd, recursive: true)
        try await local.writeFile(path: nfd.appending("secret"), data: Data([42]), append: false)
        let fs = AuthorizedFileSystem(base: local, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile], pathPrefix: nfc, effect: .allow),
        ]))
        await #expect(throws: WorkspaceError.self) { _ = try await fs.readFile(path: nfd.appending("secret")) }
        #expect(try await local.listDirectory(path: .root).count == 2)
    }
    #endif
}
