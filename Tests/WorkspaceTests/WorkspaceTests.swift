import Foundation
import Testing
@testable import Workspace

private enum WorkspaceTestSupport {
    static func makeTempDirectory(prefix: String = "WorkspaceTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class FailOnceFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let base: any WorkspaceFilesystem
    private let failingWritePaths: Set<String>
    private var failedWritePaths: Set<String> = []

    init(base: any WorkspaceFilesystem, failingWritePaths: Set<String>) {
        self.base = base
        self.failingWritePaths = failingWritePaths
    }

    func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: String) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: String) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: String, data: Data, append: Bool) async throws {
        if failingWritePaths.contains(path), !failedWritePaths.contains(path) {
            failedWritePaths.insert(path)
            throw WorkspaceError.unsupported("forced write failure")
        }
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: String, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: String, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: String, to destinationPath: String, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: String, target: String) async throws {
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: String, target: String) async throws {
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: String) async throws -> String {
        try await base.readSymlink(path: path)
    }

    func setPermissions(path: String, permissions: Int) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: String) async throws -> String {
        try await base.resolveRealPath(path: path)
    }

    func exists(path: String) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: String) async throws -> [String] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private struct DemoConfig: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
}

@Suite("Workspace")
struct WorkspaceTests {
    @Test("workspace module reexports core filesystem primitives")
    func workspaceModuleReexportsCoreFilesystemPrimitives() async throws {
        let workspaceFilesystem: any WorkspaceFilesystem = InMemoryFilesystem()
        let mount = MountableFilesystem.Mount(mountPoint: "/memory", filesystem: InMemoryFilesystem())
        let permission = WorkspacePermissionRequest(operation: .readFile, path: "/memory/note.txt")
        let error = WorkspaceError.unsupported("workspace shim check")

        #expect(await workspaceFilesystem.exists(path: "/"))
        #expect(mount.mountPoint == "/memory")
        #expect(permission.path == "/memory/note.txt")
        #expect(error.description.contains("workspace shim check"))
    }

    @Test("readJson and writeJson roundtrip")
    func readJsonAndWriteJsonRoundtrip() async throws {
        let fs = InMemoryFilesystem()
        let state = Workspace(filesystem: fs)

        try await state.writeJson("/config.json", value: DemoConfig(name: "demo", enabled: true))
        let loaded = try await state.readJson("/config.json", as: DemoConfig.self)
        #expect(loaded == DemoConfig(name: "demo", enabled: true))
    }

    @Test("readJson rejects invalid JSON")
    func readJsonRejectsInvalidJSON() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/broken.json", data: Data("{ nope".utf8), append: false)
        let state = Workspace(filesystem: fs)

        do {
            _ = try await state.readJson("/broken.json", as: DemoConfig.self)
            Issue.record("expected invalid JSON error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("invalid JSON"))
        }
    }

    @Test("walkTree and summarizeTree preserve stable ordering")
    func walkTreeAndSummarizeTreePreserveStableOrdering() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src", recursive: true)
        try await fs.writeFile(path: "/src/b.txt", data: Data("b".utf8), append: false)
        try await fs.writeFile(path: "/src/a.txt", data: Data("aa".utf8), append: false)
        try await fs.createDirectory(path: "/src/nested", recursive: true)
        let state = Workspace(filesystem: fs)

        let tree = try await state.walkTree("/src", maxDepth: 1)
        #expect(tree.children?.map(\.path) == ["/src/a.txt", "/src/b.txt", "/src/nested"])

        let summary = try await state.summarizeTree("/src", maxDepth: 1)
        #expect(summary.children.map(\.path) == ["/src/a.txt", "/src/b.txt", "/src/nested"])
        #expect(summary.fileCount == 2)
        #expect(summary.directoryCount == 2)
    }

    @Test("replaceInFiles dry run previews without mutating files")
    func replaceInFilesDryRunPreviewsWithoutMutatingFiles() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src", recursive: true)
        try await fs.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await fs.writeFile(path: "/src/b.txt", data: Data("foo bar".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.replaceInFiles("/src/*.txt", search: "foo", replacement: "baz", dryRun: true)
        #expect(result.dryRun)
        #expect(result.touchedPaths == ["/src/a.txt", "/src/b.txt"])
        #expect(result.changes.map(\.updatedContent) == ["baz", "baz bar"])
        #expect(try await state.readFile("/src/a.txt") == "foo")
    }

    @Test("replaceInFiles rolls back on write failure")
    func replaceInFilesRollsBackOnWriteFailure() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.replaceInFiles("/src/*.txt", search: "foo", replacement: "bar")
        #expect(result.rolledBack)
        #expect(try await base.readFile(path: "/src/a.txt") == Data("foo".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
    }

    @Test("applyEdits succeeds across multiple files")
    func applyEditsSucceedsAcrossMultipleFiles() async throws {
        let fs = InMemoryFilesystem()
        let state = Workspace(filesystem: fs)

        let result = try await state.applyEdits([
            .createDirectory(path: "/src"),
            .writeFile(path: "/src/a.txt", content: "one"),
            .appendFile(path: "/src/a.txt", content: " two"),
            .copy(from: "/src/a.txt", to: "/src/b.txt"),
            .move(from: "/src/b.txt", to: "/src/c.txt"),
        ])

        #expect(!result.rolledBack)
        #expect(result.touchedPaths == ["/src"])
        #expect(try await state.readFile("/src/a.txt") == "one two")
        #expect(try await state.readFile("/src/c.txt") == "one two")
    }

    @Test("applyEdits rolls back on failure")
    func applyEditsRollsBackOnFailure() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/a.txt", data: Data("old".utf8), append: false)
        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/b.txt"])
        )

        let result = try await state.applyEdits([
            .writeFile(path: "/a.txt", content: "new"),
            .writeFile(path: "/b.txt", content: "blocked"),
        ])

        #expect(result.rolledBack)
        #expect(try await base.readFile(path: "/a.txt") == Data("old".utf8))
        let bExists = await base.exists(path: "/b.txt")
        #expect(!bExists)
    }

    @Test("applyEdits works with overlay and mountable filesystems")
    func applyEditsWorksWithOverlayAndMountableFilesystems() async throws {
        let workspaceRoot = try WorkspaceTestSupport.makeTempDirectory(prefix: "WorkspaceMountRoot")
        defer { WorkspaceTestSupport.removeDirectory(workspaceRoot) }

        let docsRoot = try WorkspaceTestSupport.makeTempDirectory(prefix: "WorkspaceDocsRoot")
        defer { WorkspaceTestSupport.removeDirectory(docsRoot) }
        try Data("guide".utf8).write(to: docsRoot.appendingPathComponent("guide.txt"))

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/workspace", filesystem: try OverlayFilesystem(rootDirectory: workspaceRoot)),
                .init(mountPoint: "/docs", filesystem: try OverlayFilesystem(rootDirectory: docsRoot)),
            ]
        )

        let state = Workspace(filesystem: mountable)
        let result = try await state.applyEdits([
            .copy(from: "/docs/guide.txt", to: "/workspace/guide.txt"),
            .writeFile(path: "/workspace/note.txt", content: "hello"),
        ])

        #expect(!result.rolledBack)
        #expect(try await state.readFile("/workspace/guide.txt") == "guide")
        #expect(try await state.readFile("/workspace/note.txt") == "hello")
        #expect(!FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("guide.txt").path))
    }
}
