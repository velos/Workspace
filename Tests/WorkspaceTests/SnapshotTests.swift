import Foundation
import Testing
@testable import Workspace

@Suite("Snapshot")
struct SnapshotTests {
    @Test
    func `capture and restore roundtrips tree contents symlinks and permissions`() async throws {
        let source = InMemoryFilesystem()
        try await source.createDirectory(path: "/docs/nested", recursive: true)
        try await source.writeFile(path: "/docs/nested/note.txt", data: Data("hello".utf8), append: false)
        try await source.createSymlink(path: "/docs/link.txt", target: "/docs/nested/note.txt")
        try await source.setPermissions(path: "/docs", permissions: POSIXPermissions(0o750))
        try await source.setPermissions(path: "/docs/nested", permissions: POSIXPermissions(0o700))
        try await source.setPermissions(path: "/docs/nested/note.txt", permissions: POSIXPermissions(0o600))
        try await source.setPermissions(path: "/docs/link.txt", permissions: POSIXPermissions(0o777))

        let snapshotId = UUID()
        let snapshot = try await Snapshot.capture(from: source, snapshotId: snapshotId)

        let target = InMemoryFilesystem()
        try await target.createDirectory(path: "/docs", recursive: true)
        try await target.writeFile(path: "/docs/stale.txt", data: Data("stale".utf8), append: false)
        try await target.writeFile(path: "/stale-root.txt", data: Data("stale".utf8), append: false)

        try await Snapshot.restore(snapshot, to: target)

        #expect(snapshot.id == snapshotId)
        #expect(snapshot.rootPath == .root)
        #expect(try await target.readFile(path: "/docs/nested/note.txt") == Data("hello".utf8))
        #expect(try await target.readSymlink(path: "/docs/link.txt") == "/docs/nested/note.txt")
        #expect(try await target.stat(path: "/docs").permissions == POSIXPermissions(0o750))
        #expect(try await target.stat(path: "/docs/nested").permissions == POSIXPermissions(0o700))
        #expect(try await target.stat(path: "/docs/nested/note.txt").permissions == POSIXPermissions(0o600))
        #expect(try await target.stat(path: "/docs/link.txt").permissions == POSIXPermissions(0o777))
        #expect(!(await target.exists(path: "/docs/stale.txt")))
        #expect(!(await target.exists(path: "/stale-root.txt")))
    }

    @Test
    func `empty root and missing subtree snapshots restore expected absence`() async throws {
        let source = InMemoryFilesystem()
        let emptyRoot = try await Snapshot.capture(from: source)
        let emptySummary = Snapshot.summary(comparing: emptyRoot, to: nil)

        let target = InMemoryFilesystem()
        try await target.writeFile(path: "/stale.txt", data: Data("stale".utf8), append: false)
        try await Snapshot.restore(emptyRoot, to: target)

        #expect(emptySummary.changeCount == 0)
        #expect(emptySummary.touchedPaths.isEmpty)
        #expect(emptySummary.hasTextDiffs == false)
        #expect(!(await target.exists(path: "/stale.txt")))

        let missing = try await Snapshot.capture(from: source, at: "/missing")
        let missingTarget = InMemoryFilesystem()
        try await missingTarget.createDirectory(path: "/missing", recursive: true)
        try await missingTarget.writeFile(path: "/missing/file.txt", data: Data("remove me".utf8), append: false)
        try await missingTarget.writeFile(path: "/kept.txt", data: Data("kept".utf8), append: false)

        try await Snapshot.restore(missing, to: missingTarget)

        guard case let .missing(entry) = missing.entry else {
            Issue.record("expected missing snapshot entry")
            return
        }
        #expect(entry.path == "/missing")
        #expect(!(await missingTarget.exists(path: "/missing")))
        #expect(try await missingTarget.readFile(path: "/kept.txt") == Data("kept".utf8))
    }

    @Test
    func `summary reports stable changed paths and text diff availability`() async throws {
        let base = try await summaryFilesystem(text: "old", binary: Data([0xFF, 0xFE]))
        let baseSnapshot = try await Snapshot.capture(from: base)

        let unchanged = try await Snapshot.capture(from: try await summaryFilesystem(text: "old", binary: Data([0xFF, 0xFE])))
        let unchangedSummary = Snapshot.summary(comparing: unchanged, to: baseSnapshot)

        let textChanged = try await Snapshot.capture(from: try await summaryFilesystem(text: "new", binary: Data([0xFF, 0xFE])))
        let textSummary = Snapshot.summary(comparing: textChanged, to: baseSnapshot)

        let binaryChanged = try await Snapshot.capture(from: try await summaryFilesystem(text: "old", binary: Data([0x00, 0xFF])))
        let binarySummary = Snapshot.summary(comparing: binaryChanged, to: baseSnapshot)

        #expect(unchangedSummary.changeCount == 0)
        #expect(unchangedSummary.touchedPaths.isEmpty)
        #expect(unchangedSummary.hasTextDiffs == false)

        #expect(textSummary.changeCount == 1)
        #expect(textSummary.touchedPaths == [WorkspacePath("/text.txt")])
        #expect(textSummary.hasTextDiffs == true)

        #expect(binarySummary.changeCount == 1)
        #expect(binarySummary.touchedPaths == [WorkspacePath("/binary.dat")])
        #expect(binarySummary.hasTextDiffs == false)
    }

    private func summaryFilesystem(text: String, binary: Data) async throws -> InMemoryFilesystem {
        let filesystem = InMemoryFilesystem()
        try await filesystem.writeFile(path: "/text.txt", data: Data(text.utf8), append: false)
        try await filesystem.writeFile(path: "/binary.dat", data: binary, append: false)
        try await filesystem.createDirectory(path: "/docs", recursive: true)
        try await filesystem.createSymlink(path: "/link.txt", target: "/text.txt")
        return filesystem
    }
}
