import Foundation
import Testing
@testable import Workspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Filesystem regression contracts")
struct FileSystemRegressionTests {
    @Test
    func `concurrent writes cannot share the same remaining quota`() async throws {
        for _ in 0..<20 {
            let memory = InMemoryFileSystem()
            let limited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 5))
            let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
                for path: WorkspacePath in ["/a", "/b"] {
                    group.addTask {
                        do {
                            try await limited.writeFile(path: path, data: Data("1234".utf8), append: false)
                            return true
                        } catch let error as FileSystemLimitError {
                            #expect(error == .totalBytes(attempted: 8, limit: 5))
                            return false
                        }
                    }
                }
                var count = 0
                for try await success in group where success { count += 1 }
                return count
            }
            #expect(successes == 1)
            #expect(try await memory.listDirectory(path: "/").count == 1)
            // A rejected preflight must release the gate for the next mutation.
            for path: WorkspacePath in ["/a", "/b"] { try await limited.remove(path: path, recursive: false) }
            try await limited.createFile(path: "/after", data: Data("12345".utf8))
        }
    }

    @Test
    func `quota gate spans an awaited backend mutation`() async throws {
        let memory = InMemoryFileSystem()
        let latch = RegressionMutationLatch()
        let backend = RegressionBackend(memory: memory, writeLatch: latch)
        let limited = LimitedFileSystem(base: backend, limits: .init(maxTotalBytes: 5))
        let first = Task { try await limited.writeFile(path: "/first", data: Data("1234".utf8), append: false) }
        await latch.waitUntilEntered()
        let second = Task { () -> Bool in
            do {
                try await limited.writeFile(path: "/second", data: Data("1234".utf8), append: false)
                return true
            } catch let error as FileSystemLimitError {
                #expect(error == .totalBytes(attempted: 8, limit: 5))
                return false
            }
        }
        for _ in 0..<10 { await Task.yield() }
        await latch.release()
        try await first.value
        #expect(try await second.value == false)
        #expect(try await memory.listDirectory(path: "/").map(\.name) == ["first"])
    }

    @Test
    func `dangling symlinks count as entries but not regular file bytes`() async throws {
        let memory = InMemoryFileSystem()
        let none = LimitedFileSystem(base: memory, limits: .init(maxEntryCount: 0))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 1, limit: 0)) {
            try await none.createSymlink(path: "/dangling", target: "/missing")
        }
        #expect(!(await memory.exists(path: "/dangling")))
        let one = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 0, maxEntryCount: 1))
        try await one.createSymlink(path: "/dangling", target: "/missing")
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 2, limit: 1)) {
            try await one.createSymlink(path: "/another", target: "/missing")
        }
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 2, limit: 1)) {
            try await one.createHardLink(path: "/alias", target: "/dangling")
        }
    }

    @Test
    func `append charges every hard link while replacement charges one entry`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/file", data: Data("ab".utf8), append: false)
        try await memory.createHardLink(path: "/alias", target: "/file")
        let limited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 5))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 6, limit: 5)) {
            try await limited.writeFile(path: "/alias", data: Data("c".utf8), append: true)
        }
        #expect(try await memory.readFile(path: "/file") == Data("ab".utf8))
        try await limited.writeFile(path: "/alias", data: Data("xyz".utf8), append: false)
        #expect(try await memory.readFile(path: "/file") == Data("ab".utf8))
        #expect(try await memory.readFile(path: "/alias") == Data("xyz".utf8))
        try await limited.remove(path: "/file", recursive: false)
        try await limited.writeFile(path: "/alias", data: Data("12".utf8), append: true)
        #expect(try await memory.stat(path: "/alias").size == 5)
    }

    @Test
    func `identity distinguishes unrelated files with matching metadata sizes`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/file", data: Data("ab".utf8), append: false)
        try await memory.writeFile(path: "/unrelated", data: Data("ab".utf8), append: false)
        let mounted = MountedFileSystem(mounts: [.init(mountPoint: "/", fileSystem: memory)])
        let limited = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 5))
        try await limited.writeFile(path: "/file", data: Data("c".utf8), append: true)
        #expect(try await memory.readFile(path: "/unrelated") == Data("ab".utf8))
    }

    @Test
    func `a known single link permits exact appends through metadata only wrappers`() async throws {
        let memory = InMemoryFileSystem()
        for index in 0..<20 {
            try await memory.writeFile(path: WorkspacePath(normalizing: "/f\(index)"), data: Data(), append: false)
        }
        let backend = RegressionBackend(memory: memory, denyChildStats: true, omitIdentities: true)
        let limited = LimitedFileSystem(base: backend, limits: .init(maxTotalBytes: 5))
        try await limited.writeFile(path: "/f0", data: Data(count: 5), append: true)
        #expect(try await memory.stat(path: "/f0").size == 5)
        #expect(try await memory.stat(path: "/f1").size == 0)
    }

    @Test
    func `appending through distinct backends sharing an entry charges every exposed path`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/file", data: Data(count: 2), append: false)
        let mounted = MountedFileSystem(mounts: [
            .init(mountPoint: "/a", fileSystem: RegressionBackend(memory: memory)),
            .init(mountPoint: "/b", fileSystem: RegressionBackend(memory: memory)),
        ])
        let identity = try await memory.stat(path: "/file").identity
        #expect(identity != nil)
        #expect(try await mounted.stat(path: "/a/file").identity == identity)
        #expect(try await mounted.stat(path: "/b/file").identity == identity)
        #expect(try await mounted.listDirectory(path: "/a").first?.info.identity == identity)
        #expect(try await mounted.listDirectory(path: "/b").first?.info.identity == identity)
        let limited = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 5))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 6, limit: 5)) {
            try await limited.writeFile(path: "/a/file", data: Data(count: 1), append: true)
        }
        #expect(try await memory.stat(path: "/file").size == 2)
    }

    @Test
    func `hard link metadata tracks copies replacements moves and recursive unlinking`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/dir", recursive: false)
        try await memory.writeFile(path: "/file", data: Data(count: 2), append: false)
        try await memory.createHardLink(path: "/dir/alias", target: "/file")
        try await memory.createHardLink(path: "/dir/second", target: "/file")
        let original = try await memory.stat(path: "/file")
        #expect(original.identity != nil)
        #expect(original.linkCount == 3)
        #expect(try await memory.stat(path: "/dir/alias").identity == original.identity)
        try await memory.copy(from: "/dir", to: "/copy", recursive: true)
        #expect(try await memory.stat(path: "/copy/alias").identity != original.identity)
        #expect(try await memory.stat(path: "/copy/alias").linkCount == 1)
        try await memory.move(from: "/file", to: "/renamed")
        #expect(try await memory.stat(path: "/renamed").identity == original.identity)
        try await memory.remove(path: "/dir", recursive: true)
        #expect(try await memory.stat(path: "/renamed").linkCount == 1)
        try await memory.createHardLink(path: "/alias", target: "/renamed")
        try await memory.writeFile(path: "/alias", data: Data(count: 3), append: false)
        #expect(try await memory.stat(path: "/alias").identity != original.identity)
        #expect(try await memory.stat(path: "/renamed").linkCount == 1)
        let other = InMemoryFileSystem()
        try await other.writeFile(path: "/file", data: Data(count: 2), append: false)
        #expect(try await other.stat(path: "/file").identity != original.identity)
        await memory.reset()
        try await memory.writeFile(path: "/file", data: Data(count: 2), append: false)
        #expect(try await memory.stat(path: "/file").identity != original.identity)
    }

    @Test
    func `FileInfo decodes older metadata without identity or link count`() throws {
        let legacy = Data(#"{"path":"/file","kind":"file","size":4,"permissions":{"rawValue":420}}"#.utf8)
        let info = try JSONDecoder().decode(FileInfo.self, from: legacy)
        #expect(info.path == "/file")
        #expect(info.size == 4)
        #expect(info.identity == nil)
        #expect(info.linkCount == nil)
    }

    @Test
    func `preexisting disk hard links charge every path and replacement breaks sharing`() async throws {
        let root = try TestSupport.temporaryDirectory("LimitedDiskAliases")
        defer { TestSupport.remove(root) }
        let disk = try LocalFileSystem(root: root)
        try await disk.writeFile(path: "/file", data: Data("ab".utf8), append: false)
        try await disk.createHardLink(path: "/alias", target: "/file")
        let limited = LimitedFileSystem(base: disk, limits: .init(maxTotalBytes: 5))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 6, limit: 5)) {
            try await limited.writeFile(path: "/alias", data: Data("c".utf8), append: true)
        }
        #expect(try await disk.readFile(path: "/file") == Data("ab".utf8))
        try await limited.writeFile(path: "/alias", data: Data("abc".utf8), append: false)
        #expect(try await disk.stat(path: "/file").size == 2)
        #expect(try await disk.readFile(path: "/alias") == Data("abc".utf8))
        #expect(try await disk.stat(path: "/alias").identity != disk.stat(path: "/file").identity)
    }

    @Test
    func `limit preflight uses metadata without reading file content`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/large", data: Data("1234".utf8), append: false)
        let backend = RegressionBackend(memory: memory, denyReads: true, denyChildStats: true)
        let limited = LimitedFileSystem(base: backend, limits: .init(maxTotalBytes: 8, maxEntryCount: 3))
        try await limited.createDirectory(path: "/dir", recursive: false)
        try await limited.copy(from: "/large", to: "/dir/copy", recursive: false)
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 9, limit: 8)) {
            try await limited.writeFile(path: "/new", data: Data([1]), append: false)
        }
        try await limited.move(from: "/dir/copy", to: "/copy")
        try await limited.remove(path: "/dir", recursive: true)
        try await limited.writeFile(path: "/large", data: Data([1]), append: false)
        #expect(try await memory.readFile(path: "/copy") == Data("1234".utf8))
    }

    @Test
    func `limited moves preserve existing destination errors for overlapping paths`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/dir", recursive: false)
        try await memory.writeFile(path: "/dir/file", data: Data(count: 4), append: false)
        let limited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 8, maxEntryCount: 3))
        do {
            try await limited.move(from: "/dir/file", to: "/dir")
            Issue.record("expected existing destination rejection")
        } catch { #expect((error as NSError).code == Int(EEXIST)) }
        #expect(try await memory.stat(path: "/dir/file").size == 4)
        try await limited.move(from: "/dir/file", to: "/after")
        #expect(try await memory.stat(path: "/after").size == 4)
    }

    @Test
    func `dangling link through a symlinked parent charges the created target entry`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/dir", recursive: false)
        try await memory.createSymlink(path: "/dir/dangle", target: "/target")
        try await memory.createSymlink(path: "/link", target: "/dir")
        let limited = LimitedFileSystem(base: memory, limits: .init(maxEntryCount: 3))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 4, limit: 3)) {
            try await limited.writeFile(path: "/link/dangle", data: Data([1]), append: false)
        }
        #expect(!(await memory.exists(path: "/target")))
    }

    @Test
    func `mounted symlink writes are charged in the backend namespace`() async throws {
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/data", data: Data(count: 1000), append: false)
        let inner = InMemoryFileSystem()
        try await inner.createSymlink(path: "/link", target: "/data")
        let mounted = MountedFileSystem(base: base, mounts: [.init(mountPoint: "/m", fileSystem: inner)])
        let limited = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 1100))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 1900, limit: 1100)) {
            try await limited.writeFile(path: "/m/link", data: Data(count: 900), append: false)
        }
        #expect(!(await inner.exists(path: "/data")))
        #expect(try await base.stat(path: "/data").size == 1000)

        try await inner.createDirectory(path: "/dir", recursive: false)
        try await inner.createSymlink(path: "/parent", target: "/dir")
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 1900, limit: 1100)) {
            try await limited.writeFile(path: "/m/parent/new", data: Data(count: 900), append: false)
        }
        #expect(!(await inner.exists(path: "/dir/new")))
    }

    @Test
    func `over quota mutations may reduce or preserve usage but cannot grow it`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/large", data: Data(count: 10), append: false)
        try await memory.writeFile(path: "/small", data: Data(count: 2), append: false)
        let limited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 5, maxEntryCount: 0))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 13, limit: 5)) {
            try await limited.writeFile(path: "/large", data: Data(count: 1), append: true)
        }
        try await limited.move(from: "/small", to: "/renamed")
        try await limited.remove(path: "/renamed", recursive: false)
        #expect(try await memory.stat(path: "/large").size == 10)
        try await limited.writeFile(path: "/large", data: Data(count: 6), append: false)
        try await limited.remove(path: "/large", recursive: false)
        #expect(try await memory.listDirectory(path: "/").isEmpty)
    }

    @Test
    func `replacement accounting respects final symlink write behavior`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/file", data: Data("ab".utf8), append: false)
        try await memory.createSymlink(path: "/link", target: "/file")
        let memoryLimited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 3))
        try await memoryLimited.writeFile(path: "/link", data: Data("xyz".utf8), append: false)
        #expect(try await memory.readFile(path: "/file") == Data("xyz".utf8))
        #expect(try await memory.stat(path: "/link").kind == .symlink)

        let root = try TestSupport.temporaryDirectory("LimitedSymlinkReplacement")
        defer { TestSupport.remove(root) }
        let disk = try LocalFileSystem(root: root)
        try await disk.writeFile(path: "/file", data: Data("ab".utf8), append: false)
        try await disk.createSymlink(path: "/link", target: "file")
        let diskLimited = LimitedFileSystem(base: disk, limits: .init(maxTotalBytes: 3))
        try await diskLimited.writeFile(path: "/link", data: Data("xyz".utf8), append: false)
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 4, limit: 3)) {
            try await diskLimited.writeFile(path: "/link", data: Data("wxyz".utf8), append: false)
        }
        #expect(try await disk.stat(path: "/link").kind == .symlink)
        #expect(try await disk.readFile(path: "/file") == Data("xyz".utf8))
    }

    @Test
    func `write accounting follows symlink parents and counts created disk parents`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/dir", recursive: false)
        try await memory.writeFile(path: "/dir/file", data: Data("1234".utf8), append: false)
        try await memory.createSymlink(path: "/link", target: "/dir")
        let limited = LimitedFileSystem(base: memory, limits: .init(maxTotalBytes: 5))
        try await limited.writeFile(path: "/link/file", data: Data("abcde".utf8), append: false)
        #expect(try await memory.readFile(path: "/dir/file") == Data("abcde".utf8))
        let root = try TestSupport.temporaryDirectory("LimitedDiskParents")
        defer { TestSupport.remove(root) }
        let disk = try LocalFileSystem(root: root)
        let entries = LimitedFileSystem(base: disk, limits: .init(maxEntryCount: 2))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 3, limit: 2)) {
            try await entries.writeFile(path: "/one/two/file", data: Data(), append: false)
        }
        #expect(!(await disk.exists(path: "/one")))
    }

    @Test(arguments: [false, true])
    func `writing a directory preserves its children and throws EISDIR`(append: Bool) async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/dir", recursive: false)
        try await memory.writeFile(path: "/dir/important", data: Data("keep".utf8), append: false)
        try await memory.createSymlink(path: "/link", target: "/dir")
        for path: WorkspacePath in ["/dir", "/link"] {
            do {
                try await memory.writeFile(path: path, data: Data("oops".utf8), append: append)
                Issue.record("expected EISDIR")
            } catch {
                #expect((error as NSError).domain == NSPOSIXErrorDomain)
                #expect((error as NSError).code == Int(EISDIR))
            }
        }
        #expect(try await memory.readFile(path: "/dir/important") == Data("keep".utf8))
        #expect(try await memory.stat(path: "/dir").kind == .directory)
    }

    @Test
    func `dangling links exist in memory glob snapshots and checkpoints`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createSymlink(path: "/dangling", target: "/missing")
        #expect(await memory.exists(path: "/dangling"))
        #expect(try await memory.glob(pattern: "/dangling", currentDirectory: "/") == ["/dangling"])
        #expect(!(await memory.exists(path: "/dangling/child")))
        let snapshot = try await Snapshot.capture(from: memory)
        let restored = InMemoryFileSystem()
        try await Snapshot.restore(snapshot, to: restored)
        #expect(try await restored.readSymlink(path: "/dangling") == "/missing")
        let workspace = Workspace(fileSystem: memory)
        let checkpoint = try await workspace.createCheckpoint()
        #expect(await workspace.exists("/dangling", at: .checkpoint(checkpoint.id)))
    }

    @Test
    func `mounted empty directories succeed and backend errors survive`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.createDirectory(path: "/empty", recursive: false)
        try await memory.writeFile(path: "/file", data: Data(), append: false)
        let mounted = MountedFileSystem(base: memory)
        #expect(try await mounted.listDirectory(path: "/empty").isEmpty)
        for (path, code): (WorkspacePath, Int32) in [("/file", ENOTDIR), ("/missing", ENOENT)] {
            do {
                _ = try await mounted.listDirectory(path: path)
                Issue.record("expected backend error")
            } catch {
                #expect((error as NSError).domain == NSPOSIXErrorDomain)
                #expect((error as NSError).code == Int(code))
            }
        }
        let shadowedFile = MountedFileSystem(base: memory, mounts: [
            .init(mountPoint: "/file/inner", fileSystem: InMemoryFileSystem())
        ])
        #expect(try await shadowedFile.stat(path: "/file").kind == .file)
        #expect(await shadowedFile.exists(path: "/file"))
        let captured = try await Snapshot.capture(from: shadowedFile)
        let restored = InMemoryFileSystem()
        try await Snapshot.restore(captured, to: restored)
        #expect(try await restored.stat(path: "/file").kind == .file)
        do {
            _ = try await shadowedFile.listDirectory(path: "/file")
            Issue.record("expected ENOTDIR even with a nested mount")
        } catch { #expect((error as NSError).code == Int(ENOTDIR)) }
        let denied = MountedFileSystem(base: RegressionBackend(memory: memory, listError: EACCES), mounts: [
            .init(mountPoint: "/empty/inner", fileSystem: InMemoryFileSystem()),
            .init(mountPoint: "/missing/inner", fileSystem: InMemoryFileSystem()),
        ])
        for path: WorkspacePath in ["/empty", "/missing"] {
            do {
                _ = try await denied.listDirectory(path: path)
                Issue.record("expected permission denial")
            } catch { #expect((error as NSError).code == Int(EACCES)) }
        }
    }

    @Test
    func `missing disk directories can supply synthetic mount parents`() async throws {
        let root = try TestSupport.temporaryDirectory("SyntheticMountParent")
        defer { TestSupport.remove(root) }
        let disk = try LocalFileSystem(root: root)
        let mounted = MountedFileSystem(mounts: [
            .init(mountPoint: "/", fileSystem: disk),
            .init(mountPoint: "/parent/deep", fileSystem: InMemoryFileSystem()),
        ])
        #expect(try await mounted.listDirectory(path: "/parent").map(\.name) == ["deep"])
        #expect(try await mounted.stat(path: "/parent").kind == .directory)
    }

    @Test
    func `nested mounts shadow entries and appear in glob and snapshot traversal`() async throws {
        let root = InMemoryFileSystem()
        try await root.writeFile(path: "/nested", data: Data("shadowed".utf8), append: false)
        let nested = InMemoryFileSystem()
        try await nested.writeFile(path: "/file", data: Data("visible".utf8), append: false)
        let mounted = MountedFileSystem(mounts: [
            .init(mountPoint: "/", fileSystem: root),
            .init(mountPoint: "/nested", fileSystem: nested),
            .init(mountPoint: "/parent/deep", fileSystem: nested),
        ])
        let entries = try await mounted.listDirectory(path: "/")
        #expect(entries.map(\.name) == ["nested", "parent"])
        #expect(entries.allSatisfy { $0.info.kind == .directory })
        #expect(try await mounted.listDirectory(path: "/parent").map(\.name) == ["deep"])
        #expect(try await mounted.glob(pattern: "/**/file", currentDirectory: "/") == ["/nested/file", "/parent/deep/file"])
        let snapshot = try await Snapshot.capture(from: mounted)
        let restored = InMemoryFileSystem()
        try await Snapshot.restore(snapshot, to: restored)
        #expect(try await restored.readFile(path: "/nested/file") == Data("visible".utf8))
        #expect(try await restored.readFile(path: "/parent/deep/file") == Data("visible".utf8))
    }
}

// A real memory backend whose content-read boundary is unavailable, or whose directory
// listing is denied. This exercises metadata accounting and propagation, not a fake quota.
private final class RegressionBackend: FileSystem, Sendable {
    let memory: InMemoryFileSystem
    let denyReads: Bool
    let listError: Int32?
    let writeLatch: RegressionMutationLatch?
    let denyChildStats: Bool
    let omitIdentities: Bool

    init(
        memory: InMemoryFileSystem, denyReads: Bool = false,
        listError: Int32? = nil, writeLatch: RegressionMutationLatch? = nil,
        denyChildStats: Bool = false, omitIdentities: Bool = false
    ) {
        self.memory = memory
        self.denyReads = denyReads
        self.listError = listError
        self.writeLatch = writeLatch
        self.denyChildStats = denyChildStats
        self.omitIdentities = omitIdentities
    }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        if denyChildStats, !path.isRoot { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        var info = try await memory.stat(path: path)
        if omitIdentities { info.identity = nil }
        return info
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        if let listError { throw NSError(domain: NSPOSIXErrorDomain, code: Int(listError)) }
        return try await memory.listDirectory(path: path).map { entry in
            var entry = entry
            if omitIdentities { entry.info.identity = nil }
            return entry
        }
    }
    func readFile(path: WorkspacePath) async throws -> Data {
        if denyReads { throw WorkspaceError.accessDenied(operation: "readFile", message: "content reads unavailable") }
        return try await memory.readFile(path: path)
    }
    func exists(path: WorkspacePath) async -> Bool { await memory.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await memory.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if path == "/first" { await writeLatch?.enter() }
        try await memory.writeFile(path: path, data: data, append: append)
    }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await memory.createDirectory(path: path, recursive: recursive)
    }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await memory.remove(path: path, recursive: recursive) }
    func move(from: WorkspacePath, to: WorkspacePath) async throws { try await memory.move(from: from, to: to) }
    func copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool) async throws {
        try await memory.copy(from: from, to: to, recursive: recursive)
    }
    func createSymlink(path: WorkspacePath, target: String) async throws { try await memory.createSymlink(path: path, target: target) }
    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws { try await memory.createHardLink(path: path, target: target) }
    func readSymlink(path: WorkspacePath) async throws -> String { try await memory.readSymlink(path: path) }
}

private actor RegressionMutationLatch {
    private var entered = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?
    private var writer: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        observer?.resume()
        observer = nil
        if !released { await withCheckedContinuation { writer = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observer = $0 } }
    }
    func release() {
        released = true
        writer?.resume()
        writer = nil
    }
}
