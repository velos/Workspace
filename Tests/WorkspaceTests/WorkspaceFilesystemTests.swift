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
    @Test("permissioned filesystem normalizes paths and blocks denied writes")
    func permissionedFilesystemNormalizesPathsAndBlocksDeniedWrites() async throws {
        let base = InMemoryFilesystem()
        try base.configureForSession()

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

    @Test("permissioned filesystem caches allow-for-session decisions")
    func permissionedFilesystemCachesAllowForSessionDecisions() async throws {
        let base = InMemoryFilesystem()
        try base.configureForSession()
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

    @Test("permissioned mountable filesystem sees mounted virtual paths")
    func permissionedMountableFilesystemSeesMountedVirtualPaths() async throws {
        let docs = InMemoryFilesystem()
        try docs.configureForSession()
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

    @Test("read-write filesystem rejects symlink escapes outside root")
    func readWriteFilesystemRejectsSymlinkEscapesOutsideRoot() async throws {
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
}
