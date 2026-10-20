import Foundation
import Testing

@testable import Workspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Path resolution and authorization")
struct PathResolutionTests {
    @Test
    func authorizationChecksResolvedTargets() async throws {
        let root = try TestSupport.temporaryDirectory("AuthorizationPaths")
        defer {
            TestSupport.remove(root)
        }
        let base = try LocalFileSystem(root: root)
        try await base.createDirectory(path: "/public", recursive: true)
        try await base.createDirectory(path: "/private", recursive: true)
        try await base.writeFile(path: "/private/secret", data: Data("secret".utf8), append: false)
        try await base.createSymlink(path: "/public/link", target: "../private/secret")
        try await base.createSymlink(path: "/public/alias", target: "../private")
        let operations: Set<PermissionOperation> = [
            .readFile, .stat, .exists, .writeFile, .setPermissions, .remove, .readSymlink,
        ]
        let fs = AuthorizedFileSystem(
            base: base,
            authorizer: RuleBasedPermissionAuthorizer(rules: [
                .init(operations: operations, pathPrefix: "/public", effect: .allow)
            ]))
        for path: WorkspacePath in ["/private/secret", "/public/link", "/public/alias/secret"] {
            await #expect(throws: WorkspaceError.self) {
                _ = try await fs.readFile(path: path)
            }
        }
        await #expect(throws: WorkspaceError.self) {
            _ = try await fs.stat(path: "/public/alias/secret")
        }
        #expect(!(await fs.exists(path: "/public/alias/secret")))
        for append in [false, true] {
            await #expect(throws: WorkspaceError.self) {
                try await fs.writeFile(path: "/public/link", data: Data("leak".utf8), append: append)
            }
        }
        await #expect(throws: WorkspaceError.self) {
            try await fs.createFile(path: "/public/alias/new", data: Data())
        }
        await #expect(throws: WorkspaceError.self) {
            try await fs.setPermissions(path: "/public/link", permissions: POSIXPermissions(0o777))
        }
        #expect(try await fs.stat(path: "/public/link").kind == .symlink)
        #expect(try await fs.readSymlink(path: "/public/link") == "../private/secret")
        try await fs.remove(path: "/public/link", recursive: false)
        #expect(try await base.readFile(path: "/private/secret") == Data("secret".utf8))
    }

    @Test
    func denyRulesMatchEitherEndpoint() async throws {
        for operation: PermissionOperation in [.copy, .move, .createHardLink] {
            for reverse in [false, true] {
                let base = InMemoryFileSystem()
                try await base.createDirectory(path: "/private", recursive: true)
                try await base.createDirectory(path: "/public", recursive: true)
                let source: WorkspacePath = reverse ? "/public/source" : "/private/source"
                let destination: WorkspacePath = reverse ? "/private/destination" : "/public/destination"
                try await base.writeFile(path: source, data: Data("secret".utf8), append: false)
                let fs = AuthorizedFileSystem(
                    base: base,
                    authorizer: RuleBasedPermissionAuthorizer(rules: [
                        .init(operations: [operation], pathPrefix: "/private", effect: .deny(message: "private")),
                        .init(operations: [operation], pathPrefix: "/", effect: .allow),
                    ]))
                await #expect(throws: WorkspaceError.self) {
                    switch operation {
                    case .copy: try await fs.copy(from: source, to: destination, recursive: false)
                    case .move: try await fs.move(from: source, to: destination)
                    default: try await fs.createHardLink(path: destination, target: source)
                    }
                }
                #expect(!(await base.exists(path: destination)))
                #expect(await base.exists(path: source))
            }
        }
    }

    @Test
    func rootDescriptorSurvivesRootPathReplacement() async throws {
        let container = try TestSupport.temporaryDirectory("PinnedRoot")
        defer {
            TestSupport.remove(container)
        }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("outside")
        let fs = try LocalFileSystem(root: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try await fs.writeFile(path: "/file", data: Data("inside".utf8), append: false)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.moveItem(at: root, to: container.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(try await fs.readFile(path: "/file") == Data("inside".utf8))
        try await fs.writeFile(path: "/file", data: Data("!".utf8), append: true)
        #expect(try Data(contentsOf: outside.appendingPathComponent("file")) == Data("outside".utf8))
    }

    @Test
    func nestedPathsSurviveRootRelocation() async throws {
        let container = try TestSupport.temporaryDirectory("RelocatedRoot")
        defer { TestSupport.remove(container) }
        let parent = container.appendingPathComponent("parent")
        let root = parent.appendingPathComponent("root")
        let fs = try LocalFileSystem(root: root)
        try await fs.createFile(path: "/top", data: Data([1]))
        try await fs.createFile(path: "/d/f", data: Data([2]))

        let renamed = parent.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: root, to: renamed)
        let movedParent = container.appendingPathComponent("moved-parent")
        // Exercise both root and ancestor relocation on the same pinned fd.
        for moveAncestor in [false, true] {
            if moveAncestor {
                try FileManager.default.moveItem(at: parent, to: movedParent)
            }
            #expect(try await fs.readFile(path: "/top") == Data([1]))
            await #expect(throws: Never.self) {
                let data = try await fs.readFile(path: "/d/f")
                #expect(data == Data([2]))
            }
            await #expect(throws: Never.self) {
                try await fs.writeFile(path: "/d/g", data: Data([3]), append: false)
                #expect(try await fs.readFile(path: "/d/g") == Data([3]))
                try await fs.remove(path: "/d/g", recursive: false)
            }
        }
    }

    @Test
    func realPathsUseCanonicalRoot() async throws {
        let container = try TestSupport.temporaryDirectory("RootAlias")
        defer {
            TestSupport.remove(container)
        }
        let physical = container.appendingPathComponent("physical")
        let original = try LocalFileSystem(root: physical)
        try await original.writeFile(path: "/file", data: Data(), append: false)
        let alias = container.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let fs = try LocalFileSystem(root: alias)
        #expect(try await fs.resolveRealPath(path: "/file") == "/file")
    }

    @Test
    func chunksReadOnlyWhenRequestedAndKeepTheirOpenFile() async throws {
        let root = try TestSupport.temporaryDirectory("DemandChunks")
        defer {
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.writeFile(path: "/file", data: Data("aaaabbbbcccc".utf8), append: false)
        let stream = try await fs.readFileChunks(path: "/file", chunkSize: 4)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data("aaaa".utf8))
        // A paused consumer must not cause subsequent bytes to be read or buffered.
        try await Task.sleep(for: .milliseconds(100))
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("file"))
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data("BBBBCCCC".utf8))
        try handle.close()
        try await fs.move(from: "/file", to: "/old")
        try await fs.writeFile(path: "/file", data: Data("replacement".utf8), append: false)
        #expect(try await iterator.next() == Data("BBBB".utf8))
        #expect(try await iterator.next() == Data("CCCC".utf8))
        #expect(try await iterator.next() == nil)
    }

    @Test
    func overlayResolvesAncestorsBeforeWhiteoutsAndCopyUp() async throws {
        let base = InMemoryFileSystem()
        try await base.createDirectory(path: "/dir", recursive: true)
        try await base.writeFile(path: "/dir/file", data: Data("lower".utf8), append: false)
        try await base.createSymlink(path: "/alias", target: "dir")
        let fs = OverlayFileSystem(over: base)
        try await fs.writeFile(path: "/alias/file", data: Data("upper".utf8), append: false)
        #expect(try await fs.readFile(path: "/dir/file") == Data("upper".utf8))
        #expect(try await base.readFile(path: "/dir/file") == Data("lower".utf8))
        #expect(try await fs.resolveRealPath(path: "/alias/file") == "/dir/file")
        #expect(try await fs.listDirectory(path: "/alias").map(\.name) == ["file"])
        try await fs.remove(path: "/dir", recursive: true)
        await #expect(throws: (any Error).self) {
            _ = try await fs.readFile(path: "/alias/file")
        }
        #expect(!(await fs.exists(path: "/alias/file")))
        await #expect(throws: (any Error).self) {
            _ = try await fs.stat(path: "/alias/file")
        }
        await #expect(throws: (any Error).self) {
            try await fs.createFile(path: "/alias/new", data: Data())
        }
    }

    @Test
    func swappedAncestorCannotReachOutsideForAnyLocalOperation() async throws {
        let container = try TestSupport.temporaryDirectory("SwappedAncestor")
        defer {
            TestSupport.remove(container)
        }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("outside")
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/dir", recursive: false)
        try await fs.writeFile(path: "/source", data: Data("inside".utf8), append: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("dir"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"), withDestinationURL: outside)
        for operation in [
            "read", "range", "chunks", "stat", "list", "write", "append", "create", "mkdir",
            "remove", "moveSource", "moveDestination", "copySource", "copyDestination",
            "chmod", "symlink", "hardSource", "hardDestination",
        ] {
            await #expect(throws: WorkspaceError.self, "operation: \(operation)") {
                switch operation {
                case "read": _ = try await fs.readFile(path: "/dir/file")
                case "range": _ = try await fs.readFile(path: "/dir/file", offset: 0, length: 1)
                case "chunks": _ = try await fs.readFileChunks(path: "/dir/file", chunkSize: 1)
                case "stat": _ = try await fs.stat(path: "/dir/file")
                case "list": _ = try await fs.listDirectory(path: "/dir")
                case "write", "append":
                    try await fs.writeFile(path: "/dir/file", data: Data("bad".utf8), append: operation == "append")
                case "create": try await fs.createFile(path: "/dir/new", data: Data())
                case "mkdir": try await fs.createDirectory(path: "/dir/new/sub", recursive: true)
                case "remove": try await fs.remove(path: "/dir/file", recursive: true)
                case "moveSource": try await fs.move(from: "/dir/file", to: "/leak")
                case "moveDestination": try await fs.move(from: "/source", to: "/dir/leak")
                case "copySource": try await fs.copy(from: "/dir/file", to: "/leak", recursive: true)
                case "copyDestination": try await fs.copy(from: "/source", to: "/dir/leak", recursive: true)
                case "chmod": try await fs.setPermissions(path: "/dir/file", permissions: POSIXPermissions(0o777))
                case "symlink": try await fs.createSymlink(path: "/dir/leak", target: "file")
                case "hardSource": try await fs.createHardLink(path: "/leak", target: "/dir/file")
                default: try await fs.createHardLink(path: "/dir/leak", target: "/source")
                }
            }
        }
        #expect(!(await fs.exists(path: "/dir/file")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["file"])
        #expect(try Data(contentsOf: outside.appendingPathComponent("file")) == Data("secret".utf8))
        #expect(try await fs.readFile(path: "/source") == Data("inside".utf8))
    }

    @Test
    func overlayWhiteoutsBlockDiskAliasesAndRouteEntryMutations() async throws {
        let root = try TestSupport.temporaryDirectory("OverlayAliases")
        defer {
            TestSupport.remove(root)
        }
        let base = try LocalFileSystem(root: root)
        try await base.createDirectory(path: "/dir", recursive: false)
        try await base.writeFile(path: "/dir/file", data: Data("lower".utf8), append: false)
        try await base.createSymlink(path: "/alias", target: "dir")
        let fs = OverlayFileSystem(over: base)
        try await fs.remove(path: "/dir", recursive: true)
        await #expect(throws: (any Error).self) {
            _ = try await fs.readFile(path: "/alias/file")
        }
        #expect(!(await fs.exists(path: "/alias/file")))
        try await fs.createDirectory(path: "/dir", recursive: false)
        #expect(try await fs.listDirectory(path: "/alias").isEmpty)
        try await fs.createFile(path: "/alias/new", data: Data("upper".utf8))
        try await fs.createSymlink(path: "/second", target: "alias")
        try await fs.copy(from: "/second/new", to: "/alias/copied", recursive: false)
        try await fs.move(from: "/alias/copied", to: "/second/moved")
        try await fs.createHardLink(path: "/alias/hard", target: "/second/new")
        try await fs.setPermissions(path: "/second/new", permissions: POSIXPermissions(0o600))
        #expect(try await fs.stat(path: "/dir/new").permissions == POSIXPermissions(0o600))
        #expect(try await fs.readFile(path: "/dir/hard") == Data("upper".utf8))
        #expect(try await fs.resolveRealPath(path: "/second/moved") == "/dir/moved")
        try await fs.remove(path: "/second/moved", recursive: false)
        #expect(!(await fs.exists(path: "/dir/moved")))
        #expect(try await base.readFile(path: "/dir/file") == Data("lower".utf8))
        #expect(try await base.listDirectory(path: "/dir").map(\.name) == ["file"])
    }

    @Test
    func allowRulesStillRequireBothEndpoints() async throws {
        let authorizer = RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.copy, .move, .createHardLink], pathPrefix: "/public", effect: .allow)
        ])
        for operation: PermissionOperation in [.copy, .move, .createHardLink] {
            for (source, destination): (WorkspacePath, WorkspacePath) in [
                ("/public/file", "/private/file"), ("/private/file", "/public/file"),
                ("/publicity/file", "/public/file"),
            ] {
                let decision = await authorizer.authorize(
                    .init(operation: operation, sourcePath: source, destinationPath: destination))
                guard case .deny = decision else {
                    Issue.record("allow rule matched only one endpoint")
                    continue
                }
            }
        }
    }

    @Test
    func localSymlinkWalkingSupportsInternalAliasesAndBoundsLoops() async throws {
        let root = try TestSupport.temporaryDirectory("LocalLinks")
        defer {
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/dir/sub", recursive: true)
        try await fs.writeFile(path: "/dir/file", data: Data("inside".utf8), append: false)
        try await fs.createSymlink(path: "/alias", target: "dir/sub")
        try await fs.createSymlink(path: "/relative", target: "alias/../file")
        try await fs.createSymlink(path: "/absolute", target: root.appendingPathComponent("dir/file").path)
        #expect(try await fs.readFile(path: "/relative") == Data("inside".utf8))
        #expect(try await fs.resolveRealPath(path: "/absolute") == "/dir/file")
        try await fs.createSymlink(path: "/cycle", target: "cycle")
        await #expect(throws: (any Error).self) {
            _ = try await fs.readFile(path: "/cycle")
        }
        try await fs.createSymlink(path: "/prefix", target: root.path + "-other/file")
        await #expect(throws: WorkspaceError.self) {
            _ = try await fs.resolveRealPath(path: "/prefix")
        }
    }

    // Root bypasses access checks, so these cases must run as an ordinary user to prove recovery.
    @Test(.enabled(if: geteuid() != 0, "Root bypasses permission checks"), arguments: [false, true])
    func chmodRestoresInaccessibleEntries(directory: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("ChmodRecovery")
        let entry = root.appendingPathComponent("entry")
        defer {
            _ = chmod(entry.path, 0o755)
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        if directory {
            try await fs.createDirectory(path: "/entry", recursive: false)
        } else {
            try await fs.createFile(path: "/entry", data: Data("content".utf8))
        }
        for mode in [0o000, 0o200] {
            try await fs.setPermissions(path: "/entry", permissions: POSIXPermissions(mode))
            #expect(try await fs.stat(path: "/entry").permissions == POSIXPermissions(mode))
            try await fs.setPermissions(path: "/entry", permissions: POSIXPermissions(0o644))
            #expect(try await fs.stat(path: "/entry").permissions == POSIXPermissions(0o644))
        }
    }

    @Test
    func replacementPreservesExecutableMode() async throws {
        let root = try TestSupport.temporaryDirectory("ReplacementMode")
        defer {
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.createFile(path: "/script", data: Data("old".utf8))
        try await fs.setPermissions(path: "/script", permissions: POSIXPermissions(0o755))
        try await fs.writeFile(path: "/script", data: Data("new".utf8), append: false)
        #expect(try await fs.stat(path: "/script").permissions == POSIXPermissions(0o755))
        #expect(try await fs.readFile(path: "/script") == Data("new".utf8))
    }

    @Test
    func globAuthorizesThePatternWithoutDereferencingMatchesOrDenyingUnusedCWD() async throws {
        let root = try TestSupport.temporaryDirectory("GlobAuthorization")
        defer {
            TestSupport.remove(root)
        }
        let base = try LocalFileSystem(root: root)
        try await base.createDirectory(path: "/public", recursive: false)
        try await base.createDirectory(path: "/private", recursive: false)
        try await base.createFile(path: "/public/file", data: Data())
        try await base.createSymlink(path: "/public/dangling", target: "missing")
        try await base.createSymlink(path: "/public/external", target: root.path + "-outside/file")
        let authorizer = PermissionAuthorizer {
            _ in .allow
        }
        let fs = AuthorizedFileSystem(base: base, authorizer: authorizer)
        let expected: [WorkspacePath] = ["/public/dangling", "/public/external", "/public/file"]
        #expect(try await fs.glob(pattern: "/public/*", currentDirectory: "/private") == expected)
        #expect(await authorizer.auditLog().count == 1)
        let rules = RuleBasedPermissionAuthorizer(rules: [
            .init(operations: [.glob], pathPrefix: "/private", effect: .deny(message: nil)),
            .init(operations: [.glob], pathPrefix: "/", effect: .allow),
        ])
        let ruled = AuthorizedFileSystem(base: base, authorizer: rules)
        #expect(try await ruled.glob(pattern: "/public/*", currentDirectory: "/private") == expected)
        try await base.createSymlink(path: "/public/alias", target: "../private")
        await #expect(throws: WorkspaceError.self) {
            _ = try await ruled.glob(pattern: "/public/alias/*", currentDirectory: "/")
        }
    }

    @Test
    func authorizationPreservesSyntheticMountParents() async throws {
        let leaf = InMemoryFileSystem()
        try await leaf.createFile(path: "/file", data: Data("mounted".utf8))
        let mounted = MountedFileSystem(
            base: InMemoryFileSystem(),
            mounts: [.init(mountPoint: "/a/b", fileSystem: leaf)]
        )
        let fs = AuthorizedFileSystem(
            base: mounted,
            authorizer: PermissionAuthorizer {
                _ in .allow
            })
        #expect(try await fs.listDirectory(path: "/a").map(\.name) == ["b"])
        #expect(await fs.exists(path: "/a"))
        #expect(try await fs.stat(path: "/a").kind == .directory)
        #expect(try await fs.readFile(path: "/a/b/file") == Data("mounted".utf8))
    }

    @Test
    func absoluteSymlinkAcceptsRealpathRootSpelling() async throws {
        let root = try TestSupport.temporaryDirectory("PhysicalRoot")
        defer {
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.createFile(path: "/file", data: Data("physical".utf8))
        let physical = try #require(realpath(root.path, nil))
        defer {
            free(physical)
        }
        try await fs.createSymlink(path: "/link", target: String(cString: physical) + "/file")
        #expect(try await fs.readFile(path: "/link") == Data("physical".utf8))
        #expect(try await fs.resolveRealPath(path: "/link") == "/file")
    }

    // Root can list mode-000 directories and would conceal the traversal regression.
    @Test(.enabled(if: geteuid() != 0, "Root bypasses permission checks"))
    func globSkipsUnreadableSubdirectoriesButReportsUnreadableRoot() async throws {
        let root = try TestSupport.temporaryDirectory("GlobPermissions")
        let locked = root.appendingPathComponent("locked")
        defer {
            _ = chmod(root.path, 0o755)
            _ = chmod(locked.path, 0o755)
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/locked", recursive: false)
        try await fs.createFile(path: "/locked/hidden.txt", data: Data())
        try await fs.createFile(path: "/visible.txt", data: Data())
        #expect(chmod(locked.path, 0o000) == 0)
        #expect(try await fs.glob(pattern: "/**/*.txt", currentDirectory: "/") == ["/visible.txt"])
        #expect(chmod(root.path, 0o000) == 0)
        await #expect(throws: (any Error).self) {
            _ = try await fs.glob(pattern: "/*", currentDirectory: "/")
        }
    }

    // Search-only traversal works with a cached byte-exact policy. Uncached Linux
    // flag inspection or listing verification requires read access.
    @Test(.enabled(if: geteuid() != 0, "Root bypasses permission checks"))
    func localOperationsRespectSearchOnlyAncestorPolicy() async throws {
        let root = try TestSupport.temporaryDirectory("SearchOnly")
        let ancestor = root.appendingPathComponent("ancestor")
        defer {
            _ = chmod(ancestor.path, 0o755)
            TestSupport.remove(root)
        }
        let fs = try LocalFileSystem(root: root)
        try await fs.createDirectory(path: "/ancestor/writable", recursive: true)
        try await fs.createFile(path: "/ancestor/writable/file", data: Data("inside".utf8))
        #expect(chmod(ancestor.path, 0o111) == 0)
        #if canImport(Glibc)
        do {
            _ = try await fs.readFile(path: "/ancestor/writable/file")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES) {
            // FS_IOC_GETFLAGS cannot use O_PATH. If flags are not cached, listing
            // verification must reject mutations too until read access is available.
            await #expect(throws: POSIXError(.EACCES) as NSError) {
                try await fs.createFile(path: "/ancestor/writable/new", data: Data())
            }
            #expect(!FileManager.default.fileExists(atPath: ancestor.path + "/writable/new"))
            #expect(chmod(ancestor.path, 0o755) == 0)
        }
        #endif
        #expect(try await fs.readFile(path: "/ancestor/writable/file") == Data("inside".utf8))
        try await fs.createFile(path: "/ancestor/writable/new", data: Data())
        try await fs.move(from: "/ancestor/writable/new", to: "/ancestor/writable/moved")
        try await fs.remove(path: "/ancestor/writable/moved", recursive: false)
        #expect(try await fs.listDirectory(path: "/ancestor/writable").map(\.name) == ["file"])
        #expect(chmod(ancestor.path, 0o111) == 0)
        await #expect(throws: (any Error).self) {
            _ = try await fs.listDirectory(path: "/ancestor")
        }
    }

    @Test
    func relativeParentSymlinkCannotEscapeRoot() async throws {
        let container = try TestSupport.temporaryDirectory("RelativeEscape")
        defer {
            TestSupport.remove(container)
        }
        let fs = try LocalFileSystem(root: container.appendingPathComponent("root"))
        let outside = try LocalFileSystem(root: container.appendingPathComponent("outside"))
        try await outside.createFile(path: "/file", data: Data("secret".utf8))
        try await fs.createSymlink(path: "/esc", target: "../outside/file")
        do {
            _ = try await fs.readFile(path: "/esc")
            Issue.record("expected relative symlink escape to be rejected")
        } catch let error as WorkspaceError {
            guard case .invalidPath = error else {
                Issue.record("expected invalidPath, received \(error)")
                return
            }
        }
    }

    @Test
    func concurrentMovesNeverReplaceTheWinningDestination() async throws {
        let root = try TestSupport.temporaryDirectory("ExclusiveMove")
        defer { TestSupport.remove(root) }
        let fs = try LocalFileSystem(root: root)
        let sources = (0..<24).map { WorkspacePath.root.appending("source-\($0)") }
        for source in sources {
            try await fs.createFile(path: source, data: Data(source.string.utf8))
        }
        let winners = await withTaskGroup(of: WorkspacePath?.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        try await fs.move(from: source, to: "/destination")
                        return source
                    } catch let error as NSError {
                        #expect(error.domain == NSPOSIXErrorDomain)
                        #expect(error.code == Int(EEXIST))
                        return nil
                    }
                }
            }
            var winners: [WorkspacePath] = []
            for await winner in group {
                if let winner {
                    winners.append(winner)
                }
            }
            return winners
        }
        #expect(winners.count == 1)
        let winner = try #require(winners.first)
        #expect(try await fs.readFile(path: "/destination") == Data(winner.string.utf8))
        for source in sources {
            #expect(await fs.exists(path: source) == (source != winner))
        }
    }

    @Test
    func unsupportedExclusiveRenameFallsBackWithoutReplacingExistingEntries() async throws {
        #if canImport(Darwin)
        let unsupportedErrors = [ENOTSUP, ENOSYS]
        #else
        let unsupportedErrors = [EINVAL, ENOSYS]
        #endif
        for unsupportedError in unsupportedErrors {
            let root = try TestSupport.temporaryDirectory("RenameFallback")
            defer { TestSupport.remove(root) }
            let fs = LocalFileSystem(exclusiveRename: { _, _, _, _ in unsupportedError })
            try fs.applyConfiguration(rootDirectory: root)
            try await fs.createFile(path: "/source", data: Data("source".utf8))
            try await fs.move(from: "/source", to: "/destination")
            #expect(try await fs.readFile(path: "/destination") == Data("source".utf8))
            #expect(!(await fs.exists(path: "/source")))

            try await fs.createFile(path: "/source", data: Data("keep".utf8))
            try await fs.createSymlink(path: "/dangling", target: "missing")
            for destination: WorkspacePath in ["/destination", "/dangling"] {
                do {
                    try await fs.move(from: "/source", to: destination)
                    Issue.record("expected EEXIST for an occupied destination")
                } catch let error as NSError {
                    #expect(error.domain == NSPOSIXErrorDomain)
                    #expect(error.code == Int(EEXIST))
                }
            }
            #expect(try await fs.readFile(path: "/source") == Data("keep".utf8))
            #expect(try await fs.readFile(path: "/destination") == Data("source".utf8))
            #expect(try await fs.readSymlink(path: "/dangling") == "missing")

            try await fs.createDirectory(path: "/directory/child", recursive: true)
            try await fs.move(from: "/directory", to: "/renamed")
            #expect(try await fs.stat(path: "/renamed/child").kind == .directory)
            #expect(!(await fs.exists(path: "/directory")))
            do {
                try await fs.move(from: "/renamed", to: "/renamed/child/invalid")
                Issue.record("expected EINVAL for a directory moved into itself")
            } catch let error as NSError {
                #expect(error.domain == NSPOSIXErrorDomain)
                #expect(error.code == Int(EINVAL))
            }
        }
    }

    @Test
    func exclusiveRenamePermissionFailuresDoNotFallBack() async throws {
        let root = try TestSupport.temporaryDirectory("RenameDenied")
        defer { TestSupport.remove(root) }
        let fs = LocalFileSystem(exclusiveRename: { _, _, _, _ in EACCES })
        try fs.applyConfiguration(rootDirectory: root)
        try await fs.createFile(path: "/source", data: Data("keep".utf8))
        do {
            try await fs.move(from: "/source", to: "/destination")
            Issue.record("expected the exclusive rename error to propagate")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EACCES))
        }
        #expect(try await fs.readFile(path: "/source") == Data("keep".utf8))
        #expect(!(await fs.exists(path: "/destination")))
    }
}
