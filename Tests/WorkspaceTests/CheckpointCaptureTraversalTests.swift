import Foundation
import Testing
@testable import Workspace
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CheckpointCaptureTraversalTests {
    @Test(arguments: [Workspace.CheckpointCapturePolicy.trustMetadata, .verifyContents], [false, true])
    func captureRoutesPersistIdenticalTrees(policy: Workspace.CheckpointCapturePolicy, inMemory: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("CaptureRoutes")
        defer { TestSupport.remove(container) }
        let files = container.appendingPathComponent("files")
        let local: any FileSystem = inMemory ? InMemoryFileSystem() : try LocalFileSystem(root: files)
        try await local.createDirectory(path: "/a/empty", recursive: true)
        try await local.createFile(path: "/a/file", data: Data([0, 1, 255]))
        try await local.createFile(path: "/a-", data: Data("ordering\n".utf8))
        try await local.setPermissions(path: "/a/file", permissions: POSIXPermissions(0o640))
        try await local.setPermissions(path: "/a", permissions: POSIXPermissions(0o750))
        try await local.createHardLink(path: "/hard", target: "/a/file")
        for (name, target) in [("dangling", "missing"), ("cycle", "cycle"),
                               ("alias", "a"), ("escape", container.appendingPathComponent("outside").path)] {
            if inMemory { try await local.createSymlink(path: WorkspacePath("/" + name), target: target) }
            else {
                try FileManager.default.createSymbolicLink(atPath: files.appendingPathComponent(name).path,
                                                           withDestinationPath: target)
            }
        }
        try Data("outside".utf8).write(to: container.appendingPathComponent("outside"))
        // macOS volumes cannot host both spellings. A real mounted backend can,
        // and also exercises forwarding plus mixed bulk/per-path traversal.
        let unicode: any FileSystem = inMemory ? local : InMemoryFileSystem()
        let unicodeRoot: WorkspacePath = inMemory ? "/unicode" : .root
        if inMemory { try await unicode.createDirectory(path: unicodeRoot, recursive: true) }
        try await unicode.createFile(path: unicodeRoot.appending("caf\u{e9}"), data: Data([1]))
        try await unicode.createFile(path: unicodeRoot.appending("cafe\u{301}"), data: Data([2]))
        let source: any FileSystem = inMemory ? local :
            MountedFileSystem(base: local, mounts: [.init(mountPoint: "/unicode", fileSystem: unicode)])
        let id = UUID()
        let roots = [container.appendingPathComponent("bulk"), container.appendingPathComponent("paths")]
        let stores = roots.map { FileCheckpointStore(rootDirectory: $0, checkpointCapture: policy) }
        let old = Date(timeIntervalSince1970: 1)
        for name in inMemory ? [] : ["a/file", "a-"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: files.appendingPathComponent(name).path)
        }
        var parents: [UUID?] = [nil, nil]
        var priorTrees: [String: Data] = [:]
        for phase in 0..<4 {
            if phase == 2 {
                try await local.createFile(path: "/a/new", data: Data("new\n".utf8))
                try await local.setPermissions(path: "/a/file", permissions: POSIXPermissions(0o600))
                try await source.writeFile(path: "/unicode/cafe\u{301}", data: Data([3]), append: false)
            }
            if phase == 3 {
                try await local.remove(path: "/a/new", recursive: false)
                try await local.remove(path: "/alias", recursive: false)
                try await local.createSymlink(path: "/alias", target: "missing")
            }
            // Pin in-memory mtimes well outside the racy window on both routes,
            // including the mounted in-memory subtree in the local variant.
            // Advance only the rewritten file's timestamp so metadata reuse must
            // still detect its same-size content change in phase 2.
            let transformInfo: @Sendable (FileInfo) -> FileInfo = { info in
                var info = info
                if info.kind == .file, inMemory || info.path.isWithin("/unicode") {
                    let changed = phase >= 2 && info.path == "/unicode/cafe\u{301}"
                    info.modificationDate = old.addingTimeInterval(changed ? 1 : 0)
                }
                return info
            }
            let bulk = CaptureSource(source, scoped: true, transformInfo: transformInfo)
            let paths = CaptureSource(source, scoped: false, transformInfo: transformInfo)
            var manifests: [Data] = []
            var summaries: [ChangeSet.Summary] = []
            for (i, fs) in [bulk, paths].enumerated() {
                let checkpoint = try await stores[i].captureRevision(from: fs, draft: .init(
                    workspaceID: id, label: nil, preferredParentID: parents[i], origin: .manual))
                parents[i] = checkpoint.id
                summaries.append(checkpoint.summary)
                let captured = try #require(await stores[i].loadCapturedRevision(id: checkpoint.snapshotId, workspaceId: id))
                let expected = try await MetadataIndex.capture(from: source)
                #expect(Set(captured.metadata.entries.keys) == Set(expected.entries.keys))
                for (path, entry) in expected.entries {
                    let hint = try #require(captured.metadata.entries[path])
                    #expect(hint.info.identity == entry.info.identity)
                    #expect(hint.info.modificationDate == transformInfo(entry.info).modificationDate)
                    #expect(hint.info.permissions == entry.info.permissions)
                    #expect(hint.info.kind == entry.info.kind)
                    #expect(hint.target == entry.target)
                    if entry.info.kind == .file { #expect(hint.info.size == entry.info.size) }
                }
                #expect(captured.metadata.exactTimestamps == expected.exactTimestamps)
                #expect(captured.metadata.exactTimestamps == inMemory)
                let url = roots[i].appendingPathComponent(id.uuidString)
                    .appendingPathComponent("snapshots/\(checkpoint.snapshotId).json")
                var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                // These are intentionally fresh for every capture; all persisted node
                // metadata, hashes, targets and ordering must match byte for byte.
                manifest.removeValue(forKey: "id")
                manifest.removeValue(forKey: "captureStartedAt")
                manifests.append(try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
            }
            #expect(manifests[0] == manifests[1])
            #expect(summaries[0] == summaries[1])
            let trees = try artifacts(roots[0].appendingPathComponent(id.uuidString).appendingPathComponent("trees"))
            #expect(try trees == artifacts(roots[1].appendingPathComponent(id.uuidString).appendingPathComponent("trees")))
            if phase == 1 { #expect(trees == priorTrees) }
            priorTrees = trees
            #expect(bulk.walkCount == 1)
            #expect(bulk.statCount == 0 && bulk.listCount == 0)
            #expect(bulk.reads == paths.reads)
            if policy == .trustMetadata {
                if phase == 1 { #expect(bulk.reads.isEmpty) }
                if phase == 2 { #expect(bulk.reads == ["/a/new", "/unicode/cafe\u{301}"]) }
            }
            if policy == .verifyContents { #expect(bulk.reads.contains("/a/file")) }
        }
    }

    @Test
    func materializedSaveOmitsChildrenThatVanishedDuringCapture() async throws {
        let root = try TestSupport.temporaryDirectory("VanishedSnapshotChild")
        defer { TestSupport.remove(root) }
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/present", data: Data("retained".utf8), append: false)
        let snapshot = try await Snapshot.capture(from: GhostFileSystem(base: base, code: ENOENT))
        guard case let .directory(directory) = snapshot.entry else {
            Issue.record("expected a directory snapshot")
            return
        }
        #expect(directory.children.contains { if case .missing = $0 { return true }; return false })
        let id = UUID()
        let store = FileCheckpointStore(rootDirectory: root)
        let checkpoint = try await store.saveRevision(snapshot,
            draft: .init(workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
        let reopened = FileCheckpointStore(rootDirectory: root)
        let saved = try #require(await reopened.loadSnapshot(id: checkpoint.snapshotId, workspaceId: id))
        #expect(saved.entry == (try await Snapshot.capture(from: base)).entry)
        #expect(try await reopened.snapshotEntry(id: checkpoint.snapshotId, workspaceId: id,
                                               path: "/ghost", includeChildren: false) == nil)
    }

    @Test(arguments: [false, true])
    func racyTimestampsAndMissingBlobsForceReads(scoped: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("CaptureReuse")
        defer { TestSupport.remove(container) }
        let files = container.appendingPathComponent("files")
        let local = try LocalFileSystem(root: files)
        let source = CaptureSource(local, scoped: scoped)
        let dates = ["stable": Date(timeIntervalSince1970: 1), "replaced": Date(timeIntervalSince1970: 1), "racy": Date().addingTimeInterval(60)]
        for (name, date) in dates {
            try await local.createFile(path: WorkspacePath(normalizing: "/" + name), data: Data("old".utf8))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: files.appendingPathComponent(name).path)
        }
        let id = UUID()
        let root = container.appendingPathComponent("store")
        let store = FileCheckpointStore(rootDirectory: root)
        let first = try await store.captureRevision(from: source, draft: .init(
            workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
        for (name, date) in dates {
            if name == "replaced" {
                // Atomic replacement changes identity despite equal size and old mtime.
                try await local.writeFile(path: WorkspacePath(normalizing: "/" + name), data: Data("new".utf8), append: false)
            } else {
                // Preserve identity to isolate the timestamp-window contract.
                let handle = try FileHandle(forWritingTo: files.appendingPathComponent(name))
                try handle.write(contentsOf: Data("new".utf8))
                try handle.close()
            }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: files.appendingPathComponent(name).path)
        }
        source.reset()
        let second = try await store.captureRevision(from: source, draft: .init(
            workspaceID: id, label: nil, preferredParentID: first.id, origin: .manual))
        #expect(source.reads == ["/racy", "/replaced"])
        #expect(second.summary.touchedPaths == ["/racy", "/replaced"])
        #expect(try await store.readSnapshotFile(id: second.snapshotId, workspaceId: id, path: "/racy", offset: 0, length: nil) == Data("new".utf8))
        // Repair an absent CAS object with the same bytes. A different payload
        // would still fail when the summary tries to read the damaged parent.
        try await local.writeFile(path: "/stable", data: Data("old".utf8), append: false)
        try FileManager.default.setAttributes([.modificationDate: dates["stable"]!], ofItemAtPath: files.appendingPathComponent("stable").path)
        let hash = SHA256.hexDigest(of: Data("old".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("blobs/" + hash))
        source.reset()
        let repaired = try await store.captureRevision(from: source, draft: .init(
            workspaceID: id, label: nil, preferredParentID: second.id, origin: .manual))
        #expect(source.reads == ["/racy", "/stable"])
        #expect(try await store.readSnapshotFile(id: repaired.snapshotId, workspaceId: id, path: "/stable", offset: 0, length: nil) == Data("old".utf8))
    }

    @Test(arguments: [false, true])
    func identityOnlyReplacementRefreshesCaptureHints(scoped: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("CaptureIdentity")
        defer { TestSupport.remove(container) }
        let files = container.appendingPathComponent("files")
        let local = try LocalFileSystem(root: files)
        let source = CaptureSource(local, scoped: scoped)
        let store = FileCheckpointStore(rootDirectory: container.appendingPathComponent("store"))
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1)
        var parent: UUID?
        var previousIdentity: FileIdentity?
        for phase in 0..<3 {
            if phase < 2 {
                try await local.writeFile(path: "/file", data: Data("same".utf8), append: false)
                try FileManager.default.setAttributes([.modificationDate: old],
                    ofItemAtPath: files.appendingPathComponent("file").path)
            }
            let info = try await local.stat(path: "/file")
            if phase == 1 { #expect(info.identity != previousIdentity) }
            source.reset()
            let checkpoint = try await store.captureRevision(from: source, draft: .init(
                workspaceID: id, label: nil, preferredParentID: parent, origin: .manual))
            // An identity-only replacement must update the tree even though its
            // content hash is unchanged, then allow the next capture to reuse it.
            let captured = try #require(await store.loadCapturedRevision(id: checkpoint.snapshotId, workspaceId: id))
            #expect(captured.metadata.entries["/file"]?.info.identity == info.identity)
            #expect(source.reads == (phase < 2 ? ["/file"] : []))
            if phase > 0 { #expect(checkpoint.summary.touchedPaths.isEmpty) }
            previousIdentity = info.identity
            parent = checkpoint.id
        }
    }

    @Test(arguments: [Int32(ENOENT), Int32(ENOTDIR)])
    func vanishedListedChildrenAreOmittedByBothRoutes(code: Int32) async throws {
        let root = try TestSupport.temporaryDirectory("CaptureVanished")
        defer { TestSupport.remove(root) }
        let base = InMemoryFileSystem()
        try await base.createFile(path: "/real", data: Data([1]))
        let ghost = GhostFileSystem(base: base, code: code)
        do {
            try await ghost.walk { _, _, _ in }
            Issue.record("ordinary walks must still report vanished children")
        } catch { #expect((error as NSError).code == Int(code)) }
        let id = UUID()
        var trees: [[String: Data]] = []
        for scoped in [false, true] {
            let directory = root.appendingPathComponent(scoped ? "walk" : "paths")
            let store = FileCheckpointStore(rootDirectory: directory)
            let checkpoint = try await store.captureRevision(from: CaptureSource(ghost, scoped: scoped), draft: .init(
                workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
            let snapshot = try #require(await store.loadSnapshot(id: checkpoint.snapshotId, workspaceId: id))
            guard case let .directory(captured) = snapshot.entry else { Issue.record("expected directory"); return }
            #expect(captured.children.map(\.path) == ["/real"])
            #expect(checkpoint.summary.touchedPaths == [.root, "/real"])
            trees.append(try artifacts(directory.appendingPathComponent(id.uuidString).appendingPathComponent("trees")))
        }
        #expect(trees[0] == trees[1])
    }

    @Test(arguments: [false, true])
    func captureRoutesProduceIdenticalPackLayout(inMemory: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("CapturePacks")
        defer { TestSupport.remove(container) }
        let local: any FileSystem = inMemory ? InMemoryFileSystem() : try LocalFileSystem(root: container.appendingPathComponent("files"))
        for path: WorkspacePath in ["/a", "/a0"] {
            try await local.createDirectory(path: path, recursive: true)
        }
        for i in 0..<32 { try await local.createFile(path: WorkspacePath(normalizing: String(format: "/%02d", i)), data: Data([UInt8(i)])) }
        for name in ["a/leaf", "a-", "a0/leaf", "a0-", "z"] {
            try await local.createFile(path: WorkspacePath(normalizing: "/" + name), data: Data(name.utf8))
        }
        let id = UUID()
        var packBytes: [Data] = []
        var ranges: [Data] = []
        for (i, fs) in [CaptureSource(local, scoped: true), CaptureSource(local, scoped: false)].enumerated() {
            let root = container.appendingPathComponent("store\(i)")
            let store = FileCheckpointStore(rootDirectory: root)
            _ = try await store.captureRevision(from: fs, draft: .init(workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
            let packs = try artifacts(root.appendingPathComponent(id.uuidString).appendingPathComponent("packs"))
            let pack = try #require(packs.first { $0.key.hasSuffix(".pack") })
            packBytes.append(pack.value)
            let index = try #require(packs[String(pack.key.dropLast(5)) + ".json"])
            var entries = try #require(JSONSerialization.jsonObject(with: index) as? [String: [String: Any]])
            for hash in entries.keys { entries[hash]?.removeValue(forKey: "pack") }
            ranges.append(try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]))
        }
        #expect(packBytes[0] == packBytes[1])
        #expect(ranges[0] == ranges[1]) // random pack UUIDs differ; hashes and ranges must not.
    }

    @Test
    func unreadableDirectoriesAndFailedReadsPublishNoCheckpoint() async throws {
        let container = try TestSupport.temporaryDirectory("CaptureErrors")
        let files = container.appendingPathComponent("files")
        let blocked = files.appendingPathComponent("blocked")
        defer { _ = chmod(blocked.path, 0o755); TestSupport.remove(container) }
        let local = try LocalFileSystem(root: files)
        try await local.createFile(path: "/blocked/child", data: Data([1]))
        for scoped in [false, true] {
            let id = UUID()
            let store = FileCheckpointStore(rootDirectory: container.appendingPathComponent("store"))
            if geteuid() != 0 {
                #expect(chmod(blocked.path, 0) == 0)
                do {
                    _ = try await store.captureRevision(from: CaptureSource(local, scoped: scoped), draft: .init(
                        workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
                    Issue.record("unreadable directories must fail capture")
                } catch {
                    #expect((error as NSError).domain == NSPOSIXErrorDomain)
                    #expect((error as NSError).code == Int(EACCES))
                }
                #expect(chmod(blocked.path, 0o755) == 0)
            }
            // Disappearance after metadata, during the requested read, is an error
            // on both routes and must not become a published partial snapshot.
            let source = CaptureSource(local, scoped: scoped, failingRead: true)
            do {
                _ = try await store.captureRevision(from: source, draft: .init(
                    workspaceID: id, label: nil, preferredParentID: nil, origin: .manual))
                Issue.record("failed content reads must fail capture")
            } catch { #expect((error as NSError).code == Int(ENOENT)) }
            #expect(try await store.listCheckpoints(workspaceId: id).isEmpty)
        }
    }

    private func artifacts(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

/// Records reads on the actual descriptor callback as well as the per-path route.
private final class CaptureSource: FileSystem, TraversingFileSystem, ExactTimestampFileSystem, @unchecked Sendable {
    var hasExactContentTimestamps: Bool { get async { await base.supportsExactContentTimestamps } }
    let base: any FileSystem
    let supportsScopedWalk: Bool
    let failingRead: Bool
    private let transformInfo: @Sendable (FileInfo) -> FileInfo
    private let lock = NSLock()
    private var recordedReads: [WorkspacePath] = []
    private var counts = (walk: 0, stat: 0, list: 0)
    var reads: [WorkspacePath] { lock.withLock { recordedReads } }
    var walkCount: Int { lock.withLock { counts.walk } }
    var statCount: Int { lock.withLock { counts.stat } }
    var listCount: Int { lock.withLock { counts.list } }
    init(_ base: any FileSystem, scoped: Bool, failingRead: Bool = false,
         transformInfo: @escaping @Sendable (FileInfo) -> FileInfo = { $0 }) {
        self.base = base; supportsScopedWalk = scoped; self.failingRead = failingRead
        self.transformInfo = transformInfo
    }
    func reset() { lock.withLock { recordedReads = []; counts = (0, 0, 0) } }
    private func record(_ path: WorkspacePath) throws {
        lock.withLock { recordedReads.append(path) }
        if failingRead { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
    }
    nonisolated(nonsending) func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool,
        skippingVanishedEntries: Bool = false, visit: FileSystemWalkVisitor) async throws {
        lock.withLock { counts.walk += 1 }
        try await base.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
            skippingVanishedEntries: skippingVanishedEntries) { info, read, link in
            try await withoutActuallyEscaping(read) { read in
                try await withoutActuallyEscaping(link) { link in
                    try await visit(self.transformInfo(info), { length in
                        try self.record(info.path)
                        return try await read(length)
                    }, { try await link() })
                }
            }
        }
    }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        lock.withLock { counts.stat += 1 }
        return transformInfo(try await base.stat(path: path))
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        lock.withLock { counts.list += 1 }
        return try await base.listDirectory(path: path).map {
            DirectoryEntry(name: $0.name, info: transformInfo($0.info))
        }
    }
    func readFile(path: WorkspacePath) async throws -> Data { try record(path); return try await base.readFile(path: path) }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { try await base.glob(pattern: pattern, currentDirectory: currentDirectory) }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { throw WorkspaceError.readOnly }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func remove(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { throw WorkspaceError.readOnly }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
}

/// Enumerates a child which disappears before its own metadata is requested.
private final class GhostFileSystem: FileSystem, Sendable {
    let base: any FileSystem
    let code: Int32
    init(base: any FileSystem, code: Int32) { self.base = base; self.code = code }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        if path == "/ghost" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        return try await base.stat(path: path)
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        var entries = try await base.listDirectory(path: path)
        if path.isRoot { entries.append(.init(name: "ghost", info: .init(path: "/ghost", kind: .file, size: 1, permissions: .defaultFile, modificationDate: nil))) }
        return entries
    }
    func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { throw WorkspaceError.unsupported("test glob") }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { throw WorkspaceError.readOnly }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func remove(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { throw WorkspaceError.readOnly }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
}
