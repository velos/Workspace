import Foundation
import Testing
@testable import Workspace

@Suite("File systems")
struct FileSystemAPITests {
    @Test
    func `root mounts route descendants while nested mounts win`() async throws {
        let root = InMemoryFileSystem()
        let nested = InMemoryFileSystem()
        let mounted = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [
                .init(mountPoint: "/", fileSystem: root),
                .init(mountPoint: "/nested", fileSystem: nested),
            ]
        )
        try await mounted.writeFile(path: "/root.txt", data: Data("root".utf8), append: false)
        try await mounted.writeFile(path: "/nested/value.txt", data: Data("nested".utf8), append: false)
        #expect(try await root.readFile(path: "/root.txt") == Data("root".utf8))
        #expect(try await nested.readFile(path: "/value.txt") == Data("nested".utf8))
    }

    @Test
    func `generic overlay keeps mutations above its base`() async throws {
        let base = InMemoryFileSystem()
        try await base.writeFile(path: "/base.txt", data: Data("base".utf8), append: false)
        let overlay = OverlayFileSystem(over: base)
        try await overlay.writeFile(path: "/base.txt", data: Data("overlay".utf8), append: false)
        try await overlay.writeFile(path: "/new.txt", data: Data("new".utf8), append: false)
        #expect(try await overlay.readFile(path: "/base.txt") == Data("overlay".utf8))
        #expect(try await base.readFile(path: "/base.txt") == Data("base".utf8))
        #expect(!(await base.exists(path: "/new.txt")))
        try await overlay.discardChanges()
        #expect(try await overlay.readFile(path: "/base.txt") == Data("base".utf8))
    }

    @Test
    func `limits reject projected writes copies and entry growth`() async throws {
        let base = InMemoryFileSystem()
        let limited = LimitedFileSystem(
            base: base,
            limits: FileSystemLimits(maxTotalBytes: 5, maxEntryCount: 2, maxWriteBytes: 4)
        )
        try await limited.writeFile(path: "/a", data: Data("1234".utf8), append: false)
        do {
            try await limited.writeFile(path: "/a", data: Data("12345".utf8), append: false)
            Issue.record("expected per-write limit")
        } catch let error as FileSystemLimitError {
            #expect(error == .writeBytes(attempted: 5, limit: 4))
        }
        do {
            try await limited.copy(from: "/a", to: "/b", recursive: false)
            Issue.record("expected total limit")
        } catch let error as FileSystemLimitError {
            #expect(error == .totalBytes(attempted: 8, limit: 5))
        }
        #expect(!(await base.exists(path: "/b")))
    }

    @Test
    func `authorization supports temporary approvals rules and bounded audit`() async throws {
        let authorizer = PermissionAuthorizer(auditCapacity: 2) { _ in .allowFor(.milliseconds(2)) }
        let request = PermissionRequest(operation: .readFile, path: "/a")
        _ = await authorizer.authorize(request)
        _ = await authorizer.authorize(request)
        #expect(await authorizer.auditLog().map(\.source) == [.handler, .temporaryCache])
        try await Task.sleep(for: .milliseconds(5))
        _ = await authorizer.authorize(request)
        #expect(await authorizer.auditLog().count == 2)

        let rules = RuleBasedPermissionAuthorizer(
            rules: [.init(operations: [.readFile], pathPrefix: "/src", effect: .allow)]
        )
        #expect((await rules.authorize(.init(operation: .readFile, path: "/src/a"))).isAllowed)
        #expect(!(await rules.authorize(.init(operation: .readFile, path: "/src2/a"))).isAllowed)
    }

    @Test
    func `hard-link append shares content while replacement changes one path entry`() async throws {
        let memory = InMemoryFileSystem()
        try await assertHardLinkReplacement(on: memory)

        let root = try TestSupport.temporaryDirectory("HardLinks")
        defer { TestSupport.remove(root) }
        try await assertHardLinkReplacement(on: LocalFileSystem(root: root))
    }

    @Test
    func `local filesystem blocks symlink escapes`() async throws {
        let root = try TestSupport.temporaryDirectory("Root")
        let outside = try TestSupport.temporaryDirectory("Outside")
        defer { TestSupport.remove(root); TestSupport.remove(outside) }
        let secret = outside.appendingPathComponent("secret")
        try Data("secret".utf8).write(to: secret)
        let local = try LocalFileSystem(root: root)
        try await local.createSymlink(path: "/escape", target: secret.path)
        do {
            _ = try await local.readFile(path: "/escape")
            Issue.record("expected jail rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("invalid path"))
        }
        #expect(try await local.readSymlink(path: "/escape") == secret.path)
    }

    @Test
    func `workspace paths have one dynamic initializer and clear components`() throws {
        let path = try WorkspacePath("../src/./main.swift", relativeTo: "/project/tests")
        #expect(path == "/project/src/main.swift")
        #expect(path.name == "main.swift")
        #expect(path.parent == "/project/src")
        let invalid = "bad\u{0}path"
        #expect(throws: WorkspaceError.self) { try WorkspacePath(invalid) }
    }

    private func assertHardLinkReplacement(on fileSystem: any FileSystem) async throws {
        try await fileSystem.writeFile(path: "/target", data: Data("a".utf8), append: false)
        try await fileSystem.createHardLink(path: "/alias", target: "/target")
        try await fileSystem.writeFile(path: "/target", data: Data("b".utf8), append: true)
        #expect(try await fileSystem.readFile(path: "/alias") == Data("ab".utf8))
        try await fileSystem.writeFile(path: "/target", data: Data("new".utf8), append: false)
        #expect(try await fileSystem.readFile(path: "/target") == Data("new".utf8))
        #expect(try await fileSystem.readFile(path: "/alias") == Data("ab".utf8))
    }
}

private extension PermissionDecision {
    var isAllowed: Bool {
        switch self {
        case .allow, .allowFor, .allowForSession: true
        case .deny: false
        }
    }
}
