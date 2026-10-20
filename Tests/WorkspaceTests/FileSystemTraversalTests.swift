import Foundation
import Testing
@testable import Workspace
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct FileSystemTraversalTests {
    @Test
    func mountedWalkRebasesPathsAndPreservesShadowing() async throws {
        let root = try TestSupport.temporaryDirectory("MountedWalk")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/base", data: Data("base".utf8), append: false)
        try await local.writeFile(path: "/mount/hidden", data: Data("hidden".utf8), append: false)
        let counted = HookableFileSystem(base: local, scopedWalk: true)
        let mounted = MountedFileSystem(base: counted, mounts: [
            .init(mountPoint: "/mount", fileSystem: InMemoryFileSystem()),
            .init(mountPoint: "/synthetic/deep", fileSystem: counted),
        ])
        try await mounted.writeFile(path: "/mount/visible", data: Data("visible".utf8), append: false)
        let snapshot = try await Snapshot.capture(from: mounted)
        #expect(await counted.walks.contains(.root))
        #expect(!(await counted.walks.contains("/mount")))
        let reference = try await Snapshot.capture(from: HookableFileSystem(base: mounted))
        #expect(snapshot.entry == reference.entry)
        let metadata = try await MetadataIndex.capture(from: mounted)
        #expect(metadata.entries["/mount/hidden"] == nil)
        #expect(metadata.entries["/mount/visible"]?.info.kind == .file)
        #expect(metadata.entries["/synthetic/deep/mount/hidden"]?.info.kind == .file)
    }

    @Test
    func deepCaptureBoundsDescriptors() async throws {
        // Resource limits are process-wide. Re-execute only this test in a child so
        // the reduced limit cannot interfere with Swift Testing's parallel suites.
        let flag = "WORKSPACE_DEEP_CAPTURE_CHILD"
        if ProcessInfo.processInfo.environment[flag] != "1" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            #if os(macOS)
            let bundle = try #require(Bundle(for: TraversalTestBundle.self).executableURL)
            process.arguments = ["--test-bundle-path", bundle.path,
                                 "--testing-library", "swift-testing", "--filter", "deepCaptureBoundsDescriptors"]
            #else
            process.arguments = ["--testing-library", "swift-testing", "--filter", "deepCaptureBoundsDescriptors"]
            #endif
            var environment = ProcessInfo.processInfo.environment
            environment[flag] = "1"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: data, as: UTF8.self)
            #expect(process.terminationStatus == 0, Comment(rawValue: message))
            #expect(message.contains("DeepTreeLimitChecked"), Comment(rawValue: message))
            return
        }
        #if canImport(Darwin)
        let resource = RLIMIT_NOFILE
        #else
        let resource = Int32(RLIMIT_NOFILE.rawValue)
        #endif
        var original = rlimit()
        try #require(getrlimit(resource, &original) == 0)
        var reduced = original
        reduced.rlim_cur = min(original.rlim_cur, 256)
        try #require(setrlimit(resource, &reduced) == 0)
        defer { #expect(setrlimit(resource, &original) == 0) }
        let root = try TestSupport.temporaryDirectory("DeepWalk")
        defer { TestSupport.remove(root) }
        let path = WorkspacePath(normalizing: String(repeating: "/d", count: 300) + "/leaf")
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: path, data: Data("leaf".utf8), append: false)
        let captured = try await Snapshot.capture(from: local)
        let reference = try await Snapshot.capture(from: HookableFileSystem(base: local))
        #expect(captured.entry == reference.entry)
        var visited = false
        try await local.walk { info, read, _ in
            if info.path == path {
                visited = true
                // Some host sandboxes do not enforce the child's soft limit.
                // Independently check that most of the 256-slot budget
                // remains available rather than accepting a false-positive EMFILE test.
                let openCount = (Int32(0)..<1_024).filter { fcntl($0, F_GETFD) >= 0 }.count
                #expect(openCount < 64)
                // Leave meaningful headroom for other filesystem users while suspended
                // in the deepest visit, not merely enough to finish this particular walk.
                var descriptors: [Int32] = []
                defer { for fd in descriptors { close(fd) } }
                for _ in 0..<100 {
                    let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
                    try #require(fd >= 0)
                    descriptors.append(fd)
                }
                #expect(try await read(nil) == Data("leaf".utf8))
            }
        }
        #expect(visited)
        print("DeepTreeLimitChecked")
    }

    @Test(arguments: [false, true])
    func missingChildAtDescriptorFallbackHonorsWalkOption(skipVanished: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("WalkVanishedAtCap")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let parent = WorkspacePath(normalizing: String(repeating: "/d", count: 31))
        let first = parent.appending("a"), vanished = parent.appending("b")
        try await local.createFile(path: first, data: Data([1]))
        try await local.createFile(path: vanished, data: Data([2]))
        var visited: [WorkspacePath] = []
        do {
            try await local.walk(skippingVanishedEntries: skipVanished) { info, read, _ in
                visited.append(info.path)
                if info.path == first {
                    #expect(try await read(nil) == Data([1]))
                    // Both siblings have already been enumerated/lstat'ed. The
                    // depth-32 handoff must tolerate a now-missing child lstat.
                    try await local.remove(path: vanished, recursive: false)
                }
            }
            #expect(skipVanished)
        } catch {
            #expect(!skipVanished)
            #expect((error as NSError).code == Int(ENOENT))
        }
        #expect(visited.contains(first))
        #expect(!visited.contains(vanished))
    }

    @Test
    func captureParityIncludesLinksModesAndSubtreeSpelling() async throws {
        let container = try TestSupport.temporaryDirectory("WalkParity")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("secret")
        try Data("outside".utf8).write(to: outside)
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/dir/empty", recursive: true)
        try await local.writeFile(path: "/dir/file", data: Data([0, 1, 255]), append: false)
        try await local.setPermissions(path: "/dir/file", permissions: POSIXPermissions(0o640))
        try await local.setPermissions(path: "/dir", permissions: POSIXPermissions(0o750))
        try await local.createHardLink(path: "/hard", target: "/dir/file")
        for (name, target) in [("dangling", "missing"), ("cycle", "cycle"), ("alias", "dir"),
                               ("escape", outside.path)] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path,
                                                       withDestinationPath: target)
        }
        // A plain forwarding test backend deliberately keeps the per-path reference walk.
        let perPath = HookableFileSystem(base: local)
        for path: WorkspacePath in [.root, "/dir", "/dir/file", "/dangling", "/cycle", "/escape", "/absent", "/alias/empty"] {
            let bulk = try await Snapshot.capture(from: local, at: path)
            let reference = try await Snapshot.capture(from: perPath, at: path)
            #expect(bulk.entry == reference.entry)
            #expect(bulk.entry.path == path)
        }
        var infos: [WorkspacePath: FileInfo] = [:]
        var reads: [WorkspacePath: Data] = [:]
        #if DEBUG
        let spellingChecks = local.spellingCheckCount
        #endif
        try await local.walk { info, read, readLink in
            infos[info.path] = info
            if info.kind == .file { reads[info.path] = try await read(nil) }
            if info.kind == .symlink { _ = try await readLink() }
        }
        #if DEBUG
        // Readdir supplies stored names for files and directories alike. A root
        // scan must not add a spelling lookup for each visited entry or read.
        #expect(local.spellingCheckCount == spellingChecks)
        #endif
        #expect(Set(reads.keys) == ["/dir/file", "/hard"])
        #expect(reads["/hard"] == Data([0, 1, 255]))
        #expect(infos["/hard"]?.identity == infos["/dir/file"]?.identity)
        #expect(infos["/hard"]?.linkCount == 2)
        #expect(infos["/dir/file"]?.permissions == POSIXPermissions(0o640))
        #expect(infos["/dir"]?.permissions == POSIXPermissions(0o750))
    }

    @Test
    func combiningMarksCannotHidePathSeparatorsOrAuthorizationBoundaries() async throws {
        let root = try TestSupport.temporaryDirectory("WalkUnicode")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let name = "\u{0301}file"
        let rootPath = try WorkspacePath(name)
        #expect(rootPath.string == "/" + name)
        #expect(rootPath.name == name)
        #expect(rootPath.parent == .root)
        try #require(rootPath.components == [name])
        let path = try WorkspacePath("/private/" + name)
        try await local.writeFile(path: path, data: Data("inside".utf8), append: false)
        try await local.writeFile(path: rootPath, data: Data("root file".utf8), append: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
            withDestinationURL: root.appendingPathComponent("private").appendingPathComponent(name))
        #expect(try await local.readFile(path: "/alias") == Data("inside".utf8))
        #expect(try await Snapshot.capture(from: local).entry == Snapshot.capture(from: HookableFileSystem(base: local)).entry)
        let authorized = AuthorizedFileSystem(base: local, authorizer: RuleBasedPermissionAuthorizer(
            rules: [.init(operations: [.readFile], pathPrefix: "/private", effect: .deny(message: "private"))],
            defaultEffect: .allow))
        await #expect(throws: WorkspaceError.self) { _ = try await authorized.readFile(path: path) }
        let canonicalRules = RuleBasedPermissionAuthorizer(
            rules: [.init(operations: [.readFile], pathPrefix: "/caf\u{00e9}", effect: .deny(message: nil))],
            defaultEffect: .allow)
        let decision = await canonicalRules.authorize(.init(operation: .readFile, path: "/cafe\u{0301}/child"))
        guard case .allow = decision else {
            Issue.record("component prefixes must retain exact UTF-8 identity")
            return
        }
    }

    @Test
    func combiningMarkAncestorSwapCannotEscapeRoot() async throws {
        let container = try TestSupport.temporaryDirectory("UnicodeAncestorSwap")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("outside")
        let local = try LocalFileSystem(root: root)
        let name = "\u{0301}file"
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside secret".utf8).write(to: outside.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("private"), withDestinationURL: outside)
        let path = try WorkspacePath("/private/" + name)
        await #expect(throws: WorkspaceError.self) { _ = try await local.readFile(path: path) }
    }

    @Test
    func scopedReadsRespectBoundsAndReadGrowthBeyondEnumeratedSize() async throws {
        let root = try TestSupport.temporaryDirectory("WalkReadBounds")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createFile(path: "/file", data: Data([1]))
        let content = Data((0..<131_079).map { UInt8(truncatingIfNeeded: $0) })
        var visited = false
        try await local.walk { info, read, _ in
            guard info.path == "/file" else { return }
            visited = true
            #expect(info.size == 1)
            // Grow after enumeration; a read must not treat the old size as EOF.
            try content.write(to: root.appendingPathComponent("file"))
            for length: Int? in [0, 1, 4096, 65_536, 200_000, nil] {
                let result = try await read(length)
                #expect(result == Data(content.prefix(length ?? content.count)))
            }
        }
        #expect(visited)
        for offset: UInt64 in [0, 1, 4_096, 65_535, UInt64(content.count - 1), UInt64(content.count), .max] {
            for length: Int? in [0, 17, nil] {
                let remainder = content.dropFirst(min(content.count, Int(clamping: offset)))
                let expected = Data(remainder.prefix(length ?? remainder.count))
                #expect(try await local.readFile(path: "/file", offset: offset, length: length) == expected)
            }
        }
    }

    @Test
    func unreadableDirectoryFailsCaptureButGlobRetainsItsEntry() async throws {
        guard geteuid() != 0 else { return } // root bypasses discretionary mode bits on Linux.
        let root = try TestSupport.temporaryDirectory("WalkPermissions")
        let blocked = root.appendingPathComponent("blocked")
        defer { _ = chmod(blocked.path, 0o755); TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/blocked/child", data: Data(), append: false)
        #expect(chmod(blocked.path, 0) == 0)
        for fs: any FileSystem in [local, HookableFileSystem(base: local)] {
            do {
                _ = try await Snapshot.capture(from: fs)
                Issue.record("capture must fail when a directory cannot be enumerated")
            } catch {
                let error = error as NSError
                #expect(error.domain == NSPOSIXErrorDomain && error.code == Int(EACCES))
            }
        }
        #expect(try await local.glob(pattern: "**/*", currentDirectory: .root) == [.root, "/blocked"])
    }

    @Test
    func walkPinsAncestorAndNextOperationResolvesAgain() async throws {
        let container = try TestSupport.temporaryDirectory("WalkSwap")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("outside")
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/dir/a", data: Data("inside-a".utf8), append: false)
        try await local.writeFile(path: "/dir/b", data: Data("inside-b".utf8), append: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("b"))
        var readValues: [String] = []
        try await local.walk { info, read, _ in
            if info.path == "/dir/a" {
                try FileManager.default.moveItem(at: root.appendingPathComponent("dir"),
                                                to: container.appendingPathComponent("relocated"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"),
                                                          withDestinationURL: outside)
            }
            if info.kind == .file { readValues.append(String(decoding: try await read(nil), as: UTF8.self)) }
        }
        #expect(readValues == ["inside-a", "inside-b"])
        await #expect(throws: WorkspaceError.self) {
            try await local.writeFile(path: "/dir/b", data: Data("bad".utf8), append: false)
        }
        #expect(try Data(contentsOf: outside.appendingPathComponent("b")) == Data("secret".utf8))
        #expect(try Data(contentsOf: container.appendingPathComponent("relocated/b")) == Data("inside-b".utf8))
    }

    @Test(arguments: [false, true], ["external", "internal", "missing"])
    func substitutionsBeforeOpenNeverFollowLinks(directory: Bool, replacement: String) async throws {
        let container = try TestSupport.temporaryDirectory("WalkPendingSwap")
        defer { TestSupport.remove(container) }
        let root = container.appendingPathComponent("root")
        let outside = replacement == "internal" ? root.appendingPathComponent("zz-target")
            : container.appendingPathComponent("outside")
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/a", data: Data("first".utf8), append: false)
        try await local.writeFile(path: directory ? "/z/file" : "/z", data: Data("inside".utf8), append: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("file"))
        var readValues: [String] = []
        do {
            try await local.walk { info, read, _ in
                if info.path == "/a" {
                    try FileManager.default.removeItem(at: root.appendingPathComponent("z"))
                    if replacement != "missing" {
                        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("z"),
                            withDestinationURL: directory ? outside : outside.appendingPathComponent("file"))
                    }
                }
                if info.kind == .file { readValues.append(String(decoding: try await read(nil), as: UTF8.self)) }
            }
            Issue.record("a no-follow open must reject the substituted entry")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect((replacement == "missing" ? [Int(ENOENT)] : [Int(ELOOP), Int(ENOTDIR)]).contains(error.code))
        }
        #expect(readValues == ["first"])
    }

    @Test(arguments: [PermissionOperation.stat, .listDirectory, .readFile, .readSymlink])
    func wrappersCannotBypassPerEntryAuthorization(operation: PermissionOperation) async throws {
        let root = try TestSupport.temporaryDirectory("WalkAuthorization")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/private/file", data: Data("secret".utf8), append: false)
        try await local.createSymlink(path: "/private/link", target: "file")
        let authorized = AuthorizedFileSystem(base: local, authorizer: PermissionAuthorizer { request in
            if request.operation == operation, request.path?.string.hasPrefix("/private") == true {
                return .deny(message: "per-entry denial")
            }
            return .allow
        })
        let wrapped = LimitedFileSystem(base: authorized, limits: .init())
        do {
            try await wrapped.walk { info, read, readLink in
                if info.kind == .file { _ = try await read(nil) }
                if info.kind == .symlink { _ = try await readLink() }
            }
            Issue.record("walk must enforce the denied per-entry operation")
        } catch let WorkspaceError.accessDenied(actual, message) {
            #expect(actual == operation.rawValue)
            #expect(message == "per-entry denial")
        }
    }

    @Test
    func emptySearchSelectionDoesNotOpenTheRootDirectory() async throws {
        guard geteuid() != 0 else { return }
        let root = try TestSupport.temporaryDirectory("EmptySearch")
        let local = try LocalFileSystem(root: root)
        defer { _ = chmod(root.path, 0o755); TestSupport.remove(root) }
        #expect(chmod(root.path, 0o111) == 0)
        let result = try await Workspace.search(.init(pattern: .literal("needle"),
            files: .init(include: [])), on: local)
        #expect(result.matches.isEmpty)
        #expect(result.searchedFileCount == 0)
        #expect(result.truncation == nil)
    }

    @Test
    func searchPreservesPathOrderingLimitsAndLiteralAliases() async throws {
        let root = try TestSupport.temporaryDirectory("WalkSearch")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        for path: WorkspacePath in ["/a/file", "/a.txt", "/a-/file", "/a0", "/é", "/excluded/file"] {
            try await local.writeFile(path: path, data: Data("match\nmatch".utf8), append: false)
        }
        try await local.createSymlink(path: "/alias", target: "a")
        try await local.writeFile(path: "/0binary", data: Data([0, 1]), append: false)
        try await local.writeFile(path: "/0large", data: Data(repeating: 65, count: 101), append: false)
        let selections = [FileSelection(exclude: ["excluded/**"]), FileSelection(include: ["alias/file"])]
        for selection in selections {
            let request = SearchRequest(pattern: .literal("match", caseSensitive: true), files: selection,
                limits: .init(maxFileBytes: 100, maxFiles: 3, maxMatches: 2), matchOffset: 1)
            let fast = try await Workspace.search(request, on: local)
            let fallback = try await Workspace.search(request, on: HookableFileSystem(base: local))
            #expect(fast == fallback)
            #expect(fast.totalMatches > 0)
            if selection.include != ["alias/file"] {
                #expect(fast.skippedFiles.map(\.reason) == [.binary, .sizeLimitExceeded])
            }
        }
    }
}

private final class TraversalTestBundle: NSObject {}
