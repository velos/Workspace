import Foundation
import Testing
@testable import Workspace

private actor PermissionRecorder {
    private(set) var requests: [WorkspacePermissionRequest] = []

    func record(_ request: WorkspacePermissionRequest) {
        requests.append(request)
    }

    func snapshot() -> [WorkspacePermissionRequest] {
        requests
    }
}

private enum WorkspaceFilesystemTestSupport {
    static func makeTempDirectory(prefix: String = "WorkspaceFilesystemTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Workspace Filesystem")
struct WorkspaceFilesystemTests {
    @Test
    func `permissioned filesystem normalizes paths and blocks denied writes`() async throws {
        let base = InMemoryFilesystem()

        let recorder = PermissionRecorder()
        let authorizer = WorkspacePermissionAuthorizer { request in
            await recorder.record(request)
            if request.operation == .writeFile {
                return .deny(message: "writes are blocked")
            }
            return .allow
        }
        let filesystem = PermissionedWorkspaceFilesystem(base: base, authorizer: authorizer)

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

    @Test
    func `permissioned filesystem caches allow-for-session decisions`() async throws {
        let base = InMemoryFilesystem()
        try await base.writeFile(path: "/doc.txt", data: Data("hello".utf8), append: false)

        let recorder = PermissionRecorder()
        let authorizer = WorkspacePermissionAuthorizer { request in
            await recorder.record(request)
            return .allowForSession
        }
        let filesystem = PermissionedWorkspaceFilesystem(base: base, authorizer: authorizer)

        _ = try await filesystem.readFile(path: "/doc.txt")
        _ = try await filesystem.readFile(path: "/doc.txt")

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.operation == .readFile)
    }

    @Test
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
        let authorizer = WorkspacePermissionAuthorizer { request in
            await recorder.record(request)
            return .allow
        }
        let filesystem = PermissionedWorkspaceFilesystem(base: mountable, authorizer: authorizer)

        let data = try await filesystem.readFile(path: "/docs/guide.txt")
        #expect(String(decoding: data, as: UTF8.self) == "guide")

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/docs/guide.txt")
    }

    @Test
    func `read-write filesystem rejects symlink escapes outside root`() async throws {
        let root = try WorkspaceFilesystemTestSupport.makeTempDirectory(prefix: "WorkspaceFilesystemRoot")
        defer { WorkspaceFilesystemTestSupport.removeDirectory(root) }

        let outside = try WorkspaceFilesystemTestSupport.makeTempDirectory(prefix: "WorkspaceFilesystemOutside")
        defer { WorkspaceFilesystemTestSupport.removeDirectory(outside) }

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

    @Test
    func `in-memory filesystem reset clears prior contents`() async throws {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        #expect(await filesystem.exists(path: "/note.txt"))

        filesystem.reset()

        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/note.txt")))
    }

    @Test
    func `overlay reload restores source snapshot`() async throws {
        let root = try WorkspaceFilesystemTestSupport.makeTempDirectory(prefix: "WorkspaceOverlayRoot")
        defer { WorkspaceFilesystemTestSupport.removeDirectory(root) }

        let fileURL = root.appendingPathComponent("note.txt")
        try Data("disk".utf8).write(to: fileURL)

        let filesystem = try OverlayFilesystem(rootDirectory: root)
        try await filesystem.writeFile(path: "/note.txt", data: Data("overlay".utf8), append: false)
        #expect(try await filesystem.readFile(path: "/note.txt") == Data("overlay".utf8))

        try Data("disk-updated".utf8).write(to: fileURL)
        try filesystem.reload()

        #expect(try await filesystem.readFile(path: "/note.txt") == Data("disk-updated".utf8))
    }

    @Test
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

        try filesystem.configure(rootDirectory: URL(fileURLWithPath: "/ignored"))
        #expect(await filesystem.exists(path: "/"))
        #expect(!(await filesystem.exists(path: "/other/moved.txt")))
    }

    @Test
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
}
