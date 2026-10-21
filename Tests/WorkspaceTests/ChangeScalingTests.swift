import Foundation
import Testing
@testable import Workspace

@Suite("Change-scaled operations")
struct ChangeScalingTests {
    @Test(arguments: [false, true])
    func `local transactions and observation scan metadata through one bulk walk`(edit: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("MetadataWalk")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        for i in 0..<40 {
            try await local.writeFile(path: WorkspacePath("/tree/d\(i)/file"), data: Data("old".utf8), append: false)
        }
        let counted = HookableFileSystem(base: local, forwardsPermissions: true, scopedWalk: true)
        let storage = try TestSupport.temporaryDirectory("ColdMetadataWalk")
        defer { TestSupport.remove(storage) }
        let directoryWorkspace = Workspace(fileSystem: counted, persistence: .directory(storage))
        let cold = try await directoryWorkspace.beginTransaction()
        #expect(await counted.walks == [.root])
        #expect(await counted.reads.isEmpty) // Contents come from scoped walk callbacks.
        #expect(await counted.statCount == 0)
        #expect(await counted.listings.isEmpty)
        #expect(try await cold.readText("/tree/d0/file") == "old")
        try await cold.discard()
        await counted.resetMetadataCounts()
        let workspace = Workspace(fileSystem: counted)
        let transaction = try await workspace.beginTransaction()
        #expect(await counted.walks == [.root])
        #expect(await counted.statCount == 0)
        #expect(await counted.listings.isEmpty)

        if edit { try await transaction.writeText("/tree/d0/file", "new") }
        await counted.resetMetadataCounts()
        #expect(try await transaction.commit().applied)
        // Changed leaves use stat for their scoped reconciliation after restoration.
        #expect(await counted.walks == [.root])
        #expect(await counted.statCount < 10)
        #expect(await counted.listings.isEmpty)

        var observation = try await FilesystemObservation.start(on: counted, budget: 1024)
        try await local.writeFile(path: "/tree/d1/file", data: Data("external".utf8), append: false)
        await counted.resetMetadataCounts()
        #expect(try await observation.refresh(on: counted, signal: .rescan).touchedPaths == ["/tree/d1/file"])
        #expect(await counted.walks == [.root])
        #expect(await counted.statCount == 0)
        #expect(await counted.listings.isEmpty)

        try await local.writeFile(path: "/tree/new/deep/file", data: Data("added".utf8), append: false)
        await counted.resetMetadataCounts()
        let changes = try await observation.refresh(on: counted, signal: .paths(["/tree": .shallow]))
        #expect(changes.touchedPaths == ["/tree/new", "/tree/new/deep", "/tree/new/deep/file"])
        #expect(await counted.walks == ["/tree/new"])
        #expect(await counted.listings == ["/tree"])
        await counted.resetMetadataCounts()
        #expect(try await observation.refresh(on: counted, signal: .paths(["/tree": .recursive])).isEmpty)
        #expect(await counted.walks == ["/tree"])
        #expect(await counted.listings.isEmpty)
    }

    @Test(arguments: ["../missing.txt", "./.././missing.txt", "../shared/.env"], [false, true])
    func `leading dotdot dangling targets do not read unrelated files`(target: String, localBackend: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("LeadingDotdotJournal")
        defer { TestSupport.remove(root) }
        let base: any FileSystem = localBackend ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        try await base.createDirectory(path: "/a", recursive: true)
        try await base.writeFile(path: "/other/file", data: Data("unrelated".utf8), append: false)
        try await base.createSymlink(path: "/a/link", target: target)
        let reads = JournalReadCounter(base: base)
        let workspace = Workspace(fileSystem: reads)
        let changes = try await workspace.writeText("/a/link", "new")
        let destination = try WorkspacePath(target, relativeTo: "/a")
        #expect(changes.touchedPaths.contains(destination))
        #expect(try await base.readFile(path: destination) == Data("new".utf8))
        #expect(await reads.paths.contains(destination))
        #expect(!(await reads.paths.contains("/other/file")))
    }

    @Test
    func `preview excludes untouched symlinks and reads only affected contents`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/edit", data: Data("old".utf8), append: false)
        try await local.writeFile(path: "/unrelated", data: Data(repeating: 1, count: 2_000_000), append: false)
        try await local.createSymlink(path: "/link", target: "unrelated")
        try await local.createSymlink(path: "/dangling", target: "absent")
        let counted = HookableFileSystem(base: local)
        let workspace = Workspace(fileSystem: counted)
        let preview = try await workspace.preview([.writeText("/edit", "new")])
        #expect(preview.touchedPaths == ["/edit"])
        #expect(await counted.reads.allSatisfy { $0 == "/edit" })
        #expect(try await local.readSymlink(path: "/link") == "unrelated")
        #expect(try await local.readSymlink(path: "/dangling") == "absent")
        #expect(try await workspace.readText("/edit") == "old")
        #expect(try await workspace.writeText("/edit", "new") == preview)
    }

    @Test(arguments: [false, true])
    func `checkpoint based transactions keep unread files frozen without rereading parent contents`(directory: Bool) async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let fs = HookableFileSystem(base: try LocalFileSystem(root: root), forwardsPermissions: true)
        try await fs.base.writeFile(path: "/edit", data: Data("old".utf8), append: false)
        try await fs.base.writeFile(path: "/unread", data: Data("frozen".utf8), append: false)
        try await fs.base.writeFile(path: "/untouched", data: Data(repeating: 1, count: 1_000_000), append: false)
        let workspace = Workspace(fileSystem: fs, persistence: directory ? .directory(storage) : .memory)
        for name in ["edit", "unread", "untouched"] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                                  ofItemAtPath: root.appendingPathComponent(name).path)
        }
        // First use freezes the base; subsequent checkpoints may prime transaction reuse.
        try await workspace.beginTransaction().discard()
        _ = try await workspace.createCheckpoint()
        let readsBefore = await fs.reads.count
        let transaction = try await workspace.beginTransaction()
        #expect(await fs.reads.count == readsBefore)
        // The draft has never read this file. Mutate outside the Workspace gate.
        try await fs.base.writeFile(path: "/unread", data: Data("external".utf8), append: false)
        #expect(try await transaction.readText("/unread") == "frozen")
        try await transaction.writeText("/edit", "draft")
        #expect(try await transaction.preview().touchedPaths == ["/edit"])
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.readText("/unread") == "external")
        #expect(try await workspace.readText("/edit") == "draft")
        // Directory-store capture has its own conservative timestamp verification;
        // the memory case isolates transaction reads from that independent policy.
        if !directory {
            #expect(await fs.reads.dropFirst(readsBefore).allSatisfy { $0 != "/untouched" })
        }
    }

    @Test
    func `compaction preserves a lazy transaction base until the handle releases it`() async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let workspace = Workspace(persistence: .directory(storage))
        try await workspace.writeText("/unread", "frozen")
        try await workspace.beginTransaction().discard()
        let checkpoint = try await workspace.createCheckpoint()
        let transaction = try await workspace.beginTransaction()
        try await workspace.writeText("/unread", "parent")
        _ = try await workspace.createCheckpoint()
        let report = try await workspace.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(!report.removedCheckpointIDs.contains(checkpoint.id))
        #expect(try await transaction.readText("/unread") == "frozen")
        try await transaction.writeText("/new", "draft")
        #expect(try await transaction.commit().applied)
        #expect(try await workspace.readText("/unread") == "parent")
    }

    @Test(arguments: [0, 8], [false, true])
    func `external changes respect the content budget and never enter history`(budget: Int, unknownPaths: Bool) async throws {
        let fs = SignallingFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("old\n".utf8), append: false)
        try await fs.base.writeFile(path: "/large", data: Data(repeating: 120, count: 100_000), append: false)
        let workspace = Workspace(fileSystem: fs, observation: .init(contentCacheBytes: budget))
        let stream = await workspace.events(.init(includeCheckpoints: false))
        let initialReads = await fs.base.reads.count
        let initialStats = await fs.base.statCount
        #expect(await fs.base.reads.allSatisfy { $0 == "/a" })
        try await fs.base.writeFile(path: "/a", data: Data("new\n".utf8), append: false)
        for _ in 0..<20 { fs.signal(unknownPaths ? .rescan : .paths(["/a": .entry])) }
        guard case let .changes(changes)? = await event(in: stream) else {
            Issue.record("missing external event")
            return
        }
        #expect(changes.touchedPaths == ["/a"])
        #expect((changes.changes[0].diff != nil) == (budget > 0))
        #expect(changes.textDiffOmissions == (budget == 0 ? [.init(path: "/a", reason: .observationCacheMiss)] : []))
        #expect(await fs.base.reads.dropFirst(initialReads).allSatisfy { $0 == "/a" })
        #expect(await fs.base.reads.count - initialReads <= 1)
        #expect(try await workspace.history().isEmpty)
        #expect(await event(in: stream, timeout: .milliseconds(150)) == nil)
        #expect(await fs.base.statCount - initialStats <= 2)
    }

    @Test
    func `observation distinguishes replacements removals and metadata only changes`() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(path: "/d", recursive: true)
        try await fs.writeFile(path: "/d/file", data: Data("old\n".utf8), append: false)
        try await fs.createSymlink(path: "/link", target: "d/file")
        var observation = try await FilesystemObservation.start(on: fs, budget: 100)
        let before = try await Snapshot.capture(from: fs)
        try await fs.remove(path: "/d", recursive: true)
        try await fs.writeFile(path: "/d", data: Data("replacement\n".utf8), append: false)
        try await fs.remove(path: "/link", recursive: false)
        try await fs.createSymlink(path: "/link", target: "d")
        try await fs.setPermissions(path: .root, permissions: POSIXPermissions(0o700))
        let expected = ChangeSet.compare(before: before, after: try await Snapshot.capture(from: fs), maxTextBytes: DiffOptions.default.maxTextBytes)
        #expect(try await observation.refresh(on: fs, signal: .rescan) == expected)
        #expect(try await observation.refresh(on: fs, signal: .rescan).isEmpty)
    }

    @Test
    func `content read failure omits only that diff and follows hard link aliases`() async throws {
        let fs = HookableFileSystem()
        try await fs.base.writeFile(path: "/a", data: Data("old".utf8), append: false)
        try await fs.base.createHardLink(path: "/alias", target: "/a")
        try await fs.base.writeFile(path: "/z", data: Data("old".utf8), append: false)
        var observation = try await FilesystemObservation.start(on: fs, budget: 100)
        let before = try await Snapshot.capture(from: fs.base)
        try await fs.base.writeFile(path: "/a", data: Data("-new".utf8), append: true)
        try await fs.base.writeFile(path: "/z", data: Data("changed".utf8), append: false)
        await fs.onRead { _ in await fs.onRead { _ in throw TestFileSystemError.injected } }
        let changes = try await observation.refresh(on: fs, signal: .paths(["/a": .entry, "/z": .entry]))
        let expected = ChangeSet.compare(before: before, after: try await Snapshot.capture(from: fs.base), maxTextBytes: DiffOptions.default.maxTextBytes)
        #expect(changes.touchedPaths == expected.touchedPaths)
        #expect(changes.textDiffOmissions == [.init(path: "/alias", reason: .contentReadFailed)])
        #expect(changes.changes.filter { $0.path != "/alias" } == expected.changes.filter { $0.path != "/alias" })
    }

    @Test(arguments: [0, -1])
    func `disabled observation caching does not read even empty files`(budget: Int) async throws {
        let fs = SignallingFileSystem()
        try await fs.base.writeFile(path: "/empty", data: Data(), append: false)
        let workspace = Workspace(fileSystem: fs, observation: .init(contentCacheBytes: budget))
        let stream = await workspace.events(.init(includeCheckpoints: false))
        #expect(await fs.base.reads.isEmpty)
        withExtendedLifetime(stream) {}
    }

    @Test
    func `observation evicts the least recently used contents`() async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeFile(path: "/a", data: Data("old\n".utf8), append: false)
        try await fs.writeFile(path: "/b", data: Data("old\n".utf8), append: false)
        var observation = try await FilesystemObservation.start(on: fs, budget: 8)
        // An unchanged path signal still uses the cached contents for byte comparison.
        #expect(try await observation.refresh(on: fs, signal: .paths(["/a": .entry])).isEmpty)
        try await fs.writeFile(path: "/c", data: Data("new\n".utf8), append: false)
        _ = try await observation.refresh(on: fs, signal: .paths(["/c": .entry]))
        try await fs.writeFile(path: "/a", data: Data("new\n".utf8), append: false)
        let recent = try await observation.refresh(on: fs, signal: .paths(["/a": .entry]))
        #expect(recent.changes.first?.diff != nil)
        try await fs.writeFile(path: "/b", data: Data("new\n".utf8), append: false)
        let evicted = try await observation.refresh(on: fs, signal: .paths(["/b": .entry]))
        #expect(evicted.textDiffOmissions == [.init(path: "/b", reason: .observationCacheMiss)])
    }

    private func event(in stream: AsyncStream<WorkspaceEvent>, timeout: Duration = .seconds(2)) async -> WorkspaceEvent? {
        await withTaskGroup(of: WorkspaceEvent?.self) { group in
            group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }
}

final class SignallingFileSystem: FileSystemChangeSource, ExactTimestampFileSystem, Sendable {
    var hasExactContentTimestamps: Bool { get async { await base.supportsExactContentTimestamps } }
    let base: HookableFileSystem
    let source: (any FileSystemChangeSource)?
    let stream: AsyncStream<FileSystemChangeSignal>
    let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    init(base: any FileSystem = InMemoryFileSystem(), source: (any FileSystemChangeSource)? = nil) {
        self.base = HookableFileSystem(base: base)
        self.source = source
        (stream, continuation) = AsyncStream.makeStream()
    }
    func signal(_ signal: FileSystemChangeSignal) { continuation.yield(signal) }
    func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        if let source { return try await source.changeSignals() }
        return stream
    }
    func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] { try await base.listDirectory(path: path) }
    func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { try await base.glob(pattern: pattern, currentDirectory: currentDirectory) }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { try await base.writeFile(path: path, data: data, append: append) }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { try await base.move(from: sourcePath, to: destinationPath) }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws { try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive) }
}

// Forward real-path resolution so this counter exercises the journal's canonical-path route.
private actor JournalReadCounter: FileSystem {
    let base: any FileSystem
    var paths: Set<WorkspacePath> = []
    init(base: any FileSystem) { self.base = base }
    func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] { try await base.listDirectory(path: path) }
    func readFile(path: WorkspacePath) async throws -> Data {
        paths.insert(path)
        return try await base.readFile(path: path)
    }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try await base.writeFile(path: path, data: data, append: append)
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from: WorkspacePath, to: WorkspacePath) async throws { try await base.move(from: from, to: to) }
    func copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool) async throws { try await base.copy(from: from, to: to, recursive: recursive) }
    func createSymlink(path: WorkspacePath, target: String) async throws { try await base.createSymlink(path: path, target: target) }
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws { try await base.createHardLink(path: path, target: target) }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws { try await base.setPermissions(path: path, permissions: permissions) }
    func capabilities() async -> FileSystemFeatures { await base.capabilities() }
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath { try await base.resolveRealPath(path: path) }
}
