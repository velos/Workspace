import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import Workspace

@Suite("Review revision regressions")
struct ReviewRevisionTests {
    @Test func `unreadable content reports an omission without blocking later events or retrying`() async throws {
        let fs = SignallingFileSystem()
        let ws = Workspace(fileSystem: fs)
        let events = await ws.events(.init(includeCheckpoints: false))
        try await fs.writeFile(path: "/bad", data: Data("secret".utf8), append: false)
        await fs.base.denyReads(at: "/bad")
        fs.signal(.paths(["/bad": .entry]))
        guard case let .changes(bad)? = await first(events) else { Issue.record("missing unreadable entry"); return }
        #expect(bad.touchedPaths == ["/bad"])
        #expect(bad.textDiffOmissions == [.init(path: "/bad", reason: .contentReadFailed)])
        try await fs.writeFile(path: "/good", data: Data("good".utf8), append: false)
        fs.signal(.paths(["/good": .entry]))
        guard case let .changes(good)? = await first(events) else { Issue.record("later change blocked"); return }
        #expect(good.touchedPaths == ["/good"])
        try await Task.sleep(for: .milliseconds(400))
        #expect(await fs.base.reads.filter { $0 == "/bad" }.count == 1)
    }

    #if os(macOS) || os(Linux)
    @Test func `native unreadable files do not block later filesystem events`() async throws {
        // Root can read mode-000 files; the Docker unprivileged suite exercises this case.
        guard geteuid() != 0 else { return }
        let root = try TestSupport.temporaryDirectory("UnreadableObservation")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let ws = Workspace(fileSystem: local)
        let events = await ws.events(.init(includeCheckpoints: false))
        try await local.writeFile(path: "/bad", data: Data("secret".utf8), append: false)
        try await local.setPermissions(path: "/bad", permissions: POSIXPermissions(0))
        guard case let .changes(bad)? = await first(events) else { Issue.record("missing unreadable native event"); return }
        #expect(bad.textDiffOmissions == [.init(path: "/bad", reason: .contentReadFailed)])
        try await local.writeFile(path: "/good", data: Data("good".utf8), append: false)
        guard case let .changes(good)? = await first(events) else { Issue.record("later native event blocked"); return }
        #expect(good.touchedPaths == ["/good"])
    }
    #endif

    @Test func `metadata retries stop after three attempts and a native signal restarts retained work`() async throws {
        let fs = SignallingFileSystem()
        let ws = Workspace(fileSystem: fs)
        let events = await ws.events(.init(includeCheckpoints: false))
        try await fs.writeFile(path: "/a", data: Data("a".utf8), append: false)
        let stats = await fs.base.statCount
        await fs.base.failStat(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        fs.signal(.rescan)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await fs.base.statCount - stats < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fs.base.statCount - stats == 3)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fs.base.statCount - stats == 3)
        await fs.base.failStat(nil)
        try await fs.writeFile(path: "/z", data: Data("z".utf8), append: false)
        fs.signal(.paths(["/z": .entry]))
        guard case let .changes(changes)? = await first(events) else { Issue.record("pending work was not resumed"); return }
        #expect(changes.touchedPaths == ["/a", "/z"])
    }

    @Test(arguments: [false, true])
    func `compaction preserves reusable bases on dry runs and while their checkpoint survives`(directory: Bool) async throws {
        let storage = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(storage) }
        let fs = HookableFileSystem()
        try await fs.writeFile(path: "/a", data: Data("frozen".utf8), append: false)
        let ws = Workspace(fileSystem: fs, persistence: directory ? .directory(storage) : .memory)
        try await ws.beginTransaction().discard()
        let checkpoint = try await ws.createCheckpoint()
        // Simulate a newer revision arriving through the store without re-seeding this instance.
        _ = try await ws.store.saveRevision(Snapshot.capture(from: fs.base), draft: .init(
            workspaceID: checkpoint.workspaceID, label: nil, preferredParentID: checkpoint.id, origin: .manual))
        let reads = await fs.reads.count
        _ = try await ws.compact(retaining: .latest(1, preservingLabeled: false), dryRun: true)
        try await ws.beginTransaction().discard()
        #expect(await fs.reads.count == reads)
        _ = try await ws.compact(retaining: .latest(1, preservingLabeled: false, preserving: [checkpoint.id]))
        try await ws.beginTransaction().discard()
        #expect(await fs.reads.count == reads)
        _ = try await ws.compact(retaining: .latest(1, preservingLabeled: false))
        #expect(await ws.transactionBase == nil)
        try await ws.beginTransaction().discard()
        #expect(await fs.reads.count == reads + 1)
    }

    @Test func `old timestamps without identities can reuse contents`() async throws {
        let source = CoarseFileSystem(timestamp: Date(timeIntervalSince1970: 1_000))
        let fs = HookableFileSystem(base: source)
        try await fs.writeFile(path: "/a", data: Data("old".utf8), append: false)
        let ws = Workspace(fileSystem: fs)
        try await ws.beginTransaction().discard()
        let reads = await fs.reads.count
        try await ws.beginTransaction().discard()
        #expect(await fs.reads.count == reads)
    }

    @Test func `fresh in memory timestamps reuse unchanged contents and detect appends`() async throws {
        let fs = HookableFileSystem()
        try await fs.writeFile(path: "/a", data: Data("a".utf8), append: false)
        let ws = Workspace(fileSystem: fs)
        try await ws.beginTransaction().discard()
        let reads = await fs.reads.count
        let tx = try await ws.beginTransaction()
        #expect(await fs.reads.count == reads)
        try await fs.writeFile(path: "/a", data: Data("b".utf8), append: true)
        try await tx.writeText("/a", "draft")
        #expect(try await tx.commit().conflicts.map(\.path) == ["/a"])
    }

    @Test func `in memory draft directory and permission symlink semantics match apply`() async throws {
        let source = InMemoryFileSystem()
        try await source.createDirectory(path: "/target", recursive: false)
        try await source.createSymlink(path: "/link", target: "/target")
        let ws = Workspace(fileSystem: source)
        let tx = try await ws.beginTransaction()
        let edits: [Edit] = [.setPermissions("/link", POSIXPermissions(0o700))]
        let expected = try await ws.preview(edits)
        _ = try await tx.apply(edits)
        #expect(try await tx.preview() == expected)
        #expect(try await tx.commit().applied)
        #expect(try await source.stat(path: "/link").permissions == POSIXPermissions(0o700))
        #expect(try await source.stat(path: "/target").permissions == POSIXPermissions(0o755))
        let mkdir = try await ws.beginTransaction()
        await #expect(throws: (any Error).self) { try await mkdir.apply([.createDirectory("/link", recursive: true)]) }
        await #expect(throws: (any Error).self) { try await ws.apply([.createDirectory("/link", recursive: true)]) }
    }

    private func first(_ stream: AsyncStream<WorkspaceEvent>) async -> WorkspaceEvent? {
        await withTaskGroup(of: WorkspaceEvent?.self) { group in
            group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let event = await group.next() ?? nil
            group.cancelAll()
            return event
        }
    }
}
