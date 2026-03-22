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
    private let failingWritePaths: Set<WorkspacePath>
    private var failedWritePaths: Set<WorkspacePath> = []

    init(base: any WorkspaceFilesystem, failingWritePaths: Set<WorkspacePath>) {
        self.base = base
        self.failingWritePaths = failingWritePaths
    }

    func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if failingWritePaths.contains(path), !failedWritePaths.contains(path) {
            failedWritePaths.insert(path)
            throw WorkspaceError.unsupported("forced write failure")
        }
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: WorkspacePath, target: String) async throws {
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: WorkspacePath) async throws -> String {
        try await base.readSymlink(path: path)
    }

    func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }

    func exists(path: WorkspacePath) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private final class NSErrorFailOnceFilesystem: WorkspaceFilesystem, @unchecked Sendable {
    private let base: any WorkspaceFilesystem
    private let failingWritePaths: Set<WorkspacePath>
    private var failedWritePaths: Set<WorkspacePath> = []

    init(base: any WorkspaceFilesystem, failingWritePaths: Set<WorkspacePath>) {
        self.base = base
        self.failingWritePaths = failingWritePaths
    }

    func configure(rootDirectory: URL) throws {
        try base.configure(rootDirectory: rootDirectory)
    }

    func stat(path: WorkspacePath) async throws -> FileInfo {
        try await base.stat(path: path)
    }

    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }

    func readFile(path: WorkspacePath) async throws -> Data {
        try await base.readFile(path: path)
    }

    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        if failingWritePaths.contains(path), !failedWritePaths.contains(path) {
            failedWritePaths.insert(path)
            throw NSError(domain: "WorkspaceTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "forced NSError write failure"])
        }
        try await base.writeFile(path: path, data: data, append: append)
    }

    func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await base.createDirectory(path: path, recursive: recursive)
    }

    func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await base.remove(path: path, recursive: recursive)
    }

    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await base.move(from: sourcePath, to: destinationPath)
    }

    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    func createSymlink(path: WorkspacePath, target: String) async throws {
        try await base.createSymlink(path: path, target: target)
    }

    func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await base.createHardLink(path: path, target: target)
    }

    func readSymlink(path: WorkspacePath) async throws -> String {
        try await base.readSymlink(path: path)
    }

    func setPermissions(path: WorkspacePath, permissions: Int) async throws {
        try await base.setPermissions(path: path, permissions: permissions)
    }

    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }

    func exists(path: WorkspacePath) async -> Bool {
        await base.exists(path: path)
    }

    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
}

private struct DemoConfig: Codable, Equatable, Sendable {
    var name: String
    var enabled: Bool
}

private func diffLines(_ diff: WorkspaceTextDiff?) -> [WorkspaceTextDiffLine] {
    diff?.hunks.flatMap(\.lines) ?? []
}

private func addedLineTexts(_ diff: WorkspaceTextDiff?) -> [String] {
    diffLines(diff).filter { $0.kind == .added }.map(\.text)
}

private func removedLineTexts(_ diff: WorkspaceTextDiff?) -> [String] {
    diffLines(diff).filter { $0.kind == .removed }.map(\.text)
}

@Suite("Workspace")
struct WorkspaceTests {
    @Test
    func `workspace module reexports core filesystem primitives`() async throws {
        let workspaceFilesystem: any WorkspaceFilesystem = InMemoryFilesystem()
        let mount = MountableFilesystem.Mount(mountPoint: "/memory", filesystem: InMemoryFilesystem())
        let permission = WorkspacePermissionRequest(operation: .readFile, path: "/memory/note.txt")
        let error = WorkspaceError.unsupported("workspace shim check")

        #expect(await workspaceFilesystem.exists(path: "/"))
        #expect(mount.mountPoint == "/memory")
        #expect(permission.path == "/memory/note.txt")
        #expect(error.description.contains("workspace shim check"))
    }

    @Test
    func `readJson and writeJson roundtrip`() async throws {
        let fs = InMemoryFilesystem()
        let state = Workspace(filesystem: fs)

        try await state.writeJson("/config.json", value: DemoConfig(name: "demo", enabled: true))
        let loaded = try await state.readJson("/config.json", as: DemoConfig.self)
        #expect(loaded == DemoConfig(name: "demo", enabled: true))
    }

    @Test
    func `readJson rejects invalid JSON`() async throws {
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

    @Test
    func `walkTree and summarizeTree preserve stable ordering`() async throws {
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

    @Test
    func `walkTree and summarizeTree report symlink kinds`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)
        try await fs.createSymlink(path: "/alias.txt", target: "note.txt")
        let state = Workspace(filesystem: fs)

        let tree = try await state.walkTree("/")
        let alias = try #require(tree.children?.first(where: { $0.path == "/alias.txt" }))
        #expect(alias.kind == .symlink)

        let summary = try await state.summarizeTree("/")
        let aliasSummary = try #require(summary.children.first(where: { $0.path == "/alias.txt" }))
        #expect(aliasSummary.kind == .symlink)
        #expect(summary.symlinkCount == 1)
    }

    @Test
    func `previewReplacement previews without mutating files`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src", recursive: true)
        try await fs.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await fs.writeFile(path: "/src/b.txt", data: Data("foo bar".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewReplacement(
            WorkspaceReplaceRequest(pattern: "/src/*.txt", search: "foo", replacement: "baz")
        )
        #expect(result.mode == .preview)
        #expect(result.touchedPaths == ["/src/a.txt", "/src/b.txt"])
        #expect(result.changes.map(\.status) == [.planned, .planned])
        #expect(result.changes.map(\.replacements) == [1, 1])
        #expect(result.changes.map { addedLineTexts($0.diff) } == [["baz"], ["baz bar"]])
        #expect(try await state.readFile("/src/a.txt") == "foo")
    }

    @Test
    func `applyReplacement rolls back on write failure`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            WorkspaceReplaceRequest(pattern: "/src/*.txt", search: "foo", replacement: "bar"),
            failurePolicy: .rollback
        )
        #expect(result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.changes.map(\.status) == [.rolledBack, .failed])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("foo".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
    }

    @Test
    func `applyReplacement best effort reports failures without rollback`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: FailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            WorkspaceReplaceRequest(pattern: "/src/*.txt", search: .regularExpression("f.o"), replacement: "bar"),
            failurePolicy: .bestEffort
        )

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.changes.map(\.status) == [.applied, .failed])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("bar".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
    }

    @Test
    func `applyReplacement fail-fast stops after the first failure`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/src", recursive: true)
        try await base.writeFile(path: "/src/a.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/b.txt", data: Data("foo".utf8), append: false)
        try await base.writeFile(path: "/src/c.txt", data: Data("foo".utf8), append: false)

        let state = Workspace(
            filesystem: NSErrorFailOnceFilesystem(base: base, failingWritePaths: ["/src/b.txt"])
        )

        let result = try await state.applyReplacement(
            WorkspaceReplaceRequest(pattern: "/src/*.txt", search: "foo", replacement: "bar"),
            failurePolicy: .failFast
        )

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.path == "/src/b.txt")
        #expect(result.failures.first?.message.contains("WorkspaceTests") == true)
        #expect(result.changes.map(\.status) == [.applied, .failed, .skipped])
        #expect(try await base.readFile(path: "/src/a.txt") == Data("bar".utf8))
        #expect(try await base.readFile(path: "/src/b.txt") == Data("foo".utf8))
        #expect(try await base.readFile(path: "/src/c.txt") == Data("foo".utf8))
    }

    @Test
    func `applyReplacement returns an empty execution result when nothing matches`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        let result = try await state.applyReplacement(
            WorkspaceReplaceRequest(pattern: "/missing/*.txt", search: "foo", replacement: "bar")
        )

        #expect(result.mode == .execution)
        #expect(result.touchedPaths.isEmpty)
        #expect(result.changes.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!result.rolledBack)
    }

    @Test
    func `previewReplacement respects scope excludes and case-insensitive matching`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src/dir", recursive: true)
        try await fs.writeFile(path: "/src/keep.txt", data: Data("FoO".utf8), append: false)
        try await fs.writeFile(path: "/src/skip.txt", data: Data("foo".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewReplacement(
            WorkspaceReplaceRequest(
                scope: "/src",
                include: ["*.txt", "dir"],
                exclude: ["skip.txt"],
                search: .literal("foo", caseSensitive: false),
                replacement: "bar"
            )
        )

        #expect(result.touchedPaths == ["/src/keep.txt"])
        #expect(result.changes.count == 1)
        #expect(result.changes.first?.status == .planned)
        #expect(removedLineTexts(result.changes.first?.diff) == ["FoO"])
        #expect(addedLineTexts(result.changes.first?.diff) == ["bar"])
    }

    @Test
    func `previewReplacement rejects invalid UTF-8 and empty search patterns`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.writeFile(path: "/binary.bin", data: Data([0xFF]), append: false)
        try await fs.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)
        let state = Workspace(filesystem: fs)

        do {
            _ = try await state.previewReplacement(
                WorkspaceReplaceRequest(
                    include: ["/binary.bin"],
                    search: .literal("x"),
                    replacement: "y"
                )
            )
            Issue.record("expected invalid UTF-8 error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("not valid UTF-8"))
        }

        do {
            _ = try await state.previewReplacement(
                WorkspaceReplaceRequest(
                    include: ["/note.txt"],
                    search: .literal("", caseSensitive: false),
                    replacement: "y"
                )
            )
            Issue.record("expected empty literal search rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("must not be empty"))
        }

        do {
            _ = try await state.previewReplacement(
                WorkspaceReplaceRequest(
                    include: ["/note.txt"],
                    search: .regularExpression(""),
                    replacement: "y"
                )
            )
            Issue.record("expected empty regex search rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("must not be empty"))
        }
    }

    @Test
    func `applyEdits succeeds across multiple files`() async throws {
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
        #expect(result.mode == .execution)
        #expect(result.touchedPaths == ["/src"])
        #expect(result.edits.map(\.status) == [.applied, .applied, .applied, .applied, .applied])
        #expect(addedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one"])
        #expect(addedLineTexts(result.edits[2].fileChanges.first?.diff) == ["one two"])
        #expect(result.edits[3].fileChanges.first?.sourcePath == "/src/a.txt")
        #expect(result.edits[4].fileChanges.first?.sourcePath == "/src/b.txt")
        #expect(try await state.readFile("/src/a.txt") == "one two")
        #expect(try await state.readFile("/src/c.txt") == "one two")
    }

    @Test
    func `applyEdits rolls back on failure`() async throws {
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
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.index == 1)
        #expect(result.edits.map(\.status) == [.rolledBack, .failed])
        #expect(result.edits.first?.fileChanges.first?.status == .rolledBack)
        #expect(try await base.readFile(path: "/a.txt") == Data("old".utf8))
        let bExists = await base.exists(path: "/b.txt")
        #expect(!bExists)
    }

    @Test
    func `previewEdits reports unchanged and delete effects`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/same.txt", data: Data("same".utf8), append: false)
        try await fs.writeFile(path: "/delete.txt", data: Data("bye".utf8), append: false)
        let state = Workspace(filesystem: fs)

        let result = try await state.previewEdits([
            .writeFile(path: "/same.txt", content: "same"),
            .delete(path: "/delete.txt"),
            .delete(path: "/missing.txt"),
            .createDirectory(path: "/dir"),
            .move(from: "/same.txt", to: "/same.txt"),
        ])

        #expect(result.mode == .preview)
        #expect(result.edits.map(\.status) == [.planned, .planned, .planned, .planned, .planned])
        #expect(result.edits.map(\.effect) == [.unchanged, .deleted, .unchanged, .unchanged, .unchanged])
        #expect(result.edits[0].fileChanges.count == 1)
        #expect(result.edits[0].fileChanges[0].diff?.hunks.isEmpty == true)
        #expect(removedLineTexts(result.edits[1].fileChanges.first?.diff) == ["bye"])
        #expect(result.edits[2].fileChanges.isEmpty)
    }

    @Test
    func `applyEdits fail-fast keeps prior changes and reports non-workspace errors`() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/old.txt", data: Data("gone".utf8), append: false)
        let state = Workspace(
            filesystem: NSErrorFailOnceFilesystem(base: base, failingWritePaths: ["/blocked.txt"])
        )

        let result = try await state.applyEdits([
            .delete(path: "/old.txt"),
            .writeFile(path: "/blocked.txt", content: "blocked"),
            .writeFile(path: "/after.txt", content: "after"),
        ], failurePolicy: .failFast)

        #expect(!result.rolledBack)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.index == 1)
        #expect(result.failures.first?.message.contains("WorkspaceTests") == true)
        #expect(result.edits.map(\.status) == [.applied, .failed, .skipped])
        #expect(!(await base.exists(path: "/old.txt")))
        #expect(!(await base.exists(path: "/blocked.txt")))
        #expect(!(await base.exists(path: "/after.txt")))
    }

    @Test
    func `applyEdits returns an empty execution result when given no edits`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())
        let result = try await state.applyEdits([])

        #expect(result.mode == .execution)
        #expect(result.touchedPaths.isEmpty)
        #expect(result.edits.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(!result.rolledBack)
    }

    @Test
    func `previewEdits plans sequential text diffs across earlier edits`() async throws {
        let state = Workspace(filesystem: InMemoryFilesystem())

        let result = try await state.previewEdits([
            .writeFile(path: "/note.txt", content: "one"),
            .appendFile(path: "/note.txt", content: " two"),
        ])

        #expect(result.edits.map(\.status) == [.planned, .planned])
        #expect(addedLineTexts(result.edits[0].fileChanges.first?.diff) == ["one"])
        #expect(removedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one"])
        #expect(addedLineTexts(result.edits[1].fileChanges.first?.diff) == ["one two"])
    }

    @Test
    func `previewEdits expands recursive file changes and omits binary diffs`() async throws {
        let fs = InMemoryFilesystem()
        try await fs.createDirectory(path: "/src/nested", recursive: true)
        try await fs.writeFile(path: "/src/a.txt", data: Data("alpha".utf8), append: false)
        try await fs.writeFile(path: "/src/nested/b.bin", data: Data([0xFF]), append: false)
        let state = Workspace(filesystem: fs)

        let copyPreview = try await state.previewEdits([
            .copy(from: "/src", to: "/dest")
        ])
        let deletePreview = try await state.previewEdits([
            .delete(path: "/src")
        ])

        #expect(copyPreview.edits[0].fileChanges.map(\.path) == ["/dest/a.txt", "/dest/nested/b.bin"])
        #expect(copyPreview.edits[0].fileChanges.map(\.sourcePath) == ["/src/a.txt", "/src/nested/b.bin"])
        #expect(copyPreview.edits[0].fileChanges.allSatisfy { $0.diff == nil })
        #expect(deletePreview.edits[0].fileChanges.map(\.path) == ["/src/a.txt", "/src/nested/b.bin"])
        #expect(deletePreview.edits[0].fileChanges.first?.diff != nil)
        #expect(deletePreview.edits[0].fileChanges.last?.diff == nil)
    }

    @Test
    func `workspace path and type helpers cover normalization and coding`() throws {
        #expect(WorkspacePath(normalizing: "", relativeTo: "/base") == "/base")
        #expect(WorkspacePath(normalizing: "./child", relativeTo: "/base") == "/base/child")
        #expect(WorkspacePath.basename("/") == "/")
        #expect(WorkspacePath.dirname("/") == .root)
        #expect(WorkspacePath.join("/base", "/override") == "/override")
        #expect(WorkspacePath.globToRegex("file?.[ch]") == "^file.\\.[ch]$")
        #expect(WorkspacePath.globToRegex("file[") == "^file\\[$")

        let encoded = try JSONEncoder().encode(WorkspacePath(normalizing: "/tmp/../file.txt"))
        #expect(try JSONDecoder().decode(WorkspacePath.self, from: encoded) == "/file.txt")

        let invalidPathError = WorkspaceError.invalidPath("/bad\u{0}path")
        #expect(invalidPathError.description == "path contains null byte")

        let fileInfo = FileInfo(
            path: "/tmp/../file.txt",
            isDirectory: false,
            isSymbolicLink: false,
            size: 7,
            permissions: 0o644,
            modificationDate: nil
        )
        #expect(fileInfo.path == "/file.txt")
    }

    @Test
    func `applyEdits works with overlay and mountable filesystems`() async throws {
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
