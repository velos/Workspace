import Foundation
import Testing
@testable import Workspace

@Suite("Snapshot engine")
struct SnapshotTests {
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
