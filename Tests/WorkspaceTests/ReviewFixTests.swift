import Foundation
import Testing
@testable import Workspace

@Suite("PR review regressions")
struct ReviewFixTests {
    @Test(arguments: [WorkspacePath("/blocked"), WorkspacePath("/public.txt")], [false, true])
    func toolReadAuthorizesBothSpellings(denied: WorkspacePath, limited: Bool) async throws {
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/public.txt", data: Data("public".utf8), append: false)
        try await base.createSymlink(path: "/blocked", target: "public.txt")
        let authorized = AuthorizedFileSystem(base: base, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile], pathPrefix: denied, effect: .deny(message: "blocked")),
            .init(operations: [.readFile, .stat, .resolveRealPath], pathPrefix: "/", effect: .allow),
        ]))
        let fs: any FileSystem = limited ? LimitedFileSystem(base: authorized, limits: .init(maxTotalBytes: 100)) : authorized
        let workspace = Workspace(fileSystem: fs)
        await #expect(throws: WorkspaceError.self) { try await workspace.readText("/blocked") }
        await #expect(throws: WorkspaceError.self) { try await workspace.readData(from: "/blocked", offset: 0, length: 3) }
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        do {
            _ = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/blocked"}"#.utf8))
            Issue.record("tool read bypassed read authorization")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .permissionDenied)
            #expect(error.path == "/blocked")
        }
    }

    @Test func hardLinkAuthorizationDeniesResolvedSymlinkEntry() async throws {
        let base = InMemoryFileSystem()
        try await base.createDirectory(path: "/protected", recursive: true)
        try await base.writeFile(path: "/public/file", data: Data("public".utf8), append: false)
        try await base.createSymlink(path: "/protected/link", target: "../public/file")
        try await base.createSymlink(path: "/alias", target: "protected")
        let fs = AuthorizedFileSystem(base: base, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.createHardLink], pathPrefix: "/protected", effect: .deny(message: "protected")),
            .init(operations: [.createHardLink], pathPrefix: "/", effect: .allow),
        ]))
        do {
            try await fs.createHardLink(path: "/hard", target: "/alias/link")
            Issue.record("hard link bypassed the protected symlink entry")
        } catch let WorkspaceError.accessDenied(operation, _) {
            #expect(operation == PermissionOperation.createHardLink.rawValue)
        }
        #expect(!(await base.exists(path: "/hard")))
    }

    @Test func toolReadAuthorizesRequestedMetadata() async throws {
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/public.txt", data: Data("public".utf8), append: false)
        try await base.createSymlink(path: "/blocked", target: "public.txt")
        let fs = AuthorizedFileSystem(base: base, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.stat], pathPrefix: "/blocked", effect: .deny(message: "metadata denied")),
            .init(operations: [.readFile, .stat, .resolveRealPath], pathPrefix: "/", effect: .allow),
        ]))
        let workspace = Workspace(fileSystem: fs)
        #expect(try await workspace.readText("/blocked") == "public")
        do {
            _ = try await WorkspaceToolAdapter(workspace: workspace).call(
                name: "workspace_read", arguments: Data(#"{"path":"/blocked"}"#.utf8))
            Issue.record("tool read disclosed metadata despite requested-path stat denial")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .permissionDenied)
            #expect(error.path == "/blocked")
        }
    }

    @Test(arguments: [false, true])
    func toolReadWithoutRealPathResolution(symlinks: Bool) async throws {
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/dir/file", data: Data("ordinary read".utf8), append: false)
        try await base.createSymlink(path: "/dir/link", target: "file")
        try await base.createSymlink(path: "/alias", target: "dir")
        let fs: any FileSystem = symlinks ? SymlinkOnlyFileSystem(base: base) : RequiredOperationsFileSystem(base: base)
        let path: WorkspacePath = symlinks ? "/alias/link" : "/dir/file"
        let workspace = Workspace(fileSystem: fs)
        #expect(try await workspace.readText(path) == "ordinary read")
        let result = try await WorkspaceToolAdapter(workspace: workspace).call(
            name: "workspace_read", arguments: Data("{\"path\":\"\(path)\",\"offset\":2,\"max_bytes\":4}".utf8))
        let page = try JSONDecoder().decode(ReadPage.self, from: result)
        #expect(page.content == "dina")
        #expect(page.totalBytes == 13)
        #expect(page.nextOffset == 6)
    }

    @Test(arguments: ["retarget", "replace", "resize", "rewrite"])
    func toolReadRejectsChangesDuringRead(mutation: String) async throws {
        let memory = InMemoryFileSystem()
        // Mutate after the adapter has measured the file, before the read completes.
        try await memory.writeFile(path: "/first", data: Data("éabcd".utf8), append: false)
        try await memory.writeFile(path: "/second", data: Data("øwxyz".utf8), append: false)
        try await memory.createSymlink(path: "/link", target: "first")
        let hooked = HookableFileSystem(base: memory)
        await hooked.onRead { _ in
            switch mutation {
            case "retarget":
                try await memory.remove(path: "/link", recursive: false)
                try await memory.createSymlink(path: "/link", target: "second")
            case "replace":
                try await memory.remove(path: "/first", recursive: false)
                try await memory.writeFile(path: "/first", data: Data("øwxyz".utf8), append: false)
            case "resize": try await memory.writeFile(path: "/first", data: Data("longer".utf8), append: true)
            default: try await memory.writeFile(path: "/first", data: Data("øwxyz".utf8), append: false)
            }
        }
        let fs = ResolvingReadFileSystem(base: hooked, resolver: memory)
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        do {
            _ = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/link","offset":0,"max_bytes":4}"#.utf8))
            Issue.record("changed file returned a successful page")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .conflict)
            #expect(error.path == "/link")
            #expect(error.message == "The file changed during the read; retry this page.")
        }
    }

    @Test(arguments: [false, true])
    func resolvedReadRejectsSymlinkRetargetBetweenRanges(symlinksOnly: Bool) async throws {
        let fs = InMemoryFileSystem()
        try await fs.writeFile(path: "/first", data: Data("abcdef".utf8), append: false)
        try await fs.writeFile(path: "/second", data: Data("uvwxyz".utf8), append: false)
        try await fs.createSymlink(path: "/link", target: "first")
        let reader: any FileSystem = symlinksOnly ? SymlinkOnlyFileSystem(base: fs) : fs
        let file = try await Workspace(fileSystem: reader).resolvedReadableFile(at: "/link", revision: .current)
        #expect(try await file.readRange(0, 3) == Data("abc".utf8))
        try await fs.remove(path: "/link", recursive: false)
        try await fs.createSymlink(path: "/link", target: "second")
        do {
            _ = try await file.readRange(3, 3)
            Issue.record("retarget between ranges was not reported")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .conflict)
            #expect(error.message == "The file changed during the read; retry this page.")
        }
    }

    @Test(arguments: [false, true])
    func overlayHardLinkToSymlinkKeepsQuotaExact(upperSource: Bool) async throws {
        let lower = InMemoryFileSystem()
        let overlay = OverlayFileSystem(over: lower)
        let source: any FileSystem = upperSource ? overlay : lower
        try await source.writeFile(path: "/file", data: Data(repeating: 65, count: 10), append: false)
        try await source.createSymlink(path: "/link", target: "file")
        let limited = LimitedFileSystem(base: overlay, limits: .init(maxTotalBytes: 10))
        try await limited.createHardLink(path: "/hard", target: "/link")
        #expect(try await overlay.stat(path: "/hard").kind == .symlink)
        let entries = try await overlay.listDirectory(path: .root)
        #expect(entries.filter { $0.info.kind == .file }.reduce(UInt64(0)) { $0 + $1.info.size } == 10)
        await #expect(throws: FileSystemLimitError.self) { try await limited.createFile(path: "/extra", data: Data([1])) }
        try await limited.revalidate()
        await #expect(throws: FileSystemLimitError.self) { try await limited.createFile(path: "/extra", data: Data([1])) }
    }

    private struct ReadPage: Decodable {
        var content: String
        var totalBytes: UInt64
        var nextOffset: UInt64
    }
}

// Deliberately implement only required operations. Capabilities, resolution and
// range reads use the FileSystem defaults, as a minimal third-party backend does.
private protocol RequiredOperationsForwarding: FileSystem { var base: any FileSystem { get } }
private extension RequiredOperationsForwarding {
    func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] { try await base.listDirectory(path: path) }
    func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { try await base.writeFile(path: path, data: data, append: append) }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { try await base.createDirectory(path: path, recursive: recursive) }
    func remove(path: WorkspacePath, recursive: Bool) async throws { try await base.remove(path: path, recursive: recursive) }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { try await base.move(from: sourcePath, to: destinationPath) }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }
}
private final class RequiredOperationsFileSystem: RequiredOperationsForwarding {
    let base: any FileSystem
    init(base: any FileSystem) { self.base = base }
}
private final class ResolvingReadFileSystem: RequiredOperationsForwarding {
    let base: any FileSystem
    let resolver: any FileSystem
    init(base: any FileSystem, resolver: any FileSystem) { self.base = base; self.resolver = resolver }
    func capabilities() async -> FileSystemFeatures { [.realPathResolution] }
    func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath { try await resolver.resolveRealPath(path: path) }
}

private final class SymlinkOnlyFileSystem: RequiredOperationsForwarding {
    let base: any FileSystem
    init(base: any FileSystem) { self.base = base }
    func capabilities() async -> FileSystemFeatures { [.symlinks] }
    func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
}
