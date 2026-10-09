#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import Workspace

@Suite("Linux recursive filesystem watching")
struct LinuxFileChangeStreamTests {
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
