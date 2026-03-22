import Foundation
import Testing
@testable import Workspace

private enum WorkspaceCoverageTestSupport {
    static func makeTempDirectory(prefix: String = "WorkspaceCoverageTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    static func uniqueSuiteName(prefix: String = "WorkspaceCoverageTests") -> String {
        "\(prefix).\(UUID().uuidString)"
    }
}

private actor CoveragePermissionRecorder {
    private(set) var requests: [WorkspacePermissionRequest] = []

    func record(_ request: WorkspacePermissionRequest) {
        requests.append(request)
    }

    func snapshot() -> [WorkspacePermissionRequest] {
        requests
    }
}

@Suite("Workspace Coverage")
struct WorkspaceCoverageTests {
    @Test
    func `read-write filesystem supports round-trip operations`() async throws {
        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceReadWriteRoot")
        defer { WorkspaceCoverageTestSupport.removeDirectory(root) }

        let filesystem = try ReadWriteFilesystem(rootDirectory: root)

        try await filesystem.createDirectory(path: "/docs", recursive: false)
        try await filesystem.writeFile(path: "/docs/note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)
        try await filesystem.writeFile(path: "/docs/note.txt", data: WorkspaceCoverageTestSupport.data(" world"), append: true)

        #expect(try await filesystem.readFile(path: "/docs/note.txt") == WorkspaceCoverageTestSupport.data("hello world"))

        let fileInfo = try await filesystem.stat(path: "/docs/note.txt")
        #expect(fileInfo.size == 11)
        #expect(!fileInfo.isDirectory)

        let directoryEntries = try await filesystem.listDirectory(path: "/docs")
        #expect(directoryEntries.map(\.name) == ["note.txt"])

        try await filesystem.copy(from: "/docs/note.txt", to: "/docs/replaced.txt", recursive: false)
        try await filesystem.writeFile(path: "/docs/replaced.txt", data: WorkspaceCoverageTestSupport.data("stale"), append: false)
        try await filesystem.copy(from: "/docs/note.txt", to: "/docs/replaced.txt", recursive: false)
        #expect(try await filesystem.readFile(path: "/docs/replaced.txt") == WorkspaceCoverageTestSupport.data("hello world"))

        try await filesystem.move(from: "/docs/replaced.txt", to: "/docs/moved.txt")
        #expect(!(await filesystem.exists(path: "/docs/replaced.txt")))
        #expect(await filesystem.exists(path: "/docs/moved.txt"))

        try await filesystem.createSymlink(path: "/docs/link.txt", target: "note.txt")
        #expect(try await filesystem.readSymlink(path: "/docs/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/docs/link.txt") == "/docs/note.txt")

        try await filesystem.createHardLink(path: "/docs/hard.txt", target: "/docs/note.txt")
        #expect(try await filesystem.readFile(path: "/docs/hard.txt") == WorkspaceCoverageTestSupport.data("hello world"))

        try await filesystem.setPermissions(path: "/docs/note.txt", permissions: 0o600)
        let updatedInfo = try await filesystem.stat(path: "/docs/note.txt")
        #expect(updatedInfo.permissions == 0o600)

        try await filesystem.createDirectory(path: "/tree/sub", recursive: true)
        try await filesystem.writeFile(path: "/tree/sub/deep.txt", data: WorkspaceCoverageTestSupport.data("nested"), append: false)
        try await filesystem.copy(from: "/tree", to: "/tree-copy", recursive: true)
        #expect(try await filesystem.readFile(path: "/tree-copy/sub/deep.txt") == WorkspaceCoverageTestSupport.data("nested"))

        let globbed = try await filesystem.glob(pattern: "/docs/*.txt", currentDirectory: "/")
        #expect(globbed.contains("/docs/note.txt"))
        #expect(globbed.contains("/docs/link.txt"))
        #expect(globbed.contains("/docs/hard.txt"))
        #expect(globbed.contains("/docs/moved.txt"))

        try await filesystem.remove(path: "/docs/moved.txt", recursive: false)
        try await filesystem.remove(path: "/tree-copy", recursive: true)

        #expect(!(await filesystem.exists(path: "/docs/moved.txt")))
        #expect(!(await filesystem.exists(path: "/tree-copy")))
        #expect(await filesystem.exists(path: "/"))
    }

    @Test
    func `read-write filesystem covers errors and unconfigured access`() async throws {
        let unconfigured = ReadWriteFilesystem()

        do {
            _ = try await unconfigured.stat(path: "/")
            Issue.record("expected unconfigured filesystem error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("filesystem is not configured"))
        }

        #expect(!(await unconfigured.exists(path: "/\u{0}")))

        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceReadWriteErrors")
        defer { WorkspaceCoverageTestSupport.removeDirectory(root) }

        let filesystem = try ReadWriteFilesystem(rootDirectory: root)
        try await filesystem.createDirectory(path: "/dir", recursive: false)
        try await filesystem.writeFile(path: "/dir/file.txt", data: WorkspaceCoverageTestSupport.data("x"), append: false)

        do {
            _ = try await filesystem.listDirectory(path: "/dir/file.txt")
            Issue.record("expected ENOTDIR")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTDIR))
        }

        do {
            try await filesystem.remove(path: "/dir", recursive: false)
            Issue.record("expected ENOTEMPTY")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTEMPTY))
        }

        do {
            try await filesystem.copy(from: "/dir", to: "/dir-copy", recursive: false)
            Issue.record("expected EISDIR")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        try await filesystem.remove(path: "/missing", recursive: false)
        #expect(try await filesystem.glob(pattern: "/missing.txt", currentDirectory: "/").isEmpty)
    }

    @Test
    func `mountable filesystem merges base and synthetic directories`() async throws {
        let base = InMemoryFilesystem()
        try await base.createDirectory(path: "/docs", recursive: true)
        try await base.writeFile(path: "/docs/local.txt", data: WorkspaceCoverageTestSupport.data("local"), append: false)
        try await base.writeFile(path: "/base.txt", data: WorkspaceCoverageTestSupport.data("base"), append: false)

        let mountedDocs = InMemoryFilesystem()
        try await mountedDocs.writeFile(path: "/guide.txt", data: WorkspaceCoverageTestSupport.data("guide"), append: false)

        let filesystem = MountableFilesystem(
            base: base,
            mounts: [.init(mountPoint: "/docs/external", filesystem: mountedDocs)]
        )

        let docsInfo = try await filesystem.stat(path: "/docs")
        #expect(docsInfo.isDirectory)
        #expect(await filesystem.exists(path: "/docs"))
        #expect(try await filesystem.readFile(path: "/base.txt") == WorkspaceCoverageTestSupport.data("base"))

        let docsEntries = try await filesystem.listDirectory(path: "/docs")
        #expect(docsEntries.map(\.name) == ["external", "local.txt"])

        let mountedEntries = try await filesystem.listDirectory(path: "/docs/external")
        #expect(mountedEntries.map(\.name) == ["guide.txt"])

        try await filesystem.writeFile(path: "/docs/external/new.txt", data: WorkspaceCoverageTestSupport.data("new"), append: false)
        try await filesystem.createDirectory(path: "/docs/external/sub", recursive: true)
        try await filesystem.createSymlink(path: "/docs/external/link.txt", target: "guide.txt")
        try await filesystem.createHardLink(path: "/docs/external/hard.txt", target: "/docs/external/guide.txt")
        try await filesystem.setPermissions(path: "/docs/external/guide.txt", permissions: 0o600)

        #expect(try await filesystem.readSymlink(path: "/docs/external/link.txt") == "guide.txt")
        #expect(try await filesystem.resolveRealPath(path: "/docs/external/link.txt") == "/docs/external/guide.txt")
        #expect(try await mountedDocs.readFile(path: "/new.txt") == WorkspaceCoverageTestSupport.data("new"))
        #expect(try await mountedDocs.readFile(path: "/hard.txt") == WorkspaceCoverageTestSupport.data("guide"))
        #expect(try await mountedDocs.stat(path: "/guide.txt").permissions == 0o600)

        let globbed = try await filesystem.glob(pattern: "/docs/*.txt", currentDirectory: "/")
        #expect(globbed.contains("/docs/local.txt"))
        #expect(globbed.contains("/docs/external/guide.txt"))

        try await filesystem.remove(path: "/docs/external/new.txt", recursive: false)
        #expect(!(await mountedDocs.exists(path: "/new.txt")))

        do {
            _ = try await filesystem.listDirectory(path: "/missing")
            Issue.record("expected missing path error")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOENT))
        }
    }

    @Test
    func `mountable filesystem supports cross-mount directory copy and move`() async throws {
        let source = InMemoryFilesystem()
        try await source.createDirectory(path: "/tree/sub", recursive: true)
        try await source.writeFile(path: "/tree/sub/file.txt", data: WorkspaceCoverageTestSupport.data("nested"), append: false)
        try await source.createSymlink(path: "/tree/link.txt", target: "sub/file.txt")

        let destination = InMemoryFilesystem()
        let filesystem = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                .init(mountPoint: "/src", filesystem: source),
                .init(mountPoint: "/dst", filesystem: destination),
            ]
        )

        do {
            try await filesystem.copy(from: "/src/tree", to: "/dst/tree", recursive: false)
            Issue.record("expected recursive directory copy requirement")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        try await filesystem.copy(from: "/src/tree", to: "/dst/tree", recursive: true)
        #expect(try await destination.readFile(path: "/tree/sub/file.txt") == WorkspaceCoverageTestSupport.data("nested"))
        #expect(try await destination.readSymlink(path: "/tree/link.txt") == "sub/file.txt")

        try await filesystem.move(from: "/src/tree/sub/file.txt", to: "/dst/moved.txt")
        #expect(!(await source.exists(path: "/tree/sub/file.txt")))
        #expect(try await destination.readFile(path: "/moved.txt") == WorkspaceCoverageTestSupport.data("nested"))

        do {
            try await filesystem.createHardLink(path: "/dst/cross-hard.txt", target: "/src/tree/link.txt")
            Issue.record("expected cross-mount hard link rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("hard links across mounts are not supported"))
        }
    }

    @Test
    func `mountable filesystem supports dynamic mounts and base configuration`() async throws {
        let baseRoot = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceMountableBase")
        defer { WorkspaceCoverageTestSupport.removeDirectory(baseRoot) }

        let base = ReadWriteFilesystem()
        let filesystem = MountableFilesystem(base: base)
        try filesystem.configure(rootDirectory: baseRoot)

        let memory = InMemoryFilesystem()
        filesystem.mount("/memory", filesystem: memory)

        try await filesystem.writeFile(path: "/root.txt", data: WorkspaceCoverageTestSupport.data("root"), append: false)
        try await filesystem.writeFile(path: "/memory/note.txt", data: WorkspaceCoverageTestSupport.data("memo"), append: false)

        #expect(try await filesystem.readFile(path: "/root.txt") == WorkspaceCoverageTestSupport.data("root"))
        #expect(try await memory.readFile(path: "/note.txt") == WorkspaceCoverageTestSupport.data("memo"))
    }

    @Test
    func `overlay filesystem imports directories and symlinks and proxies mutations`() async throws {
        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceOverlayCoverage")
        defer { WorkspaceCoverageTestSupport.removeDirectory(root) }

        let dirURL = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let fileURL = dirURL.appendingPathComponent("file.txt")
        try WorkspaceCoverageTestSupport.data("disk").write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fileURL.path)

        let symlinkURL = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "dir/file.txt")

        let filesystem = try OverlayFilesystem(rootDirectory: root)

        #expect((try await filesystem.listDirectory(path: "/")).map(\.name) == ["alias.txt", "dir"])
        #expect((try await filesystem.listDirectory(path: "/dir")).map(\.name) == ["file.txt"])
        #expect(try await filesystem.readFile(path: "/alias.txt") == WorkspaceCoverageTestSupport.data("disk"))
        #expect(try await filesystem.readSymlink(path: "/alias.txt") == "dir/file.txt")
        #expect(try await filesystem.stat(path: "/dir/file.txt").permissions == 0o640)

        try await filesystem.createDirectory(path: "/scratch", recursive: true)
        try await filesystem.writeFile(path: "/scratch/note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)
        try await filesystem.copy(from: "/scratch/note.txt", to: "/scratch/copy.txt", recursive: false)
        try await filesystem.move(from: "/scratch/copy.txt", to: "/scratch/moved.txt")
        try await filesystem.createSymlink(path: "/scratch/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/scratch/hard.txt", target: "/scratch/note.txt")
        try await filesystem.setPermissions(path: "/scratch/note.txt", permissions: 0o600)

        #expect(try await filesystem.readSymlink(path: "/scratch/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/scratch/link.txt") == "/scratch/note.txt")
        #expect(try await filesystem.readFile(path: "/scratch/hard.txt") == WorkspaceCoverageTestSupport.data("hello"))
        #expect((try await filesystem.glob(pattern: "/scratch/*.txt", currentDirectory: "/")).contains("/scratch/moved.txt"))

        try await filesystem.remove(path: "/scratch/moved.txt", recursive: false)
        #expect(!(await filesystem.exists(path: "/scratch/moved.txt")))
    }

    @Test
    func `overlay filesystem reload handles missing and unconfigured roots`() async throws {
        let unconfigured = OverlayFilesystem()

        do {
            try unconfigured.reload()
            Issue.record("expected missing rootDirectory rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("requires rootDirectory"))
        }

        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceOverlayMissingRoot")
        try FileManager.default.removeItem(at: root)

        let filesystem = OverlayFilesystem()
        try filesystem.configure(rootDirectory: root)

        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/missing.txt")))
    }

    @Test
    func `permissioned filesystem covers forwarded operations`() async throws {
        let base = InMemoryFilesystem()
        let recorder = CoveragePermissionRecorder()
        let authorizer = WorkspacePermissionAuthorizer { request in
            await recorder.record(request)
            return .allow
        }
        let filesystem = PermissionedWorkspaceFilesystem(base: base, authorizer: authorizer)

        try await filesystem.writeFile(path: "/dir/../note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/links", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/links/link.txt", target: "../note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")

        _ = try await filesystem.stat(path: "/note.txt")
        _ = try await filesystem.listDirectory(path: "/")
        _ = try await filesystem.readFile(path: "/note.txt")
        _ = try await filesystem.readSymlink(path: "/links/link.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: 0o600)
        _ = try await filesystem.resolveRealPath(path: "/links/link.txt")
        #expect(await filesystem.exists(path: "/note.txt"))
        _ = try await filesystem.glob(pattern: "*.txt", currentDirectory: "/")
        try await filesystem.remove(path: "/hard.txt", recursive: false)

        let requests = await recorder.snapshot()
        #expect(requests.map(\.operation) == [
            .writeFile,
            .createDirectory,
            .copy,
            .move,
            .createSymlink,
            .createHardLink,
            .stat,
            .listDirectory,
            .readFile,
            .readSymlink,
            .setPermissions,
            .resolveRealPath,
            .exists,
            .glob,
            .remove,
        ])

        let symlinkRequest = try #require(requests.first { $0.operation == .createSymlink })
        #expect(symlinkRequest.path == "/links/link.txt")
        #expect(symlinkRequest.destinationPath == "/note.txt")

        let globRequest = try #require(requests.first { $0.operation == .glob })
        #expect(globRequest.path == "/*.txt")
        #expect(globRequest.destinationPath == "/")
    }

    @Test
    func `permissioned filesystem covers configure and denial paths`() async throws {
        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspacePermissionedConfig")
        defer { WorkspaceCoverageTestSupport.removeDirectory(root) }

        let base = ReadWriteFilesystem()
        let filesystem = PermissionedWorkspaceFilesystem(
            base: base,
            authorizer: WorkspacePermissionAuthorizer { request in
                if request.operation == .remove {
                    return .deny(message: nil)
                }
                return .allow
            }
        )

        try filesystem.configure(rootDirectory: root)
        try await filesystem.writeFile(path: "/note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)

        do {
            try await filesystem.remove(path: "/note.txt", recursive: false)
            Issue.record("expected denied remove")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("workspace access denied: remove"))
        }

        let deniedExists = await PermissionedWorkspaceFilesystem(
            base: base,
            authorizer: WorkspacePermissionAuthorizer { _ in .deny(message: "blocked") }
        ).exists(path: "/note.txt")

        #expect(!deniedExists)
        #expect(!(await filesystem.exists(path: "/\u{0}")))
    }

    @Test
    func `sandbox filesystem url root proxies filesystem operations`() async throws {
        let root = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceSandboxURL")
        defer { WorkspaceCoverageTestSupport.removeDirectory(root) }

        let filesystem = try SandboxFilesystem(root: .url(root))

        try await filesystem.writeFile(path: "/note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/dir", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: 0o600)

        #expect(try await filesystem.readFile(path: "/note.txt") == WorkspaceCoverageTestSupport.data("hello"))
        #expect(try await filesystem.readSymlink(path: "/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/link.txt") == "/note.txt")
        #expect(try await filesystem.stat(path: "/note.txt").permissions == 0o600)
        #expect(await filesystem.exists(path: "/hard.txt"))
        #expect((try await filesystem.listDirectory(path: "/")).map(\.name).sorted() == ["dir", "hard.txt", "link.txt", "moved.txt", "note.txt"])
        #expect((try await filesystem.glob(pattern: "/*.txt", currentDirectory: "/")).contains("/moved.txt"))

        try await filesystem.remove(path: "/moved.txt", recursive: false)
        #expect(!(await filesystem.exists(path: "/moved.txt")))
    }

    @Test
    func `sandbox filesystem supports standard roots and rejects invalid app groups`() async throws {
        let temporary = try SandboxFilesystem(root: .temporary)
        #expect(await temporary.exists(path: "/"))

        #if os(macOS)
        let documents = try SandboxFilesystem(root: .documents)
        let caches = try SandboxFilesystem(root: .caches)
        #expect(await documents.exists(path: "/"))
        #expect(await caches.exists(path: "/"))
        #endif

        do {
            _ = try SandboxFilesystem(root: .appGroup("invalid-group"))
            Issue.record("expected invalid app group identifier rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("invalid app group identifier"))
        }

        let firstRoot = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceSandboxFirst")
        defer { WorkspaceCoverageTestSupport.removeDirectory(firstRoot) }

        let secondRoot = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceSandboxSecond")
        defer { WorkspaceCoverageTestSupport.removeDirectory(secondRoot) }

        let filesystem = try SandboxFilesystem(root: .url(firstRoot))
        try filesystem.configure(rootDirectory: secondRoot)
        try await filesystem.writeFile(path: "/configured.txt", data: WorkspaceCoverageTestSupport.data("configured"), append: false)

        #expect(FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("configured.txt").path))
    }

    @Test
    func `user defaults bookmark store round-trips values`() async throws {
        let suiteName = WorkspaceCoverageTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")
        let data = WorkspaceCoverageTestSupport.data("bookmark")

        try await store.saveBookmark(data, for: "demo")
        #expect(try await store.loadBookmark(for: "demo") == data)

        try await store.deleteBookmark(for: "demo")
        #expect(try await store.loadBookmark(for: "demo") == nil)
    }

    #if os(macOS)
    @Test
    func `security-scoped filesystem supports url access and read-only mode`() async throws {
        let firstRoot = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceSecurityScopedFirst")
        defer { WorkspaceCoverageTestSupport.removeDirectory(firstRoot) }

        let secondRoot = try WorkspaceCoverageTestSupport.makeTempDirectory(prefix: "WorkspaceSecurityScopedSecond")
        defer { WorkspaceCoverageTestSupport.removeDirectory(secondRoot) }

        let filesystem = try SecurityScopedFilesystem(url: firstRoot, mode: .readWrite)

        try await filesystem.writeFile(path: "/note.txt", data: WorkspaceCoverageTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/dir", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: 0o600)

        #expect(try await filesystem.readFile(path: "/note.txt") == WorkspaceCoverageTestSupport.data("hello"))
        #expect(try await filesystem.readSymlink(path: "/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/link.txt") == "/note.txt")
        #expect(try await filesystem.stat(path: "/note.txt").permissions == 0o600)
        #expect(await filesystem.exists(path: "/hard.txt"))
        #expect((try await filesystem.listDirectory(path: "/")).map(\.name).sorted() == ["dir", "hard.txt", "link.txt", "moved.txt", "note.txt"])
        #expect((try await filesystem.glob(pattern: "/*.txt", currentDirectory: "/")).contains("/moved.txt"))

        try filesystem.configure(rootDirectory: secondRoot)
        #expect(!(await filesystem.exists(path: "/note.txt")))

        try await filesystem.writeFile(path: "/fresh.txt", data: WorkspaceCoverageTestSupport.data("fresh"), append: false)
        #expect(FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("fresh.txt").path))

        let readOnly = try SecurityScopedFilesystem(url: secondRoot, mode: .readOnly)
        #expect(try await readOnly.readFile(path: "/fresh.txt") == WorkspaceCoverageTestSupport.data("fresh"))

        do {
            try await readOnly.writeFile(path: "/blocked.txt", data: WorkspaceCoverageTestSupport.data("x"), append: false)
            Issue.record("expected read-only rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("read-only"))
        }
    }

    @Test
    func `security-scoped filesystem reports missing bookmarks`() async throws {
        let suiteName = WorkspaceCoverageTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")

        do {
            _ = try await SecurityScopedFilesystem.loadBookmark(id: "missing", store: store)
            Issue.record("expected missing bookmark rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("bookmark not found"))
        }
    }
    #endif
}
