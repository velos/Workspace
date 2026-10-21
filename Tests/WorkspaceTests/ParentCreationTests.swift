import Foundation
import Testing
@testable import Workspace

@Suite("Implicit parent creation")
struct ParentCreationTests {
    enum Operation: String, CaseIterable, Sendable {
        case replace, append, create, copy, move, symlink, hardLink

        func perform(on fs: any FileSystem, at path: WorkspacePath, source: WorkspacePath = "/source") async throws {
            switch self {
            case .replace, .append: try await fs.writeFile(path: path, data: Data("new".utf8), append: self == .append)
            case .create: try await fs.createFile(path: path, data: Data("new".utf8))
            case .copy: try await fs.copy(from: source, to: path, recursive: true)
            case .move: try await fs.move(from: source, to: path)
            case .symlink: try await fs.createSymlink(path: path, target: "../../source")
            case .hardLink: try await fs.createHardLink(path: path, target: "/source")
            }
        }
    }

    static let cases = Operation.allCases.flatMap { operation in
        ["plain", "alias", "dangling", "leaf", "file", "file alias", "absolute", "missing before dotdot", "escape", "loop", "subtree", "subtree source alias", "subtree destination alias", "missing source subtree"]
            .filter { $0 != "leaf" || [.replace, .append, .create].contains(operation) }
            .filter { $0 != "missing source subtree" || operation == .copy }
            .filter { !$0.hasPrefix("subtree") || [.copy, .move].contains(operation) }
            .map { (operation, $0) }
    }

    // Host creation modes depend on umask. Compare memory defaults after applying the
    // modes observed from Local, retaining explicit permissions and all tree structure.
    private func comparable(_ entry: Snapshot.Entry, diskRoot: String? = nil,
                            directoryMode: POSIXPermissions = .defaultDirectory,
                            fileMode: POSIXPermissions = .defaultFile) -> Snapshot.Entry {
        switch entry {
        case var .directory(directory):
            if !directory.path.isRoot && diskRoot == nil {
                directory.permissions = POSIXPermissions(Int(directory.permissions.rawValue & directoryMode.rawValue))
            }
            directory.children = directory.children.map {
                comparable($0, diskRoot: diskRoot, directoryMode: directoryMode, fileMode: fileMode)
            }
            return .directory(directory)
        case var .symlink(link):
            link.permissions = POSIXPermissions(0o777)
            if let diskRoot, link.target.hasPrefix(diskRoot + "/") {
                link.target = String(link.target.dropFirst(diskRoot.count))
            }
            return .symlink(link)
        case var .file(file):
            if diskRoot == nil && file.path != "/source" && file.path != "/d/f" {
                file.permissions = POSIXPermissions(Int(file.permissions.rawValue & fileMode.rawValue))
            }
            return .file(file)
        default: return entry
        }
    }

    @Test(arguments: ["file", "missing"], ["local", "memory", "overlay", "authorized", "mounted", "limited local"])
    func `hard links preserve the final symlink across backends`(target: String, backend: String) async throws {
        let root = try TestSupport.temporaryDirectory("HardLinkSymlink")
        defer { TestSupport.remove(root) }
        let lower = InMemoryFileSystem()
        let fs: any FileSystem
        switch backend {
        case "local": fs = try LocalFileSystem(root: root)
        case "overlay": fs = OverlayFileSystem(over: lower)
        case "authorized": fs = AuthorizedFileSystem(base: lower, authorizer: PermissionAuthorizer { _ in .allow })
        case "mounted": fs = MountedFileSystem(base: InMemoryFileSystem(), mounts: [.init(mountPoint: "/mount", fileSystem: lower)])
        case "limited local": fs = LimitedFileSystem(base: try LocalFileSystem(root: root), limits: .init(maxTotalBytes: 8))
        default: fs = lower
        }
        let prefix: WorkspacePath = backend == "mounted" ? "/mount" : .root
        let setup: any FileSystem = backend == "overlay" ? lower : fs
        try await setup.createDirectory(path: prefix.appending("source"), recursive: true)
        try await setup.writeFile(path: prefix.appending("source/file"), data: Data("contents".utf8), append: false)
        try await setup.createSymlink(path: prefix.appending("source/link"), target: target)
        try await setup.createSymlink(path: prefix.appending("alias"), target: "source")
        let lowerBefore = try await Snapshot.capture(from: lower)
        let hard = prefix.appending("new/deep/hard")
        try await fs.createHardLink(path: hard, target: prefix.appending("alias/link"))
        let info = try await fs.stat(path: hard)
        #expect(info.kind == .symlink)
        await #expect(throws: (any Error).self) { try await fs.stat(path: prefix.appending("new/deep/HARD")) }
        #expect(try await fs.readSymlink(path: hard) == target)
        #expect(info.identity == (try await fs.stat(path: prefix.appending("source/link"))).identity)
        #expect(try await fs.stat(path: prefix.appending("new/deep")).kind == .directory)
        if backend == "overlay" { #expect(try await Snapshot.capture(from: lower).entry == lowerBefore.entry) }
        if let limited = fs as? LimitedFileSystem {
            try await limited.revalidate()
            await #expect(throws: FileSystemLimitError.self) { try await limited.createFile(path: "/extra", data: Data([1])) }
        }
    }

    @Test(arguments: cases)
    func `creation matches disk including parents permissions and errors`(operation: Operation, route: String) async throws {
        let root = try TestSupport.temporaryDirectory("ParentCreation")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.createDirectory(path: "/mode-probe", recursive: false)
        try await local.createFile(path: "/mode-probe/file", data: Data())
        let directoryMode = try await local.stat(path: "/mode-probe").permissions
        let fileMode = try await local.stat(path: "/mode-probe/file").permissions
        try await local.remove(path: "/mode-probe", recursive: true)
        let diskRoot = root.resolvingSymlinksInPath().path
        let memory = InMemoryFileSystem()
        let lower = InMemoryFileSystem()
        let overlay = OverlayFileSystem(over: lower)
        let backends: [any FileSystem] = [local, memory, overlay]
        for fs in [local as any FileSystem, memory, lower] {
            try await fs.setPermissions(path: "/", permissions: .defaultDirectory)
            try await fs.createDirectory(path: "/existing", recursive: true)
            try await fs.setPermissions(path: "/existing", permissions: POSIXPermissions(0o700))
            try await fs.writeFile(path: "/source", data: Data("source".utf8), append: false)
            try await fs.setPermissions(path: "/source", permissions: .defaultFile)
            try await fs.createSymlink(path: "/alias", target: "existing")
            try await fs.createSymlink(path: "/dangling", target: "new")
            try await fs.createSymlink(path: "/leaf", target: "new/deep/file")
            try await fs.createSymlink(path: "/escape", target: "../outside")
            try await fs.createSymlink(path: "/loop", target: "loop")
            try await fs.createSymlink(path: "/file-alias", target: "source")
            try await fs.createSymlink(path: "/absolute", target: fs is LocalFileSystem ? diskRoot + "/existing" : "/existing")
            try await fs.createSymlink(path: "/dotdot", target: "scratch/../existing")
            try await fs.createFile(path: "/d/f", data: Data("tree".utf8))
            try await fs.setPermissions(path: "/d/f", permissions: .defaultFile)
            try await fs.createSymlink(path: "/d-alias", target: "d")
            try await fs.createSymlink(path: "/source-parent", target: ".")
        }
        let lowerBefore = try await Snapshot.capture(from: lower)
        let path: WorkspacePath = switch route {
        case "alias": "/alias/new/deep/file"
        case "dangling": "/dangling/deep/file"
        case "leaf": "/leaf"
        case "file": "/source/deep/file"
        case "file alias": "/file-alias/deep/file"
        case "absolute": "/absolute/new/deep/file"
        case "missing before dotdot": "/dotdot/new/deep/file"
        case "subtree", "subtree source alias": "/d/new/x"
        case "subtree destination alias": "/d-alias/new/x"
        case "missing source subtree": "/missing/x"
        case "escape": "/escape/deep/file"
        case "loop": "/loop/deep/file"
        default: "/new/deep/file"
        }
        var expectedTree: Snapshot.Entry?
        var expectedError: String?
        for fs in backends {
            var failure: String?
            let before = try await Snapshot.capture(from: fs).entry
            let source: WorkspacePath = route == "missing source subtree" ? "/missing" : route == "subtree source alias" ? "/source-parent/d" : (route.hasPrefix("subtree") ? "/d" : "/source")
            do { try await operation.perform(on: fs, at: path, source: source) }
            catch WorkspaceError.invalidPath { failure = "invalid_path" }
            catch { failure = "\((error as NSError).domain):\((error as NSError).code)" }
            let after = try await Snapshot.capture(from: fs).entry
            if route.hasPrefix("subtree") || route == "missing source subtree" {
                #expect(failure == "\(NSPOSIXErrorDomain):\(EINVAL)")
                #expect(after == before)
            }
            let tree = comparable(after, diskRoot: fs is LocalFileSystem ? diskRoot : nil,
                                  directoryMode: directoryMode,
                                  fileMode: [.copy, .move, .hardLink].contains(operation) ? .defaultFile : fileMode)
            if let expectedTree {
                #expect(tree == expectedTree)
                #expect(failure == expectedError)
            } else {
                expectedTree = tree
                expectedError = failure
                switch route {
                case "file", "file alias": #expect(failure == "\(NSPOSIXErrorDomain):\(ENOTDIR)")
                case "escape": #expect(failure == "invalid_path")
                case "subtree", "subtree source alias", "subtree destination alias", "missing source subtree":
                    #expect(failure == "\(NSPOSIXErrorDomain):\(EINVAL)")
                case "loop": #expect(failure == "\(NSPOSIXErrorDomain):\(ELOOP)")
                case "leaf" where operation != .replace && operation != .append:
                    #expect(failure == "\(NSPOSIXErrorDomain):\(EEXIST)")
                default: #expect(failure == nil)
                }
            }
        }
        #expect(try await Snapshot.capture(from: lower).entry == lowerBefore.entry)
    }

    @Test(arguments: [false, true])
    func `transaction draft creates parents and commits the same tree`(localBackend: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("DraftParents")
        defer { TestSupport.remove(root) }
        let fs: any FileSystem = localBackend ? try LocalFileSystem(root: root) : InMemoryFileSystem()
        let workspace = Workspace(fileSystem: fs)
        let before = try await Snapshot.capture(from: fs)
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/new/deep/file", "draft")
        #expect(try await Snapshot.capture(from: fs).entry == before.entry)
        let commit = try await transaction.commit()
        #expect(commit.applied)
        #expect(try await workspace.readText("/new/deep/file") == "draft")
        let after = try await Snapshot.capture(from: fs)
        #expect(commit.appliedChanges == ChangeSet.compare(before: before, after: after, maxTextBytes: DiffOptions.default.maxTextBytes))
    }

    @Test(arguments: Operation.allCases, ["plain", "dangling", "alias"])
    func `quota charges all implicit parents and retains correct accounting`(operation: Operation, route: String) async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/source", data: Data("source".utf8), append: false)
        let path: WorkspacePath
        switch route {
        case "dangling":
            try await memory.createSymlink(path: "/link", target: "new")
            path = "/link/deep/file"
        case "alias":
            try await memory.createDirectory(path: "/existing", recursive: true)
            try await memory.createSymlink(path: "/link", target: "existing")
            path = "/link/new/deep/file"
        default: path = "/new/deep/file"
        }
        let before = try await Snapshot.capture(from: memory)
        let total = (operation == .move ? 3 : 4) + (route == "alias" ? 2 : (route == "dangling" ? 1 : 0))
        let limited = LimitedFileSystem(base: memory, limits: .init(maxEntryCount: total - 1))
        await #expect(throws: FileSystemLimitError.entryCount(attempted: total, limit: total - 1)) {
            try await operation.perform(on: limited, at: path)
        }
        #expect(try await Snapshot.capture(from: memory).entry == before.entry)
        let enough = LimitedFileSystem(base: memory, limits: .init(maxEntryCount: total))
        try await operation.perform(on: enough, at: path)
        // The retained accounting must also charge those entries on the next mutation.
        await #expect(throws: FileSystemLimitError.entryCount(attempted: total + 1, limit: total)) {
            try await enough.createFile(path: "/extra", data: Data())
        }
        try await enough.revalidate()
        await #expect(throws: FileSystemLimitError.entryCount(attempted: total + 1, limit: total)) {
            try await enough.createFile(path: "/extra", data: Data())
        }
    }
}
