import Foundation
import Testing
@testable import Workspace

private actor PermissionRecorder {
    private(set) var requests: [PermissionRequest] = []

    func record(_ request: PermissionRequest) {
        requests.append(request)
    }

    func snapshot() -> [PermissionRequest] {
        requests
    }
}

private enum FilesystemTestSupport {
    static func makeTempDirectory(prefix: String = "FilesystemTests") throws -> URL {
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

    static func uniqueSuiteName(prefix: String = "FilesystemTests") -> String {
        "\(prefix).\(UUID().uuidString)"
    }
}

private final class NilAppGroupFileManager: FileManager {
    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        nil
    }
}

extension Tag {
    @Tag static var permissions: Self
    @Tag static var readWrite: Self
    @Tag static var inMemory: Self
    @Tag static var overlay: Self
    @Tag static var sandbox: Self
    @Tag static var bookmarks: Self
    @Tag static var securityScoped: Self
    @Tag static var watching: Self
    @Tag static var edits: Self
    @Tag static var replacement: Self
    @Tag static var tree: Self
}

@Suite("Filesystem")
struct FilesystemTests {
    @Test(.tags(.permissions))
    func `permissioned filesystem normalizes paths and blocks denied writes`() async throws {
        let base = InMemoryFilesystem()

        let recorder = PermissionRecorder()
        let authorizer = PermissionAuthorizer { request in
            await recorder.record(request)
            if request.operation == .writeFile {
                return .deny(message: "writes are blocked")
            }
            return .allow
        }
        let filesystem = PermissionedFileSystem(base: base, authorizer: authorizer)

        do {
            try await filesystem.writeFile(path: "/tmp/../note.txt", data: Data("hello".utf8), append: false)
            Issue.record("expected write rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("writes are blocked"))
        }

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/note.txt")
        let exists = await base.exists(path: "/note.txt")
        #expect(!exists)
    }

    @Test(.tags(.permissions))
    func `permissioned filesystem caches allow-for-session decisions`() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/doc.txt", data: Data("hello".utf8), append: false)

        let recorder = PermissionRecorder()
        let authorizer = PermissionAuthorizer { request in
            await recorder.record(request)
            return .allowForSession
        }
        let filesystem = PermissionedFileSystem(base: base, authorizer: authorizer)

        _ = try await filesystem.readFile(path: "/doc.txt")
        _ = try await filesystem.readFile(path: "/doc.txt")

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.operation == .readFile)
    }

    @Test(.tags(.permissions))
    func `permissioned mountable filesystem sees mounted virtual paths`() async throws {
        let docs = InMemoryFilesystem()
        try await docs.writeFile(path: "/guide.txt", data: Data("guide".utf8), append: false)

        let mountable = MountableFilesystem(
            base: InMemoryFilesystem(),
            mounts: [
                MountableFilesystem.Mount(mountPoint: "/docs", filesystem: docs),
            ]
        )

        let recorder = PermissionRecorder()
        let authorizer = PermissionAuthorizer { request in
            await recorder.record(request)
            return .allow
        }
        let filesystem = PermissionedFileSystem(base: mountable, authorizer: authorizer)

        let data = try await filesystem.readFile(path: "/docs/guide.txt")
        #expect(String(decoding: data, as: UTF8.self) == "guide")

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/docs/guide.txt")
    }

    @Test(.tags(.readWrite))
    func `read-write filesystem rejects symlink escapes outside root`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "FilesystemRoot")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let outside = try FilesystemTestSupport.makeTempDirectory(prefix: "FilesystemOutside")
        defer { FilesystemTestSupport.removeDirectory(outside) }

        let outsideFile = outside.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outsideFile)

        let filesystem = try ReadWriteFilesystem(rootDirectory: root)
        try await filesystem.createSymlink(path: "/leak", target: outsideFile.path)

        do {
            _ = try await filesystem.readFile(path: "/leak")
            Issue.record("expected invalid path error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("invalid path"))
        }
    }

    @Test(.tags(.inMemory))
    func `in-memory filesystem reset clears prior contents`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        #expect(await filesystem.exists(path: "/note.txt"))

        await filesystem.reset()

        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/note.txt")))
    }

    @Test(.tags(.overlay))
    func `overlay reload restores source snapshot`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "OverlayRoot")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let fileURL = root.appendingPathComponent("note.txt")
        try Data("disk".utf8).write(to: fileURL)

        let filesystem = try await OverlayFilesystem(rootDirectory: root)
        try await filesystem.writeFile(path: "/note.txt", data: Data("overlay".utf8), append: false)
        #expect(try await filesystem.readFile(path: "/note.txt") == Data("overlay".utf8))

        try Data("disk-updated".utf8).write(to: fileURL)
        try await filesystem.reload()

        #expect(try await filesystem.readFile(path: "/note.txt") == Data("disk-updated".utf8))
    }

    @Test(.tags(.inMemory))
    func `in-memory filesystem handles symlink writes copies moves and configure reset`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/target.txt", data: Data("one".utf8), append: false)
        try await filesystem.createSymlink(path: "/link.txt", target: "target.txt")

        try await filesystem.writeFile(path: "/link.txt", data: Data("two".utf8), append: false)
        #expect(try await filesystem.readFile(path: "/target.txt") == Data("two".utf8))

        try await filesystem.copy(from: "/link.txt", to: "/copied-link.txt", recursive: false)
        #expect(try await filesystem.readSymlink(path: "/copied-link.txt") == "target.txt")

        try await filesystem.createDirectory(path: "/tree/sub", recursive: true)
        try await filesystem.writeFile(path: "/tree/sub/file.txt", data: Data("nested".utf8), append: false)
        try await filesystem.copy(from: "/tree", to: "/tree-copy", recursive: true)
        #expect(try await filesystem.readFile(path: "/tree-copy/sub/file.txt") == Data("nested".utf8))

        try await filesystem.createDirectory(path: "/other", recursive: true)
        try await filesystem.move(from: "/target.txt", to: "/other/moved.txt")
        #expect(!(await filesystem.exists(path: "/target.txt")))
        #expect(try await filesystem.readFile(path: "/other/moved.txt") == Data("two".utf8))

        try await filesystem.configure(rootDirectory: URL(fileURLWithPath: "/ignored"))
        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/other/moved.txt")))
    }

    @Test(.tags(.inMemory))
    func `in-memory filesystem reports POSIX errors for invalid operations`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/file.txt", data: Data("data".utf8), append: false)
        try await filesystem.createDirectory(path: "/dir", recursive: true)
        try await filesystem.writeFile(path: "/dir/child.txt", data: Data("child".utf8), append: false)

        do {
            _ = try await filesystem.readFile(path: "/dir")
            Issue.record("expected EISDIR when reading a directory")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        do {
            _ = try await filesystem.listDirectory(path: "/file.txt")
            Issue.record("expected ENOTDIR when listing a file")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTDIR))
        }

        do {
            try await filesystem.writeFile(path: "/", data: Data(), append: false)
            Issue.record("expected EISDIR when writing root")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        do {
            try await filesystem.createDirectory(path: "/dir", recursive: false)
            Issue.record("expected EEXIST for existing directory")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EEXIST))
        }

        do {
            try await filesystem.createDirectory(path: "/file.txt/nested", recursive: true)
            Issue.record("expected ENOTDIR for file parent")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTDIR))
        }

        do {
            try await filesystem.createDirectory(path: "/missing/nested", recursive: false)
            Issue.record("expected ENOENT for missing intermediate directory")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOENT))
        }

        do {
            try await filesystem.remove(path: "/", recursive: true)
            Issue.record("expected EPERM when removing root")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EPERM))
        }

        do {
            try await filesystem.remove(path: "/dir", recursive: false)
            Issue.record("expected ENOTEMPTY for non-empty directory")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ENOTEMPTY))
        }

        try await filesystem.createDirectory(path: "/tree/sub", recursive: true)
        do {
            try await filesystem.move(from: "/tree", to: "/tree/sub/nested")
            Issue.record("expected EINVAL when moving directory into descendant")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EINVAL))
        }

        do {
            try await filesystem.copy(from: "/tree", to: "/tree-copy", recursive: false)
            Issue.record("expected EISDIR for non-recursive directory copy")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EISDIR))
        }

        do {
            _ = try await filesystem.readSymlink(path: "/file.txt")
            Issue.record("expected EINVAL when reading a non-symlink")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EINVAL))
        }

        do {
            try await filesystem.createHardLink(path: "/dir-link", target: "/dir")
            Issue.record("expected EPERM for directory hard link")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EPERM))
        }
    }

    @Test(.tags(.readWrite))
    func `read-write filesystem supports file metadata links globbing and recursive copies`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "ReadWriteRoot")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let filesystem = try ReadWriteFilesystem(rootDirectory: root)

        try await filesystem.createDirectory(path: "/docs", recursive: false)
        try await filesystem.writeFile(path: "/docs/note.txt", data: FilesystemTestSupport.data("hello"), append: false)
        try await filesystem.writeFile(path: "/docs/note.txt", data: FilesystemTestSupport.data(" world"), append: true)

        #expect(try await filesystem.readFile(path: "/docs/note.txt") == FilesystemTestSupport.data("hello world"))

        let fileInfo = try await filesystem.stat(path: "/docs/note.txt")
        #expect(fileInfo.size == 11)
        #expect(fileInfo.kind == .file)
        let directoryInfo = try await filesystem.stat(path: "/docs")
        #expect(directoryInfo.kind == .directory)

        let directoryEntries = try await filesystem.listDirectory(path: "/docs")
        #expect(directoryEntries.map(\.name) == ["note.txt"])

        try await filesystem.copy(from: "/docs/note.txt", to: "/docs/replaced.txt", recursive: false)
        try await filesystem.writeFile(path: "/docs/replaced.txt", data: FilesystemTestSupport.data("stale"), append: false)
        try await filesystem.copy(from: "/docs/note.txt", to: "/docs/replaced.txt", recursive: false)
        #expect(try await filesystem.readFile(path: "/docs/replaced.txt") == FilesystemTestSupport.data("hello world"))

        try await filesystem.move(from: "/docs/replaced.txt", to: "/docs/moved.txt")
        #expect(!(await filesystem.exists(path: "/docs/replaced.txt")))
        #expect(await filesystem.exists(path: "/docs/moved.txt"))

        try await filesystem.createSymlink(path: "/docs/link.txt", target: "note.txt")
        #expect(try await filesystem.readSymlink(path: "/docs/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/docs/link.txt") == "/docs/note.txt")
        #expect(try await filesystem.stat(path: "/docs/link.txt").kind == .symlink)

        try await filesystem.createHardLink(path: "/docs/hard.txt", target: "/docs/note.txt")
        #expect(try await filesystem.readFile(path: "/docs/hard.txt") == FilesystemTestSupport.data("hello world"))

        try await filesystem.setPermissions(path: "/docs/note.txt", permissions: POSIXPermissions(0o600))
        let updatedInfo = try await filesystem.stat(path: "/docs/note.txt")
        #expect(updatedInfo.permissions == POSIXPermissions(0o600))

        try await filesystem.createDirectory(path: "/tree/sub", recursive: true)
        try await filesystem.writeFile(path: "/tree/sub/deep.txt", data: FilesystemTestSupport.data("nested"), append: false)
        try await filesystem.copy(from: "/tree", to: "/tree-copy", recursive: true)
        #expect(try await filesystem.readFile(path: "/tree-copy/sub/deep.txt") == FilesystemTestSupport.data("nested"))

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

    @Test(.tags(.readWrite))
    func `read-write filesystem reports configuration and directory operation errors`() async throws {
        let unconfigured = ReadWriteFilesystem()

        do {
            _ = try await unconfigured.stat(path: "/")
            Issue.record("expected unconfigured filesystem error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("filesystem is not configured"))
        }

        #expect(!(await unconfigured.exists(path: "/\u{0}")))

        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "ReadWriteErrors")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let filesystem = try ReadWriteFilesystem(rootDirectory: root)
        try await filesystem.createDirectory(path: "/dir", recursive: false)
        try await filesystem.writeFile(path: "/dir/file.txt", data: FilesystemTestSupport.data("x"), append: false)

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

    @Test(.tags(.overlay))
    func `overlay filesystem imports disk state and proxies mutations`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "OverlayCoverage")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let dirURL = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let fileURL = dirURL.appendingPathComponent("file.txt")
        try FilesystemTestSupport.data("disk").write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fileURL.path)

        let symlinkURL = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "dir/file.txt")

        let filesystem = try await OverlayFilesystem(rootDirectory: root)

        #expect((try await filesystem.listDirectory(path: "/")).map(\.name) == ["alias.txt", "dir"])
        #expect((try await filesystem.listDirectory(path: "/dir")).map(\.name) == ["file.txt"])
        #expect(try await filesystem.readFile(path: "/alias.txt") == FilesystemTestSupport.data("disk"))
        #expect(try await filesystem.readSymlink(path: "/alias.txt") == "dir/file.txt")
        #expect(try await filesystem.stat(path: "/dir/file.txt").permissions == POSIXPermissions(0o640))

        try await filesystem.createDirectory(path: "/scratch", recursive: true)
        try await filesystem.writeFile(path: "/scratch/note.txt", data: FilesystemTestSupport.data("hello"), append: false)
        try await filesystem.copy(from: "/scratch/note.txt", to: "/scratch/copy.txt", recursive: false)
        try await filesystem.move(from: "/scratch/copy.txt", to: "/scratch/moved.txt")
        try await filesystem.createSymlink(path: "/scratch/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/scratch/hard.txt", target: "/scratch/note.txt")
        try await filesystem.setPermissions(path: "/scratch/note.txt", permissions: POSIXPermissions(0o600))

        #expect(try await filesystem.readSymlink(path: "/scratch/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/scratch/link.txt") == "/scratch/note.txt")
        #expect(try await filesystem.readFile(path: "/scratch/hard.txt") == FilesystemTestSupport.data("hello"))
        #expect((try await filesystem.glob(pattern: "/scratch/*.txt", currentDirectory: "/")).contains("/scratch/moved.txt"))

        try await filesystem.remove(path: "/scratch/moved.txt", recursive: false)
        #expect(!(await filesystem.exists(path: "/scratch/moved.txt")))
    }

    @Test(.tags(.overlay))
    func `overlay filesystem reload requires a configured root and treats missing roots as empty`() async throws {
        let unconfigured = OverlayFilesystem()

        do {
            try await unconfigured.reload()
            Issue.record("expected missing rootDirectory rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("requires rootDirectory"))
        }

        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "OverlayMissingRoot")
        try FileManager.default.removeItem(at: root)

        let filesystem = OverlayFilesystem()
        try await filesystem.configure(rootDirectory: root)

        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/missing.txt")))
    }

    @Test(.tags(.permissions))
    func `permissioned filesystem forwards filesystem operations and normalized paths`() async throws {
        let base = InMemoryFilesystem()
        let recorder = PermissionRecorder()
        let authorizer = PermissionAuthorizer { request in
            await recorder.record(request)
            return .allow
        }
        let filesystem = PermissionedFileSystem(base: base, authorizer: authorizer)

        try await filesystem.writeFile(path: "/dir/../note.txt", data: FilesystemTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/links", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/links/link.txt", target: "../note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")

        _ = try await filesystem.stat(path: "/note.txt")
        _ = try await filesystem.listDirectory(path: "/")
        _ = try await filesystem.readFile(path: "/note.txt")
        _ = try await filesystem.readSymlink(path: "/links/link.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: POSIXPermissions(0o600))
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

    @Test(.tags(.permissions))
    func `permissioned filesystem forwards configuration and denied remove operations`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "PermissionedConfig")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let base = ReadWriteFilesystem()
        let filesystem = PermissionedFileSystem(
            base: base,
            authorizer: PermissionAuthorizer { request in
                if request.operation == .remove {
                    return .deny(message: nil)
                }
                return .allow
            }
        )

        try await filesystem.configure(rootDirectory: root)
        try await filesystem.writeFile(path: "/note.txt", data: FilesystemTestSupport.data("hello"), append: false)

        do {
            try await filesystem.remove(path: "/note.txt", recursive: false)
            Issue.record("expected denied remove")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("workspace access denied: remove"))
        }

        let deniedExists = await PermissionedFileSystem(
            base: base,
            authorizer: PermissionAuthorizer { _ in .deny(message: "blocked") }
        ).exists(path: "/note.txt")

        #expect(!deniedExists)
        #expect(!(await filesystem.exists(path: "/\u{0}")))
    }

    @Test(.tags(.sandbox))
    func `sandbox filesystem rooted at a URL supports filesystem operations`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "SandboxURL")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let filesystem = try SandboxFilesystem(root: .url(root))

        try await filesystem.writeFile(path: "/note.txt", data: FilesystemTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/dir", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: POSIXPermissions(0o600))

        #expect(try await filesystem.readFile(path: "/note.txt") == FilesystemTestSupport.data("hello"))
        #expect(try await filesystem.readSymlink(path: "/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/link.txt") == "/note.txt")
        #expect(try await filesystem.stat(path: "/note.txt").permissions == POSIXPermissions(0o600))
        #expect(await filesystem.exists(path: "/hard.txt"))
        #expect((try await filesystem.listDirectory(path: "/")).map(\.name).sorted() == ["dir", "hard.txt", "link.txt", "moved.txt", "note.txt"])
        #expect((try await filesystem.glob(pattern: "/*.txt", currentDirectory: "/")).contains("/moved.txt"))

        try await filesystem.remove(path: "/moved.txt", recursive: false)
        #expect(!(await filesystem.exists(path: "/moved.txt")))
    }

    @Test(.tags(.sandbox))
    func `sandbox filesystem supports standard roots configuration and app-group validation`() async throws {
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

        do {
            _ = try SandboxFilesystem(
                root: .appGroup("group.workspace.tests.missing"),
                fileManager: NilAppGroupFileManager()
            )
            Issue.record("expected unavailable app group rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("app group container unavailable"))
        }

        let firstRoot = try FilesystemTestSupport.makeTempDirectory(prefix: "SandboxFirst")
        defer { FilesystemTestSupport.removeDirectory(firstRoot) }

        let secondRoot = try FilesystemTestSupport.makeTempDirectory(prefix: "SandboxSecond")
        defer { FilesystemTestSupport.removeDirectory(secondRoot) }

        let filesystem = try SandboxFilesystem(root: .url(firstRoot))
        try await filesystem.configure(rootDirectory: secondRoot)
        try await filesystem.writeFile(path: "/configured.txt", data: FilesystemTestSupport.data("configured"), append: false)

        #expect(FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("configured.txt").path))
    }

    @Test(.tags(.bookmarks))
    func `user defaults bookmark store persists and deletes suite values`() async throws {
        let suiteName = FilesystemTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")
        let data = FilesystemTestSupport.data("bookmark")

        try await store.saveBookmark(data, for: "demo")
        #expect(try await store.loadBookmark(for: "demo") == data)

        try await store.deleteBookmark(for: "demo")
        #expect(try await store.loadBookmark(for: "demo") == nil)
    }

    @Test(.tags(.bookmarks))
    func `user defaults bookmark store supports standard defaults`() async throws {
        let id = "standard-\(UUID().uuidString)"
        let store = UserDefaultsBookmarkStore(keyPrefix: "workspace.tests.standard.")
        let data = FilesystemTestSupport.data("bookmark")
        defer { UserDefaults.standard.removeObject(forKey: "workspace.tests.standard." + id) }

        try await store.saveBookmark(data, for: id)
        #expect(try await store.loadBookmark(for: id) == data)

        try await store.deleteBookmark(for: id)
        #expect(try await store.loadBookmark(for: id) == nil)
    }

    #if os(macOS)
    @Test(.tags(.securityScoped))
    func `security-scoped filesystem supports url access reconfiguration and read-only mode`() async throws {
        let firstRoot = try FilesystemTestSupport.makeTempDirectory(prefix: "SecurityScopedFirst")
        defer { FilesystemTestSupport.removeDirectory(firstRoot) }

        let secondRoot = try FilesystemTestSupport.makeTempDirectory(prefix: "SecurityScopedSecond")
        defer { FilesystemTestSupport.removeDirectory(secondRoot) }

        let filesystem = try SecurityScopedFilesystem(url: firstRoot, mode: .readWrite)

        try await filesystem.writeFile(path: "/note.txt", data: FilesystemTestSupport.data("hello"), append: false)
        try await filesystem.createDirectory(path: "/dir", recursive: true)
        try await filesystem.copy(from: "/note.txt", to: "/copy.txt", recursive: false)
        try await filesystem.move(from: "/copy.txt", to: "/moved.txt")
        try await filesystem.createSymlink(path: "/link.txt", target: "note.txt")
        try await filesystem.createHardLink(path: "/hard.txt", target: "/note.txt")
        try await filesystem.setPermissions(path: "/note.txt", permissions: POSIXPermissions(0o600))

        #expect(try await filesystem.readFile(path: "/note.txt") == FilesystemTestSupport.data("hello"))
        #expect(try await filesystem.readSymlink(path: "/link.txt") == "note.txt")
        #expect(try await filesystem.resolveRealPath(path: "/link.txt") == "/note.txt")
        #expect(try await filesystem.stat(path: "/note.txt").permissions == POSIXPermissions(0o600))
        #expect(await filesystem.exists(path: "/hard.txt"))
        #expect((try await filesystem.listDirectory(path: "/")).map(\.name).sorted() == ["dir", "hard.txt", "link.txt", "moved.txt", "note.txt"])
        #expect((try await filesystem.glob(pattern: "/*.txt", currentDirectory: "/")).contains("/moved.txt"))

        try await filesystem.remove(path: "/moved.txt", recursive: false)
        #expect(!(await filesystem.exists(path: "/moved.txt")))

        try await filesystem.configure(rootDirectory: secondRoot)
        #expect(!(await filesystem.exists(path: "/note.txt")))

        try await filesystem.writeFile(path: "/fresh.txt", data: FilesystemTestSupport.data("fresh"), append: false)
        #expect(FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("fresh.txt").path))

        let readOnly = try SecurityScopedFilesystem(url: secondRoot, mode: .readOnly)
        #expect(try await readOnly.readFile(path: "/fresh.txt") == FilesystemTestSupport.data("fresh"))

        do {
            try await readOnly.writeFile(path: "/blocked.txt", data: FilesystemTestSupport.data("x"), append: false)
            Issue.record("expected read-only rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("read-only"))
        }
    }

    @Test(.tags(.securityScoped, .bookmarks))
    func `security-scoped filesystem reports missing stored bookmarks`() async throws {
        let suiteName = FilesystemTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")

        do {
            _ = try await SecurityScopedFilesystem.loadBookmark(id: "missing", store: store)
            Issue.record("expected missing bookmark rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("bookmark not found"))
        }
    }

    @Test(.tags(.securityScoped, .bookmarks))
    func `security-scoped filesystem rejects invalid stored bookmark data`() async throws {
        let suiteName = FilesystemTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")
        try await store.saveBookmark(FilesystemTestSupport.data("not-a-bookmark"), for: "invalid")

        do {
            _ = try await SecurityScopedFilesystem.loadBookmark(id: "invalid", store: store)
            Issue.record("expected invalid bookmark rejection")
        } catch let error as NSError {
            #expect(error.domain == NSCocoaErrorDomain)
        } catch {
            Issue.record("expected Cocoa bookmark error")
        }
    }

    @Test(.tags(.securityScoped, .bookmarks))
    func `security-scoped filesystem bookmark creation either saves or reports Cocoa errors`() async throws {
        let root = try FilesystemTestSupport.makeTempDirectory(prefix: "SecurityScopedBookmark")
        defer { FilesystemTestSupport.removeDirectory(root) }

        let suiteName = FilesystemTestSupport.uniqueSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

        let filesystem = try SecurityScopedFilesystem(url: root, mode: .readWrite)
        let store = UserDefaultsBookmarkStore(suiteName: suiteName, keyPrefix: "workspace.tests.")

        do {
            let bookmarkData = try filesystem.makeBookmarkData()
            #expect(!bookmarkData.isEmpty)

            try await filesystem.saveBookmark(id: "demo", store: store)
            #expect(try await store.loadBookmark(for: "demo") == bookmarkData)
        } catch let error as NSError {
            #expect(error.domain == NSCocoaErrorDomain)
        }
    }
    #endif
}
