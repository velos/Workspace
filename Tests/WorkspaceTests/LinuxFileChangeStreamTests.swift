#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import Workspace

@Suite("Linux recursive filesystem watching")
struct LinuxFileChangeStreamTests {
    @Test(arguments: ["limited", "sandbox", "mounted", "authorized"])
    func `wrappers deliver scoped native changes in their virtual namespace`(wrapper: String) async throws {
        let root = try TestSupport.temporaryDirectory("WrappedWatch")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let source: any FileSystemChangeSource = switch wrapper {
        case "limited": LimitedFileSystem(base: local, limits: .init())
        case "sandbox": try SandboxFileSystem(root: .url(root))
        case "mounted": MountedFileSystem(mounts: [.init(mountPoint: "/mount", fileSystem: local)])
        default: AuthorizedFileSystem(base: local, authorizer: PermissionAuthorizer { _ in .allow })
        }
        let stream = try await source.changeSignals()
        let signals = LinuxScopedSignals()
        let consumer = Task { for await signal in stream { await signals.record(signal) } }
        defer { consumer.cancel() }
        // Mounted subscriptions are installed asynchronously and announce their
        // initial reconciliation after registering all native streams.
        if wrapper == "mounted" { #expect(await signals.waitForRescan()) }
        try await local.writeFile(path: "/x", data: Data("new".utf8), append: false)
        let path: WorkspacePath = wrapper == "mounted" ? "/mount/x" : "/x"
        #expect(await signals.waitForPath(path, after: 0))
        #expect(await signals.scopes[path] == .entry)
        if let mounted = source as? MountedFileSystem {
            let rescans = await signals.rescans
            mounted.mount("/added", fileSystem: local)
            #expect(await signals.waitForRescan(after: rescans))
            let previous = await signals.count
            try await local.writeFile(path: "/later", data: Data("later".utf8), append: false)
            #expect(await signals.waitForPath("/added/later", after: previous))
            #expect(await signals.waitForPath("/mount/later", after: previous))
        }
    }

    @Test
    func `native stored spellings retain canonical twins and combining mark components`() async throws {
        let container = try TestSupport.temporaryDirectory("UnicodeWatch")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("\u{301}root")
        let fs = try LocalFileSystem(root: root)
        let paths: [WorkspacePath] = ["/caf\u{e9}/\u{301}file", "/cafe\u{301}/\u{301}file"]
        for path in paths { try await fs.writeFile(path: path, data: Data("old".utf8), append: false) }
        let stream = try await fs.changeSignals()
        let signals = LinuxScopedSignals()
        let consumer = Task { for await signal in stream { await signals.record(signal) } }
        defer { consumer.cancel() }
        for path in paths {
            try await fs.writeFile(path: path, data: Data("new".utf8), append: false)
            #expect(await signals.waitForPath(path, after: 0))
            #expect(await signals.scopes[path] == .entry)
        }
        #expect(await signals.rescans == 0)
    }

    @Test
    func `directory creation and removal emit recursive path invalidations`() async throws {
        let root = try TestSupport.temporaryDirectory("ScopedDirectoryWatch")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        let stream = try await fs.changeSignals()
        let signals = LinuxScopedSignals()
        let consumer = Task { for await signal in stream { await signals.record(signal) } }
        defer { consumer.cancel() }
        try await fs.createDirectory(path: "/child", recursive: false)
        #expect(await signals.waitForPath("/child", after: 0))
        #expect(await signals.scopes["/child"] == .recursive)
        let beforeRemoval = await signals.count
        try await fs.remove(path: "/child", recursive: true)
        #expect(await signals.waitForPath("/child", after: beforeRemoval))
        // Include any queued IN_IGNORED notification after watch retirement.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await signals.rescans == 0)
    }

    @Test
    func `file writes are entry scoped and directory metadata is shallow`() async throws {
        let root = try TestSupport.temporaryDirectory("ScopedFileWatch")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/d", recursive: false)
        let stream = try await fs.changeSignals()
        let signals = LinuxScopedSignals()
        let consumer = Task { for await signal in stream { await signals.record(signal) } }
        defer { consumer.cancel() }
        try await fs.writeFile(path: "/x", data: Data("changed".utf8), append: false)
        #expect(await signals.waitForPath("/x", after: 0))
        try await fs.setPermissions(path: "/d", permissions: POSIXPermissions(0o700))
        #expect(await signals.waitForPath("/d", after: 0))
        let userName = ".workspace-" + UUID().uuidString
        let userPath = try WorkspacePath("/" + userName)
        try await fs.writeFile(path: userPath, data: Data("user file".utf8), append: false)
        #expect(await signals.waitForPath(userPath, after: 0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await signals.rescans == 0)
        #expect(await signals.scopes["/x"] == .entry)
        #expect(await signals.scopes["/d"] == .shallow)
        #expect(await signals.scopes[userPath] == .entry)
        #expect(await !signals.scopes.keys.contains { LocalAtomicTemporaryName.matches($0.name) })
    }

    @Test(arguments: [false, true])
    func `directory rename and move out do not rescan after retiring watches`(moveOut: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("RetiredWatch")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d/sub"), withIntermediateDirectories: true)
        let fs = try LocalFileSystem(root: root)
        let stream = try await fs.changeSignals()
        let signals = LinuxScopedSignals()
        let consumer = Task { for await signal in stream { await signals.record(signal) } }
        defer { consumer.cancel() }
        try FileManager.default.moveItem(at: root.appendingPathComponent("d"),
            to: (moveOut ? container : root).appendingPathComponent("e"))
        #expect(await signals.waitForPath("/d", after: 0))
        if !moveOut { #expect(await signals.waitForPath("/e", after: 0)) }
        // IN_IGNORED from our rm_watch arrives in a later batch.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await signals.rescans == 0)
        #expect(await signals.scopes["/d"] == .recursive)
        if !moveOut {
            #expect(await signals.scopes["/e"] == .recursive)
            let previous = await signals.count
            try await fs.writeFile(path: "/e/sub/new", data: Data("new".utf8), append: false)
            #expect(await signals.waitForPath("/e/sub/new", after: previous))
        }
    }

    @Test
    func `recursive watches observe writes inside hidden directories`() async throws {
        let root = try TestSupport.temporaryDirectory("HiddenDirectoryWatch")
        defer { TestSupport.remove(root) }
        let hidden = root.appendingPathComponent(".config/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let file = hidden.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        let before = await counter.value
        try Data("after".utf8).write(to: file)
        #expect(await counter.waitForChange(after: before))
    }

    @Test
    func `removing thousands of watched directories promptly emits an invalidation`() async throws {
        let root = try TestSupport.temporaryDirectory("BulkDirectoryRemoval")
        defer { TestSupport.remove(root) }
        let bulk = root.appendingPathComponent("bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0..<6000 {
            try FileManager.default.createDirectory(
                atPath: bulk.path + "/d\(index)", withIntermediateDirectories: false
            )
        }
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        let clock = ContinuousClock()
        let start = clock.now
        try FileManager.default.removeItem(at: bulk)
        #expect(await counter.waitForChange(after: 0))
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test(.enabled(if: geteuid() != 0, "requires unprivileged filesystem permissions"))
    func `an unreadable root parent does not disable observation`() async throws {
        let parent = try TestSupport.temporaryDirectory("UnreadableWatchParent")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        defer { _ = chmod(parent.path, 0o700); TestSupport.remove(parent) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        // Execute-only access reproduces a non-owner under a 0711 parent.
        #expect(chmod(parent.path, 0o111) == 0)
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        try Data("after".utf8).write(to: file)
        #expect(await counter.waitForChange(after: 0))
    }

    @Test(.enabled(if: geteuid() != 0, "requires unprivileged filesystem permissions"))
    func `unreadable hidden children do not prevent initial or later watches`() async throws {
        let root = try TestSupport.temporaryDirectory("UnreadableHiddenWatch")
        let denied = root.appendingPathComponent(".denied", isDirectory: true)
        defer { _ = chmod(denied.path, 0o700); TestSupport.remove(root) }
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let healthy = root.appendingPathComponent("healthy", isDirectory: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        let file = healthy.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        #expect(chmod(denied.path, 0) == 0)
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        try Data("after".utf8).write(to: file)
        #expect(await counter.waitForChange(after: 0))
        let beforeCreation = await counter.settledValue()
        let later = root.appendingPathComponent("later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let laterFile = later.appendingPathComponent("file")
        try Data("before".utf8).write(to: laterFile)
        #expect(await counter.waitForChange(after: beforeCreation))
        let settled = await counter.settledValue()
        try Data("after".utf8).write(to: laterFile)
        #expect(await counter.waitForChange(after: settled))
    }

    @Test
    func `watch coverage resumes when the observed root is recreated later`() async throws {
        let parent = try TestSupport.temporaryDirectory("ReplacementRootWatch")
        defer { TestSupport.remove(parent) }
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        let before = await counter.value
        try FileManager.default.removeItem(at: root)
        #expect(await counter.waitForChange(after: before))
        let beforeRecreation = await counter.settledValue()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data("new".utf8).write(to: file)
        #expect(await counter.waitForChange(after: beforeRecreation))
        let settled = await counter.settledValue()
        try Data("later".utf8).write(to: file)
        #expect(await counter.waitForChange(after: settled))
    }

    @Test(arguments: [false, true])
    func `recursive watches resume after a directory inode is replaced`(move: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("ReplacementDirectoryWatch")
        defer { TestSupport.remove(root) }
        let watched = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: watched.appendingPathComponent("file"))
        let stream = try DirectoryChangeStream.observe(root, recursive: true)
        let counter = LinuxInvalidationCounter()
        let consumer = Task { for await _ in stream { await counter.increment() } }
        defer { consumer.cancel() }
        let before = await counter.value
        if move {
            try FileManager.default.moveItem(at: watched, to: root.appendingPathComponent("moved"))
        } else {
            try FileManager.default.removeItem(at: watched)
        }
        // Recreate before the observer drains its events: existence at the old pathname
        // must not keep the descriptor attached to the old inode.
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let replacement = watched.appendingPathComponent("file")
        try Data("new".utf8).write(to: replacement)
        #expect(await counter.waitForChange(after: before))
        let settled = await counter.settledValue()
        // Only the child's watch sees this write; directory creation events cannot satisfy it.
        try Data("later".utf8).write(to: replacement)
        #expect(await counter.waitForChange(after: settled))
    }
}

private actor LinuxScopedSignals {
    var count = 0
    var rescans = 0
    var scopes: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
    var lastSeen: [WorkspacePath: Int] = [:]
    func waitForRescan(after previous: Int = 0) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if rescans > previous { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    func record(_ signal: FileSystemChangeSignal) {
        count += 1
        switch signal {
        case .rescan: rescans += 1
        case let .paths(paths):
            for (path, scope) in paths {
                lastSeen[path] = count
                scopes[path] = max(scopes[path] ?? .entry, scope)
            }
        }
    }
    func waitForPath(_ path: WorkspacePath, after previous: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if (lastSeen[path] ?? 0) > previous { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private actor LinuxInvalidationCounter {
    private(set) var value = 0
    func increment() { value += 1 }

    func waitForChange(after previous: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if value > previous { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value > previous
    }

    func settledValue() async -> Int {
        for _ in 0..<20 {
            let previous = value
            try? await Task.sleep(for: .milliseconds(100))
            if value == previous { return value }
        }
        return value
    }
}
#endif
