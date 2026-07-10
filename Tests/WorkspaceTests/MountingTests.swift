import Foundation
import Testing
@testable import Workspace

private enum MountingTestSupport {
    static func makeTempDirectory(prefix: String = "MountingTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func data(_ value: String) -> Data {
        Data(value.utf8)
    }
}

@Suite("Mounting")
struct MountingTests {
    @Test
    func `multiple isolated mounts can share a memory workspace`() async throws {
        let workspaceA = InMemoryFileSystem()

        let workspaceB = InMemoryFileSystem()

        let memory = InMemoryFileSystem()

        let mountable = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/workspace-a", fileSystem: workspaceA),
                .init(mountPoint: "/workspace-b", fileSystem: workspaceB),
                .init(mountPoint: "/memory", fileSystem: memory),
            ]
        )

        let workspace = Workspace(fileSystem: mountable)
        try await workspace.writeText("/memory/shared.txt", "memo")
        try await workspace.copy(from: "/memory/shared.txt", to: "/workspace-a/note.txt")

        #expect(try await workspace.readText("/memory/shared.txt") == "memo")
        #expect(try await workspace.readText("/workspace-a/note.txt") == "memo")
        #expect(!(await workspace.exists("/workspace-b/note.txt")))
    }

    @Test
    func `preview shows mounted changes without mutating`() async throws {
        let memory = InMemoryFileSystem()

        let workspaceRoot = InMemoryFileSystem()

        let mountable = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/workspace", fileSystem: workspaceRoot),
                .init(mountPoint: "/memory", fileSystem: memory),
            ]
        )
        try await memory.writeFile(path: "/shared.txt", data: Data("memo".utf8), append: false)

        let workspace = Workspace(fileSystem: mountable)
        let result = try await workspace.preview(
            [
                .copy(from: "/memory/shared.txt", to: "/workspace/shared.txt"),
                .appendText("/memory/shared.txt", "!"),
            ]
        )

        #expect(result.touchedPaths.contains("/workspace/shared.txt"))
        #expect(result.touchedPaths.contains("/memory/shared.txt"))
        #expect(!(await workspace.exists("/workspace/shared.txt")))
        #expect(try await workspace.readText("/memory/shared.txt") == "memo")
    }

    @Test
    func `tree maxDepth stops recursion at nested directories`() async throws {
        let filesystem = InMemoryFileSystem()
        try await filesystem.createDirectory(path: "/workspace/src/nested", recursive: true)
        try await filesystem.writeFile(path: "/workspace/src/nested/deep.txt", data: Data("deep".utf8), append: false)

        let workspace = Workspace(fileSystem: filesystem)
        let tree = try await workspace.tree(at: "/workspace", maxDepth: 1)

        #expect(tree.children?.count == 1)
        let src = try #require(tree.children?.first)
        #expect(src.path == "/workspace/src")
        #expect(src.children == nil)
    }

    @Test
    func `copy and move operations work across mounted roots`() async throws {
        let docs = InMemoryFileSystem()

        let workspaceFiles = InMemoryFileSystem()

        let mountable = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/docs", fileSystem: docs),
                .init(mountPoint: "/workspace", fileSystem: workspaceFiles),
            ]
        )
        try await docs.writeFile(path: "/guide.txt", data: Data("guide".utf8), append: false)

        let workspace = Workspace(fileSystem: mountable)
        try await workspace.copy(from: "/docs/guide.txt", to: "/workspace/guide.txt")
        try await workspace.move(from: "/workspace/guide.txt", to: "/workspace/guide-copy.txt")

        #expect(!(await workspace.exists("/workspace/guide.txt")))
        #expect(try await workspace.readText("/workspace/guide-copy.txt") == "guide")
        #expect(try await workspace.readText("/docs/guide.txt") == "guide")
    }

    @Test
    func `mountable filesystem merges base entries with mounted directories`() async throws {
        let base = InMemoryFileSystem()
        try await base.createDirectory(path: "/docs", recursive: true)
        try await base.writeFile(path: "/docs/local.txt", data: MountingTestSupport.data("local"), append: false)
        try await base.writeFile(path: "/base.txt", data: MountingTestSupport.data("base"), append: false)

        let mountedDocs = InMemoryFileSystem()
        try await mountedDocs.writeFile(path: "/guide.txt", data: MountingTestSupport.data("guide"), append: false)

        let filesystem = MountedFileSystem(
            base: base,
            mounts: [.init(mountPoint: "/docs/external", fileSystem: mountedDocs)]
        )

        let docsInfo = try await filesystem.stat(path: "/docs")
        #expect(docsInfo.kind == .directory)
        #expect(await filesystem.exists(path: "/docs"))
        #expect(try await filesystem.readFile(path: "/base.txt") == MountingTestSupport.data("base"))

        let docsEntries = try await filesystem.listDirectory(path: "/docs")
        #expect(docsEntries.map(\.name) == ["external", "local.txt"])

        let mountedEntries = try await filesystem.listDirectory(path: "/docs/external")
        #expect(mountedEntries.map(\.name) == ["guide.txt"])

        try await filesystem.writeFile(path: "/docs/external/new.txt", data: MountingTestSupport.data("new"), append: false)
        try await filesystem.createDirectory(path: "/docs/external/sub", recursive: true)
        try await filesystem.createSymlink(path: "/docs/external/link.txt", target: "guide.txt")
        try await filesystem.createHardLink(path: "/docs/external/hard.txt", target: "/docs/external/guide.txt")
        try await filesystem.setPermissions(path: "/docs/external/guide.txt", permissions: POSIXPermissions(0o600))

        #expect(try await filesystem.readSymlink(path: "/docs/external/link.txt") == "guide.txt")
        #expect(try await filesystem.resolveRealPath(path: "/docs/external/link.txt") == "/docs/external/guide.txt")
        #expect(try await mountedDocs.readFile(path: "/new.txt") == MountingTestSupport.data("new"))
        #expect(try await mountedDocs.readFile(path: "/hard.txt") == MountingTestSupport.data("guide"))
        #expect(try await mountedDocs.stat(path: "/guide.txt").permissions == POSIXPermissions(0o600))

        let globbed = try await filesystem.glob(pattern: "/docs/*.txt", currentDirectory: "/")
        #expect(globbed.contains("/docs/local.txt"))
        #expect(!globbed.contains("/docs/external/guide.txt"))

        let nested = try await filesystem.glob(pattern: "/docs/**", currentDirectory: "/")
        #expect(nested.contains("/docs/external/guide.txt"))

        try await filesystem.remove(path: "/docs/external/new.txt", recursive: false)
        #expect(!(await mountedDocs.exists(path: "/new.txt")))

        do {
            _ = try await filesystem.listDirectory(path: "/missing")
            Issue.record("expected missing path error")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOENT))
        }
    }

    @Test
    func `mountable filesystem supports directory copy and move across mounts`() async throws {
        let source = InMemoryFileSystem()
        try await source.createDirectory(path: "/tree/sub", recursive: true)
        try await source.writeFile(path: "/tree/sub/file.txt", data: MountingTestSupport.data("nested"), append: false)
        try await source.createSymlink(path: "/tree/link.txt", target: "sub/file.txt")

        let destination = InMemoryFileSystem()
        let filesystem = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/src", fileSystem: source),
                .init(mountPoint: "/dst", fileSystem: destination),
            ]
        )

        do {
            try await filesystem.copy(from: "/src/tree", to: "/dst/tree", recursive: false)
            Issue.record("expected recursive directory copy requirement")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        try await filesystem.copy(from: "/src/tree", to: "/dst/tree", recursive: true)
        #expect(try await destination.readFile(path: "/tree/sub/file.txt") == MountingTestSupport.data("nested"))
        #expect(try await destination.readSymlink(path: "/tree/link.txt") == "sub/file.txt")

        try await filesystem.move(from: "/src/tree/sub/file.txt", to: "/dst/moved.txt")
        #expect(!(await source.exists(path: "/tree/sub/file.txt")))
        #expect(try await destination.readFile(path: "/moved.txt") == MountingTestSupport.data("nested"))

        do {
            try await filesystem.createHardLink(path: "/dst/cross-hard.txt", target: "/src/tree/link.txt")
            Issue.record("expected cross-mount hard link rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("hard links across mounts are not supported"))
        }
    }

    @Test
    func `mounted filesystem supports dynamic mounts and constructor configured base storage`() async throws {
        let baseRoot = try MountingTestSupport.makeTempDirectory(prefix: "MountableBase")
        defer { MountingTestSupport.removeDirectory(baseRoot) }

        let base = try LocalFileSystem(root: baseRoot)
        let filesystem = MountedFileSystem(base: base)

        let memory = InMemoryFileSystem()
        filesystem.mount("/memory", fileSystem: memory)

        try await filesystem.writeFile(path: "/root.txt", data: MountingTestSupport.data("root"), append: false)
        try await filesystem.writeFile(path: "/memory/note.txt", data: MountingTestSupport.data("memo"), append: false)

        #expect(try await filesystem.readFile(path: "/root.txt") == MountingTestSupport.data("root"))
        #expect(try await memory.readFile(path: "/note.txt") == MountingTestSupport.data("memo"))
    }

    @Test
    func `mountable filesystem prefers the longest matching mount prefix`() async throws {
        let outer = InMemoryFileSystem()
        let inner = InMemoryFileSystem()
        try await outer.writeFile(path: "/outer.txt", data: MountingTestSupport.data("outer"), append: false)
        try await inner.writeFile(path: "/inner.txt", data: MountingTestSupport.data("inner"), append: false)

        let filesystem = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/mnt", fileSystem: outer),
                .init(mountPoint: "/mnt/deep", fileSystem: inner),
            ]
        )

        #expect(try await filesystem.readFile(path: "/mnt/outer.txt") == MountingTestSupport.data("outer"))
        #expect(try await filesystem.readFile(path: "/mnt/deep/inner.txt") == MountingTestSupport.data("inner"))
    }

    @Test
    func `mountable filesystem exposes synthetic parents for nested mount points`() async throws {
        let nested = InMemoryFileSystem()
        try await nested.writeFile(path: "/leaf.txt", data: MountingTestSupport.data("leaf"), append: false)

        let filesystem = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [.init(mountPoint: "/data/repo", fileSystem: nested)]
        )

        #expect(await filesystem.exists(path: "/data"))
        #expect(await filesystem.exists(path: "/data/repo"))

        let dataInfo = try await filesystem.stat(path: "/data")
        #expect(dataInfo.kind == .directory)
        #expect(dataInfo.path == "/data")

        let dataEntries = try await filesystem.listDirectory(path: "/data")
        #expect(dataEntries.map(\.name) == ["repo"])

        let repoEntries = try await filesystem.listDirectory(path: "/data/repo")
        #expect(repoEntries.map(\.name) == ["leaf.txt"])

        #expect(try await filesystem.readFile(path: "/data/repo/leaf.txt") == MountingTestSupport.data("leaf"))
    }

    @Test
    func `mountable filesystem glob aggregates paths from base and mounts`() async throws {
        let mounted = InMemoryFileSystem()
        try await mounted.writeFile(path: "/b.txt", data: MountingTestSupport.data("mb"), append: false)

        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/a.txt", data: MountingTestSupport.data("ba"), append: false)

        let filesystem = MountedFileSystem(
            base: base,
            mounts: [.init(mountPoint: "/m", fileSystem: mounted)]
        )

        let matches = try await filesystem.glob(pattern: "/*.txt", currentDirectory: "/")
        #expect(matches.contains("/a.txt"))
        #expect(!matches.contains("/m/b.txt"))

        let recursive = try await filesystem.glob(pattern: "/**.txt", currentDirectory: "/")
        #expect(recursive.contains("/a.txt"))
        #expect(recursive.contains("/m/b.txt"))
    }
}
