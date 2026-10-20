import Foundation
import Testing
@testable import Workspace

struct InMemoryTraversalTests {
    @Test(arguments: [false, true])
    func nativeWalkMatchesPerPathCaptureAndMetadata(skipUnreadable: Bool) async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(path: "/a/empty", recursive: true)
        for path: WorkspacePath in ["/a/file", "/a.txt", "/a0", "/é", "/e\u{301}"] {
            try await fs.writeFile(path: path, data: Data([0, 1, 255]), append: false)
        }
        try await fs.setPermissions(path: "/a/file", permissions: POSIXPermissions(0o100))
        try await fs.setPermissions(path: "/a", permissions: POSIXPermissions(0o000))
        try await fs.createHardLink(path: "/hard", target: "/a/file")
        for (name, target) in [("dangling", "missing"), ("cycle", "cycle"), ("alias", "a"), ("absolute", "/absent")] {
            try await fs.createSymlink(path: WorkspacePath("/" + name), target: target)
        }
        let fallback = HookableFileSystem(base: fs)
        for path: WorkspacePath in [.root, "/a", "/a/file", "/alias/empty", "/dangling", "/cycle", "/absolute", "/absent"] {
            var nativeMetadata: MetadataIndex? = MetadataIndex()
            var fallbackMetadata: MetadataIndex? = MetadataIndex()
            let native = try await Snapshot.capture(from: fs, at: path, metadata: &nativeMetadata)
            let reference = try await Snapshot.capture(from: fallback, at: path, metadata: &fallbackMetadata)
            #expect(native.entry == reference.entry)
            #expect(nativeMetadata?.entries == fallbackMetadata?.entries)
            var nativeInfos: [FileInfo] = []
            var fallbackInfos: [FileInfo] = []
            var nativeBytes: [Data] = []
            var fallbackBytes: [Data] = []
            var nativeLinks: [String] = []
            var fallbackLinks: [String] = []
            for bulk in [true, false] {
                let backend: any FileSystem = bulk ? fs : fallback
                try await backend.walk(at: path, skippingUnreadableDirectories: skipUnreadable) { info, read, readLink in
                    if bulk { nativeInfos.append(info) } else { fallbackInfos.append(info) }
                    if info.kind == .file {
                        for length: Int? in [nil, 0, 2, 100] {
                            let bytes = try await read(length)
                            if bulk { nativeBytes.append(bytes) } else { fallbackBytes.append(bytes) }
                        }
                        await #expect(throws: WorkspaceError.self) { _ = try await read(-1) }
                    } else if info.kind == .symlink {
                        let target = try await readLink()
                        if bulk { nativeLinks.append(target) } else { fallbackLinks.append(target) }
                    }
                }
            }
            #expect(nativeInfos.map(\.path) == fallbackInfos.map(\.path))
            #expect(nativeInfos.map { MetadataIndex.Entry(info: $0) } == fallbackInfos.map { MetadataIndex.Entry(info: $0) })
            #expect(nativeInfos.map(\.linkCount) == fallbackInfos.map(\.linkCount))
            #expect(nativeBytes == fallbackBytes)
            #expect(nativeLinks == fallbackLinks)
            if path.isRoot {
                #expect(nativeInfos.filter { $0.kind == .file }.map(\.path) == ["/a.txt", "/a/file", "/a0", "/e\u{301}", "/hard", "/é"])
                #expect(nativeInfos.first { $0.path == "/hard" }?.linkCount == 2)
                #expect(nativeInfos.first { $0.path == "/hard" }?.identity == nativeInfos.first { $0.path == "/a/file" }?.identity)
            }
        }
    }

    @Test(arguments: [false, true], [
        "remove pending", "replace ancestor", "replace pending with link", "change bytes",
        "remove during read", "change link target", "add hard link", "reset", "nested walk"
    ])
    func reentrantWalkMatchesPerPathSemantics(skipVanished: Bool, mutation: String) async throws {
        var results: [[WalkRecord]] = []
        var errors: [Int?] = []
        for route in ["native", "limited", "mounted", "fallback"] {
            let fs = InMemoryFileSystem()
            try await fs.createDirectory(path: "/dir", recursive: true)
            for path: WorkspacePath in ["/a", "/dir/a", "/dir/z", "/target", "/z"] {
                try await fs.writeFile(path: path, data: Data(path.string.utf8), append: false)
            }
            try await fs.createSymlink(path: "/alink", target: "a")
            let backend: any FileSystem
            switch route {
            case "native": backend = fs
            case "limited": backend = LimitedFileSystem(base: fs, limits: .init())
            case "mounted": backend = MountedFileSystem(base: fs)
            default: backend = HookableFileSystem(base: fs)
            }
            var records: [WalkRecord] = []
            var errorCode: Int?
            do {
                try await backend.walk(skippingVanishedEntries: skipVanished) { info, read, readLink in
                    if info.path == "/a" {
                        switch mutation {
                        case "remove pending": try await fs.remove(path: "/z", recursive: false)
                        case "replace pending with link":
                            try await fs.remove(path: "/z", recursive: false)
                            try await fs.createSymlink(path: "/z", target: "target")
                        case "change bytes": try await fs.writeFile(path: "/a", data: Data("new".utf8), append: false)
                        case "remove during read": try await fs.remove(path: "/a", recursive: false)
                        case "add hard link": try await fs.createHardLink(path: "/new", target: "/z")
                        case "nested walk":
                            var paths: [WorkspacePath] = []
                            try await fs.walk { nested, _, _ in paths.append(nested.path) }
                            #expect(paths.count == 8)
                        default: break
                        }
                    }
                    if info.path == "/alink" && mutation == "change link target" {
                        try await fs.remove(path: "/alink", recursive: false)
                        try await fs.createSymlink(path: "/alink", target: "target")
                    }
                    records.append(WalkRecord(path: info.path, kind: info.kind, permissions: info.permissions,
                        linkCount: info.linkCount, bytes: info.kind == .file ? try await read(nil) : nil,
                        target: info.kind == .symlink ? try await readLink() : nil))
                    if info.path == "/dir/a" && mutation == "replace ancestor" {
                        try await fs.remove(path: "/dir", recursive: true)
                        try await fs.writeFile(path: "/dir", data: Data("replacement".utf8), append: false)
                    }
                    if info.path == "/a" && mutation == "reset" {
                        await fs.reset()
                        try await fs.writeFile(path: "/z", data: Data("replacement".utf8), append: false)
                    }
                }
            } catch {
                let error = error as NSError
                #expect(error.domain == NSPOSIXErrorDomain)
                errorCode = error.code
            }
            // Skipping missing metadata never swallows a read failure after metadata.
            let expectedError: Int?
            if mutation == "remove during read" { expectedError = Int(ENOENT) }
            else if mutation == "replace ancestor" && !skipVanished { expectedError = Int(ENOTDIR) }
            else if ["remove pending", "reset"].contains(mutation) && !skipVanished { expectedError = Int(ENOENT) }
            else { expectedError = nil }
            #expect(errorCode == expectedError)
            results.append(records)
            errors.append(errorCode)
        }
        #expect(results.allSatisfy { $0 == results.last })
        #expect(errors.allSatisfy { $0 == errors.last! })
    }
}

private struct WalkRecord: Equatable {
    var path: WorkspacePath
    var kind: FileTree.Kind
    var permissions: POSIXPermissions
    var linkCount: UInt64?
    var bytes: Data?
    var target: String?
}
