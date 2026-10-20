import Foundation
import Testing
@testable import Workspace

/// Models coarse or preserved metadata independently of the underlying in-memory clock.
final class CoarseFileSystem: FileSystem, FileSystemChangeSource, Sendable {
    let base = InMemoryFileSystem()
    let stream: AsyncStream<FileSystemChangeSignal>
    let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    enum Mode: Sendable, CaseIterable { case coarse, racy, verified }
    let mode: Mode
    let timestamp: Date
    init(mode: Mode = .coarse, timestamp: Date? = nil) {
        self.mode = mode
        self.timestamp = timestamp ?? (mode == .verified ? Date(timeIntervalSince1970: 1_000) : Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
        (stream, continuation) = AsyncStream.makeStream()
    }
    func signal(_ s: FileSystemChangeSignal) { continuation.yield(s) }
    func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> { stream }
    func changes() async throws -> AsyncStream<Void> { unscopedChanges(stream) }
    func coarse(_ info: FileInfo) -> FileInfo {
        var i = info
        i.identity = mode == .coarse ? nil : FileIdentity(device: 1, inode: info.path == "/a" ? 1 : 2)
        i.modificationDate = timestamp
        return i
    }
    func stat(path: WorkspacePath) async throws -> FileInfo { coarse(try await base.stat(path: path)) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path).map { DirectoryEntry(name: $0.name, info: coarse($0.info)) }
    }
    func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { try await base.glob(pattern: pattern, currentDirectory: currentDirectory) }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { try await base.writeFile(path: path, data: data, append: append) }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from s: WorkspacePath, to d: WorkspacePath) async throws { try await base.move(from: s, to: d) }
    func copy(from s: WorkspacePath, to d: WorkspacePath, recursive: Bool) async throws { try await base.copy(from: s, to: d, recursive: recursive) }
    func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws { try await base.setPermissions(path: path, permissions: permissions) }
}

@Suite("Transaction and observation soundness")
struct ChangeSoundnessTests {
    @Test(arguments: ["discard", "deallocate", "commit"])
    func `cold transaction bytes live only as long as active handles`(finish: String) async throws {
        let storage = try TestSupport.temporaryDirectory("ColdBaseLifetime")
        defer { TestSupport.remove(storage) }
        let allocation = TrackedColdAllocation()
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/a", data: Data(repeating: 42, count: 4096), append: false)
        let fs = HookableFileSystem(base: base, forwardsPermissions: true, transformRead: { allocation.wrapFirst($0) })
        let ws = Workspace(fileSystem: fs, persistence: .directory(storage))
        var transaction: Workspace.Transaction? = try await ws.beginTransaction()
        #expect(allocation.live == 1)
        // A second live handle shares the frozen bytes, even if the first closes.
        let sibling = try await ws.beginTransaction()
        switch finish {
        case "discard": try await transaction!.discard()
        case "deallocate": transaction = nil
        default:
            try await transaction!.writeText("/a", "committed")
            #expect(try await transaction!.commit().applied)
        }
        #expect(allocation.live == 1)
        #expect(try await sibling.readData(from: "/a") == Data(repeating: 42, count: 4096))
        try await sibling.discard()
        #expect(allocation.live == 0)
        // Keep closed handles and the parent alive: neither may retain the payload.
        withExtendedLifetime((transaction, sibling, ws)) {}
    }

    @Test
    func `cold base retains at most its budget and freezes overflow files`() async throws {
        let storage = try TestSupport.temporaryDirectory("ColdBaseOverflow")
        defer { TestSupport.remove(storage) }
        let fs = InMemoryFileSystem()
        let budget = TransactionBacking.memoryBudgetBytes
        try await fs.writeFile(path: "/a", data: Data(count: budget), append: false)
        try await fs.writeFile(path: "/z", data: Data("overflow".utf8), append: false)
        let ws = Workspace(fileSystem: fs, persistence: .directory(storage))
        let transaction = try await ws.beginTransaction()
        let retained = await ws.coldTransactionBase?.tree.nodes.values.reduce(0) { $0 + ($1.fileData?.count ?? 0) }
        #expect(retained == budget)
        try await fs.writeFile(path: "/z", data: Data("external".utf8), append: false)
        #expect(try await transaction.readText("/z") == "overflow")
        try await transaction.discard()
        #expect(await ws.coldTransactionBase == nil)
    }

    @Test(arguments: CoarseFileSystem.Mode.allCases)
    func `same metadata parent writes conflict instead of being overwritten`(mode: CoarseFileSystem.Mode) async throws {
        let fs = CoarseFileSystem(mode: mode)
        let ws = Workspace(fileSystem: fs, checkpointCapture: mode == .verified ? .verifyContents : .trustMetadata)
        try await ws.writeText("/a", "aaaa")
        let tx = try await ws.beginTransaction()
        try await fs.base.writeFile(path: "/a", data: Data("bbbb".utf8), append: false)
        try await tx.writeText("/a", "cccc")
        let commit = try await tx.commit()
        #expect(commit.conflicts.map(\.kind) == [.bothModified])
        #expect(try await ws.readText("/a") == "bbbb")
    }

    @Test(arguments: CoarseFileSystem.Mode.allCases)
    func `unrelated draft edits checkpoint the actual concurrent parent contents`(mode: CoarseFileSystem.Mode) async throws {
        let fs = CoarseFileSystem(mode: mode)
        let ws = Workspace(fileSystem: fs, checkpointCapture: mode == .verified ? .verifyContents : .trustMetadata)
        try await ws.writeText("/a", "aaaa")
        let tx = try await ws.beginTransaction()
        try await fs.base.writeFile(path: "/a", data: Data("bbbb".utf8), append: false)
        try await tx.writeText("/b", "draft")
        let commit = try await tx.commit()
        let cp = try #require(commit.checkpoint)
        let stored = try await ws.readText("/a", at: .checkpoint(cp.id))
        #expect(stored == "bbbb")
    }

    @Test func `draft hard link append survives commit`() async throws {
        let ws = Workspace()
        try await ws.writeText("/a", "x")
        let tx = try await ws.beginTransaction()
        try await tx.createHardLink("/b", target: "/a")
        try await tx.appendText("/a", "yy")
        let draftB = try await tx.readText("/b")
        _ = try await tx.commit()
        let b = try await ws.readText("/b")
        #expect(b == draftB)
    }

    @Test(arguments: [(CoarseFileSystem.Mode.coarse, false), (.coarse, true), (.racy, true), (.verified, false)])
    func `path and rescan signals verify cached metadata`(scenario: (CoarseFileSystem.Mode, Bool)) async throws {
        let (mode, rescan) = scenario
        let fs = CoarseFileSystem(mode: mode)
        try await fs.base.writeFile(path: "/a", data: Data("old\n".utf8), append: false)
        let ws = Workspace(fileSystem: fs)
        let stream = await ws.events(.init(includeCheckpoints: false))
        try await fs.base.writeFile(path: "/a", data: Data("new\n".utf8), append: false)
        fs.signal(rescan ? .rescan : .paths(["/a": .entry]))
        let got = await first(stream)
        guard case let .changes(changes)? = got else { Issue.record("missing rewrite event"); return }
        #expect(changes.touchedPaths == ["/a"])
        #expect(changes.changes.first?.diff != nil)
    }

    @Test func `workspace retries a failed path refresh and preserves later signals`() async throws {
        let fs = FailingSignalFS()
        try await fs.base.writeFile(path: "/a", data: Data("old\n".utf8), append: false)
        try await fs.base.writeFile(path: "/z", data: Data("z\n".utf8), append: false)
        let ws = Workspace(fileSystem: fs)
        let stream = await ws.events(.init(includeCheckpoints: false))
        try await fs.base.writeFile(path: "/a", data: Data("newer\n".utf8), append: false)
        fs.failNext()
        fs.signal(.paths(["/a": .entry]))
        try await Task.sleep(for: .milliseconds(200))
        try await fs.base.writeFile(path: "/z", data: Data("zz\n".utf8), append: false)
        fs.signal(.paths(["/z": .entry]))
        var paths: Set<WorkspacePath> = []
        while paths.count < 2, let e = await first(stream) {
            if case let .changes(c) = e { paths.formUnion(c.touchedPaths) }
        }
        while let e = await first(stream, timeout: .milliseconds(400)) {
            if case let .changes(c) = e { paths.formUnion(c.touchedPaths) }
        }
        #expect(paths == ["/a", "/z"])
    }

    @Test func `directory commits release accumulated file bytes and older base pins`() async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let ws = Workspace(persistence: .directory(storage))
        for i in 0..<20 { try await ws.writeText(WorkspacePath(normalizing: "/f\(i)"), "v") }
        _ = try await ws.createCheckpoint()
        for i in 0..<20 {
            let tx = try await ws.beginTransaction()
            try await tx.writeText(WorkspacePath(normalizing: "/f\(i)"), "changed \(i)")
            _ = try await tx.commit()
        }
        let held = await ws.transactionBase?.nodes.values.filter { $0.fileData != nil }.count ?? -1
        #expect(held == 0)
        let latest = try #require(try await ws.checkpoints().last)
        #expect(TransactionRevisionPins.shared.checkpoints(in: ws.workspaceID) == [latest.id])
    }

    @Test func `later begins verify a reused base against coarse parent metadata`() async throws {
        let fs = CoarseFileSystem()
        let ws = Workspace(fileSystem: fs)
        try await ws.writeText("/a", "aaaa")
        try await ws.beginTransaction().discard()
        try await fs.base.writeFile(path: "/a", data: Data("bbbb".utf8), append: false)
        let tx = try await ws.beginTransaction()
        #expect(try await tx.readText("/a") == "bbbb")
        try await tx.discard()
    }

    @Test func `transaction overwrites retain executable permissions`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/tool", data: Data("old".utf8), append: false)
        try await local.setPermissions(path: "/tool", permissions: POSIXPermissions(0o755))
        let ws = Workspace(fileSystem: local)
        let tx = try await ws.beginTransaction()
        try await tx.writeText("/tool", "new")
        #expect(try await tx.info("/tool").permissions == POSIXPermissions(0o755))
        _ = try await tx.commit()
        #expect(try await local.stat(path: "/tool").permissions == POSIXPermissions(0o755))
    }

    #if os(macOS)
    @Test func `FSEvents preserves scoped paths beneath private temporary roots`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        // Subscribe before writing: the stream itself, not Workspace, must preserve paths.
        let stream = try await fs.changeSignals()
        try await fs.writeFile(path: "/x", data: Data("changed".utf8), append: false)
        let signal = await withTaskGroup(of: FileSystemChangeSignal?.self) { group in
            group.addTask {
                var combined: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
                for await signal in stream {
                    guard case let .paths(paths) = signal else { return signal }
                    combined.merge(paths, uniquingKeysWith: max)
                    if combined["/x"] != nil { return .paths(combined) }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
        guard case let .paths(paths)? = signal else {
            Issue.record("expected scoped FSEvents notification, got \(String(describing: signal))")
            return
        }
        #expect(paths["/x"] == .entry)
        #expect(paths[.root] == nil || paths[.root] == .shallow)
        #expect(!paths.values.contains(.recursive))
        #expect(!paths.keys.contains { LocalAtomicTemporaryName.matches($0.name) })
    }

    @Test func `FSEvents root created immediately before observation stays shallow after one write`() async throws {
        let root = try TestSupport.temporaryDirectory("FreshRootWatch")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        // No settling delay: the root's own creation can arrive with the file event.
        let stream = try await fs.changeSignals()
        try await fs.writeFile(path: "/x", data: Data("changed".utf8), append: false)
        let collector = Task {
            var combined: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
            var rescanned = false
            for await signal in stream {
                switch signal {
                case .rescan: rescanned = true
                case let .paths(paths): combined.merge(paths, uniquingKeysWith: max)
                }
            }
            return (combined, rescanned)
        }
        defer { collector.cancel() }
        // Unlike the first-event probe above, include delayed batches after /x.
        try await Task.sleep(for: .seconds(2))
        collector.cancel()
        let (paths, rescanned) = await collector.value
        #expect(!rescanned)
        #expect(paths["/x"] == .entry)
        #expect(paths[.root] == nil || paths[.root] == .shallow)
        #expect(!paths.values.contains(.recursive))
    }
    #endif

    private func first(_ stream: AsyncStream<WorkspaceEvent>, timeout: Duration = .seconds(5)) async -> WorkspaceEvent? {
        await withTaskGroup(of: WorkspaceEvent?.self) { group in
            group.addTask { var it = stream.makeAsyncIterator(); return await it.next() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let v = await group.next() ?? nil
            group.cancelAll()
            return v
        }
    }
}

/// Tracks the actual buffer returned by the first filesystem read, independently
/// of transaction representation and allocator RSS reuse.
private final class TrackedColdAllocation: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = false
    private var retained = 0
    var live: Int { lock.withLock { retained } }
    func wrapFirst(_ data: Data) -> Data {
        let track = lock.withLock {
            guard !issued else { return false }
            issued = true
            retained += 1
            return true
        }
        guard track else { return data }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 8)
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return Data(bytesNoCopy: pointer, count: data.count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            self.lock.withLock { self.retained -= 1 }
        })
    }
}

final class FailingSignalFS: FileSystem, FileSystemChangeSource, @unchecked Sendable {
    let base = InMemoryFileSystem()
    let stream: AsyncStream<FileSystemChangeSignal>
    let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    let lock = NSLock()
    var fail = false
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func failNext() { lock.withLock { fail = true } }
    func signal(_ s: FileSystemChangeSignal) { continuation.yield(s) }
    func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> { stream }
    func changes() async throws -> AsyncStream<Void> { unscopedChanges(stream) }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        if lock.withLock({ let f = fail; fail = false; return f }) { throw TestFileSystemError.injected }
        return try await base.stat(path: path)
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] { try await base.listDirectory(path: path) }
    func readFile(path: WorkspacePath) async throws -> Data {
        return try await base.readFile(path: path)
    }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] { try await base.glob(pattern: pattern, currentDirectory: currentDirectory) }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { try await base.writeFile(path: path, data: data, append: append) }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from s: WorkspacePath, to d: WorkspacePath) async throws { try await base.move(from: s, to: d) }
    func copy(from s: WorkspacePath, to d: WorkspacePath, recursive: Bool) async throws { try await base.copy(from: s, to: d, recursive: recursive) }
}
