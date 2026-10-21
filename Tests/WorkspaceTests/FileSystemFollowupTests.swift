import Foundation
import Testing
@testable import Workspace

@Suite("Filesystem follow-up contracts")
struct FileSystemFollowupTests {
    @Test(arguments: [false, true])
    func `writes through dangling links resolve relative targets from physical parents`(localBackend: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("PhysicalDanglingWrite")
        defer { TestSupport.remove(root) }
        let base: any FileSystem = localBackend ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        try await preparePhysicalDanglingLink(on: base)
        try await base.writeFile(path: "/a/link/dangle", data: Data(count: 120), append: false)
        #expect(try await base.readFile(path: "/a/link/dangle") == Data(count: 120))
        #expect(try await base.readFile(path: "/x/t") == Data(count: 120))
        #expect(try await base.readFile(path: "/a/t") == Data(count: 100))
    }

    @Test(arguments: ["local", "memory", "authorized local"])
    func `quota charges dangling targets beneath physical parents`(backend: String) async throws {
        let root = try TestSupport.temporaryDirectory("PhysicalDanglingQuota")
        defer { TestSupport.remove(root) }
        let base: any FileSystem = backend == "memory" ? InMemoryFileSystem() : try LocalFileSystem(root: root)
        try await preparePhysicalDanglingLink(on: base)
        let decorated: any FileSystem = backend == "authorized local"
            ? AuthorizedFileSystem(base: base, authorizer: PermissionAuthorizer { _ in .allow }) : base
        let limited = LimitedFileSystem(base: decorated, limits: .init(maxTotalBytes: 150))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 220, limit: 150)) {
            try await limited.writeFile(path: "/a/link/dangle", data: Data(count: 120), append: false)
        }
        #expect(!(await base.exists(path: "/x/t")))
        #expect(try await base.readFile(path: "/a/t") == Data(count: 100))
    }

    static var absoluteTargetBackends: [String] {
        var backends = ["local", "limited", "sandbox", "mounted", "limited mounted"]
        #if os(macOS)
        backends.append("security scoped")
        #endif
        return backends
    }

    @Test(arguments: absoluteTargetBackends)
    func `absolute host dangling targets retain backend namespaces through decorators`(backend: String) async throws {
        let root = try TestSupport.temporaryDirectory("AbsoluteDanglingQuota")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createSymlink(path: "/abs", target: root.resolvingSymlinksInPath().appendingPathComponent("target").path)
        let mounted = MountedFileSystem(mounts: [.init(mountPoint: "/mounted", fileSystem: local)])
        let base: any FileSystem
        switch backend {
        case "limited": base = LimitedFileSystem(base: local, limits: .init())
        case "sandbox": base = try SandboxFileSystem(root: .url(root))
        case "mounted": base = mounted
        case "limited mounted": base = LimitedFileSystem(base: mounted, limits: .init())
        #if os(macOS)
        case "security scoped": base = try SecurityScopedFileSystem(url: root)
        #endif
        default: base = local
        }
        let mountedBackend = backend.contains("mounted")
        let limited = LimitedFileSystem(base: base, limits: .init(maxEntryCount: mountedBackend ? 3 : 2))
        try await limited.writeFile(path: mountedBackend ? "/mounted/abs" : "/abs", data: Data([1]), append: false)
        #expect(try await local.stat(path: "/abs").kind == .symlink)
        #expect(try await local.readFile(path: "/target") == Data([1]))
        #expect(try await local.listDirectory(path: "/").map(\.name) == ["abs", "target"])
    }

    @Test
    func `absolute dangling targets count missing parents without creating them during preflight`() async throws {
        let root = try TestSupport.temporaryDirectory("AbsoluteDanglingParents")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createSymlink(path: "/abs", target: root.resolvingSymlinksInPath().appendingPathComponent("new/target").path)
        let tooSmall = LimitedFileSystem(base: local, limits: .init(maxEntryCount: 2))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 3, limit: 2)) {
            try await tooSmall.writeFile(path: "/abs", data: Data([1]), append: false)
        }
        #expect(!(await local.exists(path: "/new")))
        let enough = LimitedFileSystem(base: local, limits: .init(maxEntryCount: 3))
        try await enough.writeFile(path: "/abs", data: Data([1]), append: false)
        #expect(try await local.readFile(path: "/new/target") == Data([1]))
        #expect(try await local.stat(path: "/abs").kind == .symlink)
    }

    @Test
    func `local quota permits appending among many equal size files`() async throws {
        let root = try TestSupport.temporaryDirectory("LocalQuotaPrecision")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        for index in 0..<20 {
            try await local.createFile(path: .root.appending("file-\(index)"), data: Data())
        }
        let limited = LimitedFileSystem(base: local, limits: .init(maxTotalBytes: 1))
        try await limited.writeFile(path: "/file-0", data: Data([1]), append: true)
        #expect(try await local.readFile(path: "/file-0") == Data([1]))
        #expect(try await local.stat(path: "/file-1").size == 0)
    }

    @Test
    func `local metadata identifies hard links without treating directory links as aliases`() async throws {
        let root = try TestSupport.temporaryDirectory("LocalMetadata")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/dir/child", recursive: true)
        try await local.createFile(path: "/file", data: Data("ab".utf8))
        try await local.createHardLink(path: "/alias", target: "/file")
        try await local.createSymlink(path: "/link", target: "file")
        let original = try await local.stat(path: "/file")
        let identity = try #require(original.identity)
        #expect(original.linkCount == 2)
        #expect(try await local.stat(path: "/alias").identity == identity)
        #expect(try await local.stat(path: "/link").identity != identity)
        #expect(try await local.stat(path: "/link").linkCount == 1)
        #expect(try await local.stat(path: "/dir").linkCount == nil)
        for entry in try await local.listDirectory(path: "/") {
            let info = try await local.stat(path: entry.info.path)
            #expect(entry.info.identity == info.identity)
            #expect(entry.info.linkCount == info.linkCount)
        }
        let limited = LimitedFileSystem(base: local, limits: .init(maxTotalBytes: 6))
        try await limited.writeFile(path: "/alias", data: Data("c".utf8), append: true)
        #expect(try await local.readFile(path: "/file") == Data("abc".utf8))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 8, limit: 6)) {
            try await limited.writeFile(path: "/file", data: Data("d".utf8), append: true)
        }
        #expect(try await local.readFile(path: "/alias") == Data("abc".utf8))
    }

    @Test
    func `separate local instances mounted twice account for the same inode`() async throws {
        let root = try TestSupport.temporaryDirectory("LocalMountedAliases")
        defer { TestSupport.remove(root) }
        let first = try LocalFileSystem(root: root)
        let second = try LocalFileSystem(root: root)
        for index in 0..<10 {
            try await first.createFile(path: .root.appending("file-\(index)"), data: Data("ab".utf8))
        }
        let mounted = MountedFileSystem(mounts: [
            .init(mountPoint: "/first", fileSystem: first),
            .init(mountPoint: "/second", fileSystem: second),
        ])
        let identity = try #require(try await mounted.stat(path: "/first/file-0").identity)
        #expect(try await mounted.stat(path: "/second/file-0").identity == identity)
        #expect(try await mounted.stat(path: "/first/file-0").linkCount == 1)
        let limited = LimitedFileSystem(base: mounted, limits: .init(maxTotalBytes: 42))
        try await limited.writeFile(path: "/first/file-0", data: Data("c".utf8), append: true)
        #expect(try await mounted.readFile(path: "/second/file-0") == Data("abc".utf8))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 44, limit: 42)) {
            try await limited.writeFile(path: "/second/file-0", data: Data("d".utf8), append: true)
        }
        #expect(try await first.readFile(path: "/file-0") == Data("abc".utf8))
    }

    @Test
    func `local replacement writes follow final symlinks and charge dangling targets`() async throws {
        let root = try TestSupport.temporaryDirectory("LocalLinkReplacement")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createFile(path: "/file", data: Data("original".utf8))
        try await local.createSymlink(path: "/link", target: "file")
        #expect(try await local.readFile(path: "/link") == Data("original".utf8))
        try await local.writeFile(path: "/link", data: Data("replacement".utf8), append: false)
        #expect(try await local.stat(path: "/link").kind == .symlink)
        #expect(try await local.readSymlink(path: "/link") == "file")
        #expect(try await local.readFile(path: "/file") == Data("replacement".utf8))

        try await local.remove(path: "/link", recursive: false)
        try await local.remove(path: "/file", recursive: false)
        try await local.createSymlink(path: "/dangling", target: "missing")
        let oneEntry = LimitedFileSystem(base: local, limits: .init(maxEntryCount: 1))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: 2, limit: 1)) {
            try await oneEntry.writeFile(path: "/dangling", data: Data("new".utf8), append: false)
        }
        #expect(!(await local.exists(path: "/missing")))
        let twoEntries = LimitedFileSystem(base: local, limits: .init(maxTotalBytes: 3, maxEntryCount: 2))
        try await twoEntries.writeFile(path: "/dangling", data: Data("new".utf8), append: false)
        #expect(try await local.stat(path: "/dangling").kind == .symlink)
        #expect(try await local.readSymlink(path: "/dangling") == "missing")
        #expect(try await local.readFile(path: "/missing") == Data("new".utf8))
    }

    @Test(arguments: [false, true])
    func `overlay dangling links survive snapshots and persisted checkpoint restoration`(upperLayer: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("OverlayDangling")
        let history = try TestSupport.temporaryDirectory("OverlayDanglingHistory")
        defer { TestSupport.remove(root); TestSupport.remove(history) }
        let local = try LocalFileSystem(root: root)
        let overlay = OverlayFileSystem(over: local)
        let layer: any FileSystem = upperLayer ? overlay : local
        try await layer.createSymlink(path: "/dangling", target: "missing")
        #expect(await overlay.exists(path: "/dangling"))
        #expect(try await overlay.glob(pattern: "/dangling", currentDirectory: "/") == ["/dangling"])
        let id = UUID()
        let workspace = Workspace(workspaceID: id, fileSystem: overlay, persistence: .directory(history))
        let checkpoint = try await workspace.createCheckpoint()
        let snapshot = try await Snapshot.capture(from: overlay)
        try await overlay.remove(path: "/dangling", recursive: false)
        #expect(!(await overlay.exists(path: "/dangling")))
        try await Snapshot.restore(snapshot, to: overlay)
        #expect(try await overlay.readSymlink(path: "/dangling") == "missing")

        try await overlay.remove(path: "/dangling", recursive: false)
        let reopened = Workspace(workspaceID: id, fileSystem: overlay, persistence: .directory(history))
        #expect(await reopened.exists("/dangling", at: .checkpoint(checkpoint.id)))
        _ = try await reopened.restore(to: checkpoint)
        #expect(try await overlay.readSymlink(path: "/dangling") == "missing")
        #expect(!(await overlay.exists(path: "/missing")))
    }

    @Test
    func `all backends use lstat existence through symlinked parents`() async throws {
        let root = try TestSupport.temporaryDirectory("BackendLinkExistence")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let memory = InMemoryFileSystem()
        for base: any FileSystem in [local, memory] {
            try await base.createDirectory(path: "/dir", recursive: false)
            try await base.createSymlink(path: "/dir/dangling", target: "../missing")
            try await base.createSymlink(path: "/parent", target: "dir")
            try await base.createSymlink(path: "/loop", target: "loop")
        }
        var backends: [any FileSystem] = [
            local, memory, OverlayFileSystem(over: local),
            try SandboxFileSystem(root: .url(root)),
            LimitedFileSystem(base: local, limits: .init()),
            MountedFileSystem(base: local),
            AuthorizedFileSystem(base: local, authorizer: PermissionAuthorizer { _ in .allow }),
        ]
        #if os(macOS)
        backends.append(try SecurityScopedFileSystem(url: root))
        #endif
        for backend in backends {
            #expect(await backend.exists(path: "/parent/dangling"))
            #expect(try await backend.glob(pattern: "/parent/dangling", currentDirectory: "/") == ["/parent/dangling"])
            #expect(await backend.exists(path: "/loop"))
            #expect(!(await backend.exists(path: "/parent/dangling/child")))
            #expect(!(await backend.exists(path: "/missing")))
        }
    }

    @Test
    func `disk adapters preserve identity link count and features`() async throws {
        let root = try TestSupport.temporaryDirectory("AdapterMetadata")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createFile(path: "/file", data: Data([1]))
        try await local.createHardLink(path: "/alias", target: "/file")
        let identity = try #require(try await local.stat(path: "/file").identity)
        var adapters: [any FileSystem] = [try SandboxFileSystem(root: .url(root))]
        #if os(macOS)
        adapters.append(try SecurityScopedFileSystem(url: root, mode: .readOnly))
        adapters.append(try SecurityScopedFileSystem(url: root, mode: .readWrite))
        #endif
        for adapter in adapters {
            #expect(await adapter.capabilities() == local.capabilities())
            #expect(try await adapter.stat(path: "/file").identity == identity)
            #expect(try await adapter.stat(path: "/file").linkCount == 2)
            for entry in try await adapter.listDirectory(path: "/") {
                #expect(entry.info.identity == identity)
                #expect(entry.info.linkCount == 2)
            }
        }
    }
}

private func preparePhysicalDanglingLink(on base: any FileSystem) async throws {
    try await base.createDirectory(path: "/a", recursive: false)
    try await base.createDirectory(path: "/x/y", recursive: true)
    try await base.createSymlink(path: "/a/link", target: "../x/y")
    try await base.createSymlink(path: "/x/y/dangle", target: "../t")
    try await base.createFile(path: "/a/t", data: Data(count: 100))
}
