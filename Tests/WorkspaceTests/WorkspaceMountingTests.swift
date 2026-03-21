import Foundation
import Testing
@testable import Workspace

@Suite("Workspace Mounting")
struct WorkspaceMountingTests {
    @Test("multiple isolated mounts can share a memory workspace")
    func multipleIsolatedMountsCanShareAMemoryWorkspace() async throws {
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
        try await workspace.cp("/memory/shared.txt", "/workspace-a/note.txt")

        #expect(try await workspace.readFile("/memory/shared.txt") == "memo")
        #expect(try await workspace.readFile("/workspace-a/note.txt") == "memo")
        #expect(!(await workspace.exists("/workspace-b/note.txt")))
    }

    @Test("previewEdits previews mounted changes without mutating")
    func previewEditsPreviewMountedChangesWithoutMutating() async throws {
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
        #expect(result.edits.map(\.operation) == [.copy, .appendFile])
        #expect(!(await workspace.exists("/workspace/shared.txt")))
        #expect(try await workspace.readFile("/memory/shared.txt") == "memo")
    }

    @Test("walkTree maxDepth stops recursion at nested directories")
    func walkTreeMaxDepthStopsRecursionAtNestedDirectories() async throws {
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

    @Test("copy and move operations work across mounted roots")
    func copyAndMoveOperationsWorkAcrossMountedRoots() async throws {
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
        try await workspace.cp("/docs/guide.txt", "/workspace/guide.txt")
        try await workspace.mv("/workspace/guide.txt", "/workspace/guide-copy.txt")

        #expect(!(await workspace.exists("/workspace/guide.txt")))
        #expect(try await workspace.readFile("/workspace/guide-copy.txt") == "guide")
        #expect(try await workspace.readFile("/docs/guide.txt") == "guide")
    }
}
