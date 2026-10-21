import Foundation
import Testing
@testable import Workspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Unicode path boundaries")
struct UnicodePathRegressionTests {
    // All escape fixtures stay inside a disposable container: "outside" means outside
    // the LocalFileSystem root, never a real user directory.
    private func jail() throws -> (container: URL, outside: URL, fs: LocalFileSystem) {
        let container = try TestSupport.temporaryDirectory("UnicodeJail")
        let outside = container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (container, outside, try LocalFileSystem(root: container.appendingPathComponent("root")))
    }

    @Test
    func localReadCannotCrossSymlinkedAncestor() async throws {
        let fixture = try jail()
        defer { TestSupport.remove(fixture.container) }
        let secret = Data("outside secret".utf8)
        try secret.write(to: fixture.outside.appendingPathComponent("\u{301}secret"))
        try await fixture.fs.createSymlink(path: "/l", target: fixture.outside.path)
        await #expect(throws: WorkspaceError.self) {
            _ = try await fixture.fs.readFile(path: "/l/\u{301}secret")
        }
    }

    @Test
    func localWriteCannotPlantOutsideFile() async throws {
        let fixture = try jail()
        defer { TestSupport.remove(fixture.container) }
        try await fixture.fs.createSymlink(path: "/l", target: fixture.outside.path)
        await #expect(throws: WorkspaceError.self) {
            try await fixture.fs.writeFile(path: "/l/\u{301}evil.plist", data: Data("payload".utf8), append: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path).isEmpty)
    }

    enum Mutation: CaseIterable, Sendable {
        case overwrite, remove, hardLink
    }

    @Test(arguments: Mutation.allCases)
    func localOtherMutationsCannotCrossSymlinkedAncestor(operation: Mutation) async throws {
        let fixture = try jail()
        defer { TestSupport.remove(fixture.container) }
        let secretURL = fixture.outside.appendingPathComponent("\u{301}secret")
        let secret = Data("unchanged".utf8)
        try secret.write(to: secretURL)
        try await fixture.fs.createSymlink(path: "/l", target: fixture.outside.path)
        await #expect(throws: WorkspaceError.self) {
            switch operation {
            case .overwrite:
                try await fixture.fs.writeFile(path: "/l/\u{301}secret", data: Data("changed".utf8), append: false)
            case .remove:
                try await fixture.fs.remove(path: "/l/\u{301}secret", recursive: false)
            case .hardLink:
                try await fixture.fs.createHardLink(path: "/stolen", target: "/l/\u{301}secret")
            }
        }
        #expect(try Data(contentsOf: secretURL) == secret)
        #expect(!(await fixture.fs.exists(path: "/stolen")))
    }

    @Test
    func relativeSymlinkTargetCannotHideAncestor() async throws {
        let fixture = try jail()
        defer { TestSupport.remove(fixture.container) }
        try Data("outside".utf8).write(to: fixture.outside.appendingPathComponent("\u{301}secret"))
        try await fixture.fs.createSymlink(path: "/l", target: fixture.outside.path)
        try await fixture.fs.createSymlink(path: "/alias", target: "l/\u{301}secret")
        await #expect(throws: WorkspaceError.self) {
            _ = try await fixture.fs.readFile(path: "/alias")
        }
    }

    @Test
    func absoluteSymlinkTargetPreservesLeadingExtender() async throws {
        let root = try TestSupport.temporaryDirectory("UnicodeAbsoluteTarget")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        let target = root.appendingPathComponent("\u{301}file")
        try Data("inside".utf8).write(to: target)
        try await fs.createSymlink(path: "/alias", target: target.path)
        #expect(try await fs.readFile(path: "/alias") == Data("inside".utf8))
        #expect(try await fs.resolveRealPath(path: "/alias") == "/\u{301}file")
    }

    @Test
    func containmentUsesExactBytesAndBoundaries() {
        // Canonically equivalent spellings are deliberately distinct workspace paths.
        let decomposed = WorkspacePath("/cafe\u{301}/x")
        let composed = WorkspacePath("/caf\u{e9}")
        #expect(!decomposed.isWithin(composed))
        #expect(!composed.isWithin(WorkspacePath("/cafe\u{301}")))
        #expect(!(WorkspacePath("/cafe\u{301}-other/x")).isWithin(composed))
        #expect(!(WorkspacePath("/caf\u{e9}/x")).isWithin(WorkspacePath("/cafe")))

        // Inclusive equality, root, and slash boundaries use allocation-free byte checks.
        let path = WorkspacePath("/private/\u{301}x")
        #expect(path.isWithin(path))
        #expect(path.isWithin(.root))
        #expect(path.isWithin("/private"))
        #expect(!(WorkspacePath("/private-other/x")).isWithin("/private"))
        #expect(!(WorkspacePath("/priv")).isWithin("/private"))
    }

    @Test
    func denyRulesUseComponentBoundariesAndExactEquality() async throws {
        let authorizer = RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile], pathPrefix: "/private", effect: .deny(message: nil)),
            .init(operations: [.readFile], pathPrefix: "/caf\u{e9}", effect: .deny(message: nil)),
        ], defaultEffect: .allow)
        for path: WorkspacePath in ["/private/\u{301}x", "/caf\u{e9}/\u{301}x", "/caf\u{e9}"] {
            let decision = await authorizer.authorize(.init(operation: .readFile, path: path))
            guard case .deny = decision else {
                Issue.record("deny rule did not match \(path)")
                continue
            }
        }
        let decision = await authorizer.authorize(.init(operation: .readFile, path: "/private-other/\u{301}x"))
        guard case .allow = decision else { Issue.record("component boundary overmatched"); return }
    }

    @Test
    func mountRoutesUnicodeChildAndTranslatesRealPath() async throws {
        let base = InMemoryFileSystem()
        let mounted = InMemoryFileSystem()
        try await base.createDirectory(path: "/mnt", recursive: true)
        let fs = MountedFileSystem(base: base, mounts: [.init(mountPoint: "/mnt", fileSystem: mounted)])
        try await fs.writeFile(path: "/mnt/\u{301}x", data: Data("mount".utf8), append: false)
        #expect(await mounted.exists(path: "/\u{301}x"))
        #expect(!(await base.exists(path: "/mnt/\u{301}x")))
        #expect(try await fs.resolveRealPath(path: "/mnt/\u{301}x") == "/mnt/\u{301}x")
        let nested = MountedFileSystem(mounts: [.init(mountPoint: "/mnt/\u{301}dir/sub", fileSystem: mounted)])
        #expect(try await nested.listDirectory(path: "/mnt").map(\.name) == ["\u{301}dir"])
    }

    @Test
    func overlaySymlinkCannotResurrectCutEntry() async throws {
        let root = try TestSupport.temporaryDirectory("UnicodeOverlay")
        defer { TestSupport.remove(root) }
        let lower = try LocalFileSystem(root: root)
        try await lower.createDirectory(path: "/d", recursive: true)
        try Data("deleted".utf8).write(to: root.appendingPathComponent("d/\u{301}x"))
        for cut: WorkspacePath in ["/d/\u{301}x", "/d"] {
            let fs = OverlayFileSystem(over: lower)
            try await fs.remove(path: cut, recursive: true)
            if cut == "/d" {
                // Recreating the directory must not reveal its old lower children.
                try await fs.createDirectory(path: "/d", recursive: false)
            }
            try await fs.createSymlink(path: "/l", target: "d/\u{301}x")
            await #expect(throws: (any Error).self) { _ = try await fs.readFile(path: "/l") }
            #expect(try await lower.readFile(path: "/d/\u{301}x") == Data("deleted".utf8))
        }
    }

    @Test
    func inMemoryMoveIntoUnicodeDescendantPreservesSource() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(path: "/a", recursive: true)
        try await fs.writeFile(path: "/a/keep", data: Data("keep".utf8), append: false)
        await #expect(throws: (any Error).self) { try await fs.move(from: "/a", to: "/a/\u{301}b") }
        #expect(await fs.exists(path: "/a"))
        #expect(try await fs.readFile(path: "/a/keep") == Data("keep".utf8))
    }

    @Test
    func limitedCopyCountsUnicodeDescendants() async throws {
        let root = try TestSupport.temporaryDirectory("UnicodeQuota")
        defer { TestSupport.remove(root) }
        let base = try LocalFileSystem(root: root)
        try await base.createDirectory(path: "/a", recursive: true)
        // Host fixture makes the physical tree independent of WorkspacePath parsing.
        try Data([1, 2]).write(to: root.appendingPathComponent("a/\u{301}x"))
        let fs = LimitedFileSystem(base: base, limits: .init(maxTotalBytes: 3))
        await #expect(throws: FileSystemLimitError.totalBytes(attempted: 4, limit: 3)) {
            try await fs.copy(from: "/a", to: "/b", recursive: true)
        }
        #expect(!(await base.exists(path: "/b")))
    }

    @Test
    func toolJSONCannotBypassDenyRules() async throws {
        let base = InMemoryFileSystem()
        try await base.createDirectory(path: "/private", recursive: true)
        try await base.writeFile(path: "/private/\u{301}x", data: Data("secret".utf8), append: false)
        let fs = AuthorizedFileSystem(base: base, authorizer: RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.readFile, .writeFile], pathPrefix: "/private", effect: .deny(message: nil)),
        ], defaultEffect: .allow))
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        await #expect(throws: (any Error).self) {
            _ = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/private/\u0301x"}"#.utf8))
        }
        await #expect(throws: (any Error).self) {
            _ = try await adapter.call(name: "workspace_apply", arguments: Data(#"{"edits":[{"kind":"write_text","path":"/private/\u0301x","content":"changed"}]}"#.utf8))
        }
        #expect(try await base.readFile(path: "/private/\u{301}x") == Data("secret".utf8))
    }

    @Test(arguments: [false, true])
    func checkpointAndArchiveRetainUnicodeDescendants(diskBacked: Bool) async throws {
        let container = try TestSupport.temporaryDirectory("UnicodeRevision")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/d", recursive: true)
        try Data("saved".utf8).write(to: root.appendingPathComponent("d/\u{301}x"))
        let workspace = Workspace(fileSystem: fs, persistence: diskBacked
            ? .directory(container.appendingPathComponent("history")) : .memory)
        let checkpoint = try await workspace.createCheckpoint()
        #expect(try await workspace.readText("/d/\u{301}x", at: .checkpoint(checkpoint.id)) == "saved")
        let archive = try await workspace.archive(at: "/d", from: .checkpoint(checkpoint.id))
        let restored = Workspace()
        try await restored.restore(archive, at: "/restored")
        #expect(try await restored.readText("/restored/\u{301}x") == "saved")
        #expect(!(await restored.exists("/d/\u{301}x")))
    }

    @Test
    func recursiveEventsIncludeUnicodeDescendants() async throws {
        let workspace = Workspace()
        try await workspace.createDirectory("/d")
        let stream = await workspace.events(.init(path: "/d", includeCheckpoints: false))
        let expected = try await workspace.writeText("/d/\u{301}x", "first")
        // A second matching event makes an omitted first event observable without
        // timing assumptions or an indefinitely suspended iterator on the baseline.
        try await workspace.writeText("/d/sentinel", "second")
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .changes(expected))
    }

    @Test
    func extendingScalarsAgreeAcrossPathsAndBackends() async throws {
        let root = try TestSupport.temporaryDirectory("UnicodeProperties")
        defer { TestSupport.remove(root) }
        var backends: [(String, any FileSystem)] = [
            ("memory", InMemoryFileSystem()),
            ("local", try LocalFileSystem(root: root.appendingPathComponent("local"))),
            ("overlay", OverlayFileSystem(over: InMemoryFileSystem())),
            ("mounted", MountedFileSystem(mounts: [.init(mountPoint: "/d", fileSystem: InMemoryFileSystem())])),
            ("limited", LimitedFileSystem(base: InMemoryFileSystem(), limits: .init(maxTotalBytes: 1000))),
            ("authorized", AuthorizedFileSystem(base: InMemoryFileSystem(), authorizer: RuleBasedPermissionAuthorizer(rules: [], defaultEffect: .allow))),
            ("sandbox", try SandboxFileSystem(root: .url(root.appendingPathComponent("sandbox")))),
        ]
        #if canImport(Darwin)
        backends.append(("securityScoped", try SecurityScopedFileSystem(url: root.appendingPathComponent("scoped"))))
        #endif
        let extensions = ["\u{301}", "\u{200d}", "\u{20e3}", "\u{fe0f}", "\u{fe0e}\u{301}", "\u{1f3fb}", "\u{903}"]
        for (index, ext) in extensions.enumerated() {
            #expect(("/" + ext).count == 1, "fixture must hide slash inside a grapheme cluster")
            let name = ext + "x"
            let path = try WorkspacePath("/d/" + name)
            #expect(path.components == ["d", name])
            #expect(path.name == name)
            #expect(path.parent == "/d")
            #expect(try WorkspacePath("/" + name, relativeTo: "/other").components == [name])
            #expect(try WorkspacePath("/d/" + name + "/../kept") == "/d/kept")
            #expect(WorkspacePath.root.appending("d").appending(name) == path)
            for (label, fs) in backends {
                do {
                    try await fs.createDirectory(path: "/d", recursive: true)
                    let data = Data([UInt8(index)])
                    try await fs.writeFile(path: path, data: data, append: false)
                    #expect(try await fs.listDirectory(path: "/d").contains { $0.name == name }, "\(label)")
                    #expect(try await fs.readFile(path: path) == data, "\(label)")
                    let link = try WorkspacePath("/d/link\(index)")
                    try await fs.createSymlink(path: link, target: name)
                    #expect(try await fs.readFile(path: link) == data, "\(label)")
                    #expect(try await fs.resolveRealPath(path: link) == path, "\(label)")
                    // **/ must be recognized even when / joins the following scalar.
                    #expect(try await fs.glob(pattern: "/d/**/" + name, currentDirectory: .root).contains(path), "\(label)")
                } catch {
                    Issue.record(error, "\(label), scalar sequence \(index)")
                }
            }
        }
    }
}
