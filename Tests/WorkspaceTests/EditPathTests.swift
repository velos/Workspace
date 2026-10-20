import Foundation
import Testing
@testable import Workspace

@Suite("Edit path coverage")
struct EditPathTests {
    static var localWrappers: [String] {
        var wrappers = ["limited", "sandbox", "mounted", "authorized"]
        #if canImport(Darwin)
        wrappers.append("securityScoped")
        #endif
        return wrappers
    }

    @Test(arguments: localWrappers)
    func `wrapped local preview preserves overwrite modes and symlink semantics`(wrapper: String) async throws {
        let root = try TestSupport.temporaryDirectory("WrappedPreview")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/tool", data: Data("old".utf8), append: false)
        try await local.setPermissions(path: "/tool", permissions: POSIXPermissions(0o755))
        try await local.createSymlink(path: "/alias", target: "tool")
        let fs: any FileSystem
        switch wrapper {
        case "limited": fs = LimitedFileSystem(base: local, limits: .init())
        case "sandbox": fs = try SandboxFileSystem(root: .url(root))
        case "mounted": fs = MountedFileSystem(mounts: [.init(mountPoint: "/mount", fileSystem: local)])
        #if canImport(Darwin)
        case "securityScoped": fs = try SecurityScopedFileSystem(url: root)
        #endif
        default: fs = AuthorizedFileSystem(base: local, authorizer: PermissionAuthorizer { _ in .allow })
        }
        let prefix = wrapper == "mounted" ? "/mount" : ""
        let workspace = Workspace(fileSystem: fs)
        let edits: [Edit] = [.writeText(try WorkspacePath(prefix + "/alias"), "new")]
        let before = try await Snapshot.capture(from: fs)
        let preview = try await workspace.preview(edits)
        #expect(try await Snapshot.capture(from: fs).entry == before.entry)
        let applied = try await workspace.apply(edits)
        #expect(preview == applied.changes)
        #expect(preview.touchedPaths == [try WorkspacePath(prefix + "/tool")])
        #expect(try await local.stat(path: "/tool").permissions == POSIXPermissions(0o755))
        #expect(try await local.readSymlink(path: "/alias") == "tool")
        #expect(try await local.readFile(path: "/tool") == Data("new".utf8))
    }

    enum Backend: CaseIterable, Sendable { case memory, local, mounted }

    struct Scenario: Sendable, CustomStringConvertible {
        var description: String
        var edits: [Edit]
        var memoryRejects = false
    }

    static let scenarios: [Scenario] = [
        .init(description: "nested mount write", edits: [.writeText("/mnt/data/x", "hi")]),
        .init(description: "overwrite mode", edits: [.setPermissions("/dir/a", POSIXPermissions(0o600)), .writeText("/dir/a", "new")]),
        .init(description: "writeText", edits: [.writeText("/dir/a", "new")]),
        .init(description: "appendText", edits: [.appendText("/dir/a", "new")]),
        .init(description: "writeData", edits: [.writeData("/dir/a", Data([1, 2]))]),
        .init(description: "appendData", edits: [.appendData("/dir/a", Data([1, 2]))]),
        .init(description: "createDirectory", edits: [.createDirectory("/new/deep")]),
        .init(description: "remove", edits: [.remove("/dir/sub")]),
        .init(description: "copy", edits: [.copy(from: "/dir/sub", to: "/copied")]),
        .init(description: "move", edits: [.move(from: "/dir/sub", to: "/moved")]),
        .init(description: "createSymbolicLink", edits: [.createSymbolicLink("/newlink", target: "dir/a")]),
        .init(description: "createHardLink", edits: [.createHardLink("/hard", target: "/dir/a")]),
        .init(description: "setPermissions", edits: [.setPermissions("/dir/a", POSIXPermissions(0o600))]),
        .init(description: "replace", edits: [.replace(files: .init(root: "/dir"), pattern: .literal("alpha"), with: "new")]),
        .init(description: "alias writeText", edits: [.writeText("/dirlink/a", "new")]),
        .init(description: "alias appendText", edits: [.appendText("/dirlink/a", "new")]),
        .init(description: "alias writeData", edits: [.writeData("/dirlink/a", Data([1, 2]))]),
        .init(description: "alias appendData", edits: [.appendData("/dirlink/a", Data([1, 2]))]),
        // This backend currently rejects mkdir through a symlink. Verify that
        // rejection remains atomic too; filesystem traversal belongs to its slice.
        .init(description: "alias createDirectory", edits: [.createDirectory("/dirlink/new/deep")], memoryRejects: true),
        .init(description: "alias remove", edits: [.remove("/dirlink/sub")]),
        .init(description: "alias copy", edits: [.copy(from: "/dirlink/sub", to: "/dirlink/copied")]),
        .init(description: "alias move", edits: [.move(from: "/dirlink/sub", to: "/dirlink/moved")]),
        .init(description: "alias createSymbolicLink", edits: [.createSymbolicLink("/dirlink/newlink", target: "a")]),
        .init(description: "alias createHardLink", edits: [.createHardLink("/dirlink/hard", target: "/dirlink/a")]),
        .init(description: "alias setPermissions", edits: [.setPermissions("/dirlink/a", POSIXPermissions(0o600))]),
        .init(description: "alias replace", edits: [.replace(files: .init(include: ["/dirlink/a"]), pattern: .literal("alpha"), with: "new")]),
        .init(description: "alias new file", edits: [.writeText("/dirlink/new", "new")]),
        .init(description: "leaf write", edits: [.writeText("/link", "new")]),
        .init(description: "leaf append", edits: [.appendText("/link", "new")]),
        .init(description: "relative leaf through alias", edits: [.writeText("/dirlink/link", "new")]),
        .init(description: "dangling write", edits: [.writeText("/dangling", "new")]),
        .init(description: "dangling append", edits: [.appendText("/dangling", "new")]),
        .init(description: "dangling data", edits: [.writeData("/dangling", Data([1, 2]))]),
        .init(description: "dangling append data", edits: [.appendData("/dangling", Data([1, 2]))]),
        .init(description: "dangling chain", edits: [.writeText("/chain", "new")]),
        .init(description: "remove leaf link", edits: [.remove("/dirlink/link")]),
        .init(description: "move dangling link", edits: [.move(from: "/dangling", to: "/dirlink/moved")]),
        .init(description: "expanded root with dangling sibling", edits: [.writeText("/dir/a", "new"), .setPermissions("/", POSIXPermissions(0o750))]),
        .init(description: "move then edit alias", edits: [.move(from: "/dirlink/sub", to: "/dirlink/moved"), .writeText("/dirlink/moved/b", "new")]),
    ]

    // Exercise the nested mount regression here. The backend's separate empty
    // directory listing issue prevents applying the entire matrix to it yet.
    static let cases = Backend.allCases.flatMap { backend in
        scenarios.filter { backend != .mounted || $0.description == "nested mount write" }
            .map { (backend, $0) }
    }

    @Test(arguments: cases)
    func `scoped changes and rollback match whole tree`(backend: Backend, scenario: Scenario) async throws {
        for failing in [false, true] {
            let root = try TestSupport.temporaryDirectory()
            defer { TestSupport.remove(root) }
            let fs: any FileSystem = switch backend {
            case .memory: InMemoryFileSystem()
            case .local: try LocalFileSystem(root: root)
            case .mounted:
                MountedFileSystem(
                    base: InMemoryFileSystem(),
                    mounts: [.init(mountPoint: "/mnt/data", fileSystem: InMemoryFileSystem())]
                )
            }
            if backend != .mounted {
                try await fs.createDirectory(path: "/mnt/data", recursive: true)
            }
            try await fs.createDirectory(path: "/dir/sub", recursive: true)
            try await fs.writeFile(path: "/dir/a", data: Data("alpha".utf8), append: false)
            try await fs.writeFile(path: "/dir/sub/b", data: Data("beta".utf8), append: false)
            try await fs.createSymlink(path: "/dirlink", target: "dir")
            try await fs.createSymlink(path: "/dir/link", target: "a")
            try await fs.createSymlink(path: "/link", target: "dir/a")
            try await fs.createSymlink(path: "/dangling", target: "nowhere")
            try await fs.createSymlink(path: "/chain", target: "dangling")
            let workspace = Workspace(fileSystem: fs)
            let before = try await Snapshot.capture(from: fs)
            let edits = scenario.edits + (failing ? [.copy(from: "/absent", to: "/failure")] : [])
            if failing || (backend != .local && scenario.memoryRejects) {
                await #expect(throws: (any Error).self) { try await workspace.preview(edits) }
                do {
                    try await workspace.apply(edits)
                    Issue.record("expected edit failure")
                } catch {
                    #expect(!(error is WorkspaceRollbackError))
                }
                let after = try await Snapshot.capture(from: fs)
                #expect(after.entry == before.entry)
                #expect(try await workspace.history().isEmpty)
            } else {
                let preview = try await workspace.preview(edits)
                #expect(try await Snapshot.capture(from: fs).entry == before.entry)
                let result = try await workspace.apply(edits)
                #expect(preview == result.changes)
                let after = try await Snapshot.capture(from: fs)
                let expected = ChangeSet.compare(before: before, after: after, maxTextBytes: DiffOptions.default.maxTextBytes)
                #expect(result.changes == expected)
            }
        }
    }

    @Test
    func `removing a path beneath a local regular file is a no-op`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.writeFile(path: "/dir/a", data: Data("original".utf8), append: false)
        let workspace = Workspace(fileSystem: fs)
        let before = try await Snapshot.capture(from: fs)
        let result = try await workspace.remove("/dir/a/x")
        #expect(result.isEmpty)
        #expect(try await Snapshot.capture(from: fs).entry == before.entry)
        #expect(try await workspace.history().isEmpty)
    }

    @Test
    func `canonical alias changes update the observation baseline`() async throws {
        let root = try TestSupport.temporaryDirectory()
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/dir", recursive: true)
        try await fs.createSymlink(path: "/alias", target: "dir")
        let workspace = Workspace(fileSystem: fs)
        let events = await workspace.events(.init(path: .root, includeCheckpoints: false))
        let changes = try await workspace.writeText("/alias/new", "new")
        #expect(changes.touchedPaths == ["/dir/new"])
        #expect(await nextEditEvent(in: events) == .changes(changes))
        // Exercise the refresh directly as well as any native invalidation. This
        // verifies baseline folding without depending on OS event delivery timing.
        await workspace.refreshFilesystemEvents()
        #expect(await nextEditEvent(in: events, timeout: .milliseconds(100)) == nil)
    }
}
