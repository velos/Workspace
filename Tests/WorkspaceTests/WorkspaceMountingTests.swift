import Foundation
import Testing
@testable import Workspace

private enum WorkspaceMountingTestSupport {
    static func makeTempDirectory(prefix: String = "WorkspaceMountingTests") throws -> URL {
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

@Suite("Workspace Mounting")
struct WorkspaceMountingTests {
    @Test
    func `multiple isolated mounts can share a memory workspace`() async throws {
        let workspaceA = InMemoryFilesystem()

        let workspaceB = InMemoryFilesystem()

        let memory = InMemoryFilesystem()

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/workspace-a", filesystem: workspaceA),
                .init(mountPoint: "/workspace-b", filesystem: workspaceB),
                .init(mountPoint: "/memory", filesystem: memory),
            ]
        )

        let workspace = Workspace(filesystem: mountable)
        try await workspace.writeFile("/memory/shared.txt", content: "memo")
        try await workspace.copyItem(from: "/memory/shared.txt", to: "/workspace-a/note.txt")

        #expect(try await workspace.readFile("/memory/shared.txt") == "memo")
        #expect(try await workspace.readFile("/workspace-a/note.txt") == "memo")
        #expect(!(await workspace.exists("/workspace-b/note.txt")))
    }

    @Test
    func `previewEdits previews mounted changes without mutating`() async throws {
        let memory = InMemoryFilesystem()

        let workspaceRoot = InMemoryFilesystem()

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/workspace", filesystem: workspaceRoot),
                .init(mountPoint: "/memory", filesystem: memory),
            ]
        )
        try await memory.writeFile(path: "/shared.txt", data: Data("memo".utf8), append: false)

        let workspace = Workspace(filesystem: mountable)
        let result = try await workspace.previewEdits(
            [
                .copy(from: "/memory/shared.txt", to: "/workspace/shared.txt"),
                .appendFile(path: "/memory/shared.txt", content: "!"),
            ]
        )

        #expect(result.mode == .preview)
        #expect(result.edits.map(\.edit) == [
            .copy(from: "/memory/shared.txt", to: "/workspace/shared.txt"),
            .appendFile(path: "/memory/shared.txt", content: "!")
        ])
        #expect(!(await workspace.exists("/workspace/shared.txt")))
        #expect(try await workspace.readFile("/memory/shared.txt") == "memo")
    }

    @Test
    func `walkTree maxDepth stops recursion at nested directories`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.createDirectory(path: "/workspace/src/nested", recursive: true)
        try await filesystem.writeFile(path: "/workspace/src/nested/deep.txt", data: Data("deep".utf8), append: false)

        let workspace = Workspace(filesystem: filesystem)
        let tree = try await workspace.walkTree("/workspace", maxDepth: 1)

        #expect(tree.children?.count == 1)
        let src = try #require(tree.children?.first)
        #expect(src.path == "/workspace/src")
        #expect(src.children == nil)
    }

    @Test
    func `copy and move operations work across mounted roots`() async throws {
        let docs = InMemoryFilesystem()

        let workspaceFiles = InMemoryFilesystem()

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/docs", filesystem: docs),
                .init(mountPoint: "/workspace", filesystem: workspaceFiles),
            ]
        )
        try await docs.writeFile(path: "/guide.txt", data: Data("guide".utf8), append: false)

        let workspace = Workspace(filesystem: mountable)
        try await workspace.copyItem(from: "/docs/guide.txt", to: "/workspace/guide.txt")
        try await workspace.moveItem(from: "/workspace/guide.txt", to: "/workspace/guide-copy.txt")

        #expect(!(await workspace.exists("/workspace/guide.txt")))
        #expect(try await workspace.readFile("/workspace/guide-copy.txt") == "guide")
        #expect(try await workspace.readFile("/docs/guide.txt") == "guide")
    }

    @Test
    func `mountable filesystem merges base entries with mounted directories`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/docs", recursive: true)
        try await base.writeFile(path: "/docs/local.txt", data: WorkspaceMountingTestSupport.data("local"), append: false)
        try await base.writeFile(path: "/base.txt", data: WorkspaceMountingTestSupport.data("base"), append: false)

        let mountedDocs = InMemoryFilesystem()
        try await mountedDocs.writeFile(path: "/guide.txt", data: WorkspaceMountingTestSupport.data("guide"), append: false)

        let filesystem = MountableFilesystem(
            base: base,
            mounts: [.init(mountPoint: "/docs/external", filesystem: mountedDocs)]
        )

        let docsInfo = try await filesystem.stat(path: "/docs")
        #expect(docsInfo.kind == .directory)
        #expect(await filesystem.exists(path: "/docs"))
        #expect(try await filesystem.readFile(path: "/base.txt") == WorkspaceMountingTestSupport.data("base"))

        let docsEntries = try await filesystem.listDirectory(path: "/docs")
        #expect(docsEntries.map(\.name) == ["external", "local.txt"])

        let mountedEntries = try await filesystem.listDirectory(path: "/docs/external")
        #expect(mountedEntries.map(\.name) == ["guide.txt"])

        try await filesystem.writeFile(path: "/docs/external/new.txt", data: WorkspaceMountingTestSupport.data("new"), append: false)
        try await filesystem.createDirectory(path: "/docs/external/sub", recursive: true)
        try await filesystem.createSymlink(path: "/docs/external/link.txt", target: "guide.txt")
        try await filesystem.createHardLink(path: "/docs/external/hard.txt", target: "/docs/external/guide.txt")
        try await filesystem.setPermissions(path: "/docs/external/guide.txt", permissions: POSIXPermissions(0o600))

        #expect(try await filesystem.readSymlink(path: "/docs/external/link.txt") == "guide.txt")
        #expect(try await filesystem.resolveRealPath(path: "/docs/external/link.txt") == "/docs/external/guide.txt")
        #expect(try await mountedDocs.readFile(path: "/new.txt") == WorkspaceMountingTestSupport.data("new"))
        #expect(try await mountedDocs.readFile(path: "/hard.txt") == WorkspaceMountingTestSupport.data("guide"))
        #expect(try await mountedDocs.stat(path: "/guide.txt").permissions == POSIXPermissions(0o600))

        let globbed = try await filesystem.glob(pattern: "/docs/*.txt", currentDirectory: "/")
        #expect(globbed.contains("/docs/local.txt"))
        #expect(globbed.contains("/docs/external/guide.txt"))

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
        let source = InMemoryFilesystem()
        try await source.createDirectory(path: "/tree/sub", recursive: true)
        try await source.writeFile(path: "/tree/sub/file.txt", data: WorkspaceMountingTestSupport.data("nested"), append: false)
        try await source.createSymlink(path: "/tree/link.txt", target: "sub/file.txt")

        let destination = InMemoryFilesystem()
        let filesystem = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/src", filesystem: source),
                .init(mountPoint: "/dst", filesystem: destination),
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
        #expect(try await destination.readFile(path: "/tree/sub/file.txt") == WorkspaceMountingTestSupport.data("nested"))
        #expect(try await destination.readSymlink(path: "/tree/link.txt") == "sub/file.txt")

        try await filesystem.move(from: "/src/tree/sub/file.txt", to: "/dst/moved.txt")
        #expect(!(await source.exists(path: "/tree/sub/file.txt")))
        #expect(try await destination.readFile(path: "/moved.txt") == WorkspaceMountingTestSupport.data("nested"))

        do {
            try await filesystem.createHardLink(path: "/dst/cross-hard.txt", target: "/src/tree/link.txt")
            Issue.record("expected cross-mount hard link rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("hard links across mounts are not supported"))
        }
    }

    @Test
    func `mountable filesystem supports dynamic mounts and configurable base storage`() async throws {
        let baseRoot = try WorkspaceMountingTestSupport.makeTempDirectory(prefix: "WorkspaceMountableBase")
        defer { WorkspaceMountingTestSupport.removeDirectory(baseRoot) }

        let base = ReadWriteFilesystem()
        let filesystem = MountableFilesystem(base: base)
        try await filesystem.configure(rootDirectory: baseRoot)

        let memory = InMemoryFilesystem()
        filesystem.mount("/memory", filesystem: memory)

        try await filesystem.writeFile(path: "/root.txt", data: WorkspaceMountingTestSupport.data("root"), append: false)
        try await filesystem.writeFile(path: "/memory/note.txt", data: WorkspaceMountingTestSupport.data("memo"), append: false)

        #expect(try await filesystem.readFile(path: "/root.txt") == WorkspaceMountingTestSupport.data("root"))
        #expect(try await memory.readFile(path: "/note.txt") == WorkspaceMountingTestSupport.data("memo"))
    }
}
