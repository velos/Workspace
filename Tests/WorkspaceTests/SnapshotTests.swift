import Foundation
import Testing
@testable import Workspace

@Suite("Snapshot engine")
struct SnapshotTests {
    @Test
    func `permission denial recognizes Foundation and nested Swift error representations`() {
        let denied: [any Error] = [
            POSIXError(.EACCES), POSIXError(.EPERM),
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.EACCES.rawValue)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.Code.EPERM.rawValue)),
            CocoaError(.fileReadNoPermission), CocoaError(.fileWriteNoPermission),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                    userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES) as any Error]),
            NSError(domain: "outer", code: 1, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: "inner", code: 2, userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM) as any Error])])
        ]
        for error in denied { #expect(Snapshot.isPermissionDenied(error)) }
        let other: [any Error] = [
            POSIXError(.ENOENT), POSIXError(.EIO), CocoaError(.fileWriteUnknown),
            WorkspaceError.unsupported("permissions"), WorkspaceError.accessDenied(operation: "write", message: nil),
            NSError(domain: "unrelated", code: Int(POSIXError.Code.EACCES.rawValue)),
            NSError(domain: "outer", code: 1, userInfo: [NSUnderlyingErrorKey: POSIXError(.EIO) as any Error])
        ]
        for error in other { #expect(!Snapshot.isPermissionDenied(error)) }
    }

    @Test
    func `folding a replacement preserves unrelated missing entries`() {
        let missing = Snapshot.Entry.missing(.init(path: "/unrelated"))
        let file = Snapshot.Entry.file(.init(path: "/changed", data: Data(), permissions: .defaultFile))
        let tree = Snapshot.Entry.directory(.init(path: .root, permissions: .defaultDirectory, children: [file, missing]))
        let replacement = Snapshot.Entry.missing(.init(path: "/changed"))
        let folded = Snapshot.replacing(tree, with: replacement)
        #expect(folded == .directory(.init(path: .root, permissions: .defaultDirectory, children: [missing])))
    }

    @Test
    func `capture and restore roundtrips tree contents symlinks and permissions`() async throws {
        let source = InMemoryFileSystem()
        try await source.createDirectory(path: "/docs/nested", recursive: true)
        try await source.writeFile(path: "/docs/nested/note.txt", data: Data("hello".utf8), append: false)
        try await source.createSymlink(path: "/docs/link.txt", target: "/docs/nested/note.txt")
        try await source.setPermissions(path: "/docs", permissions: POSIXPermissions(0o750))
        try await source.setPermissions(path: "/docs/nested/note.txt", permissions: POSIXPermissions(0o600))

        let snapshotID = UUID()
        let snapshot = try await Snapshot.capture(from: source, snapshotId: snapshotID)
        let target = InMemoryFileSystem()
        try await target.writeFile(path: "/stale.txt", data: Data("stale".utf8), append: false)
        try await Snapshot.restore(snapshot, to: target)

        #expect(snapshot.id == snapshotID)
        #expect(snapshot.rootPath == WorkspacePath.root)
        #expect(try await target.readFile(path: "/docs/nested/note.txt") == Data("hello".utf8))
        #expect(try await target.readSymlink(path: "/docs/link.txt") == "/docs/nested/note.txt")
        #expect(try await target.stat(path: "/docs").permissions == POSIXPermissions(0o750))
        #expect(try await target.stat(path: "/docs/nested/note.txt").permissions == POSIXPermissions(0o600))
        #expect(!(await target.exists(path: "/stale.txt")))
    }

    @Test
    func `empty root and missing subtree restore exact absence`() async throws {
        let source = InMemoryFileSystem()
        let emptyRoot = try await Snapshot.capture(from: source)
        let target = InMemoryFileSystem()
        try await target.writeFile(path: "/stale.txt", data: Data("stale".utf8), append: false)
        try await Snapshot.restore(emptyRoot, to: target)
        #expect(!(await target.exists(path: "/stale.txt")))

        let missing = try await Snapshot.capture(from: source, at: "/missing")
        let missingTarget = InMemoryFileSystem()
        try await missingTarget.createDirectory(path: "/missing", recursive: true)
        try await missingTarget.writeFile(path: "/missing/file", data: Data("remove".utf8), append: false)
        try await missingTarget.writeFile(path: "/kept", data: Data("kept".utf8), append: false)
        try await Snapshot.restore(missing, to: missingTarget)

        guard case let .missing(entry) = missing.entry else {
            Issue.record("expected missing snapshot entry")
            return
        }
        #expect(entry.path == "/missing")
        #expect(!(await missingTarget.exists(path: "/missing")))
        #expect(try await missingTarget.readFile(path: "/kept") == Data("kept".utf8))
    }

    @Test
    func `entry paths reflect every captured node kind`() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory(path: "/dir", recursive: true)
        try await fileSystem.writeFile(path: "/dir/note", data: Data("hi".utf8), append: false)
        try await fileSystem.createSymlink(path: "/dir/link", target: "/dir/note")

        let snapshot = try await Snapshot.capture(from: fileSystem)
        guard case let .directory(root) = snapshot.entry,
              let child = root.children.first(where: { $0.path == "/dir" }),
              case let .directory(directory) = child
        else {
            Issue.record("expected captured directory")
            return
        }
        #expect(snapshot.entry.path == WorkspacePath.root)
        #expect(directory.children.map(\.path).sorted() == ["/dir/link", "/dir/note"])
    }

    @Test
    func `subtree snapshots produce canonical changes and Codable round trips`() async throws {
        let fileSystem = InMemoryFileSystem()
        try await fileSystem.createDirectory(path: "/project/src", recursive: true)
        try await fileSystem.writeFile(path: "/project/src/main.swift", data: Data("old\n".utf8), append: false)
        let before = try await Snapshot.capture(from: fileSystem, at: "/project")

        try await fileSystem.writeFile(path: "/project/src/main.swift", data: Data("new\n".utf8), append: false)
        let after = try await Snapshot.capture(from: fileSystem, at: "/project")
        let changes = ChangeSet.compare(before: before, after: after, maxTextBytes: 1_000_000)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(after))

        #expect(changes.touchedPaths == ["/project/src/main.swift"])
        #expect(changes.summary.hasTextChanges)
        #expect(decoded == after)
    }
}
