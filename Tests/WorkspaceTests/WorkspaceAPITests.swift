import Foundation
import Testing
@testable import Workspace

@Suite("Workspace API")
struct WorkspaceAPITests {
    @Test
    func `one changeset flows through preview apply events and history`() async throws {
        let workspace = Workspace()
        let preview = try await workspace.preview([
            .createDirectory("/docs"),
            .writeText("/docs/note.txt", "hello\n"),
        ])
        #expect(preview.touchedPaths.contains("/docs/note.txt"))
        #expect(!(await workspace.exists("/docs/note.txt")))

        let stream = await workspace.events(.init(includeCheckpoints: false))
        let nextEvent = Task<WorkspaceEvent?, Never> {
            for await event in stream { return event }
            return nil
        }
        let result = try await workspace.apply([
            .createDirectory("/docs"),
            .writeText("/docs/note.txt", "hello\n"),
        ])
        #expect(result.failures.isEmpty)
        #expect(try await workspace.readText("/docs/note.txt") == "hello\n")
        #expect(await nextEvent.value == .changes(result.changes))

        let history = try await workspace.history()
        #expect(history.count == 1)
        #expect(history[0].operation == .edit)
        #expect(history[0].changes == result.changes)
    }

    @Test
    func `atomic failure leaves files events and history unchanged`() async throws {
        let workspace = Workspace()
        let stream = await workspace.events(.init(includeCheckpoints: false))
        do {
            _ = try await workspace.apply([
                .writeText("/kept.txt", "temporary"),
                .remove("/missing/child", recursive: false),
            ])
            Issue.record("expected edit failure")
        } catch {}
        #expect(!(await workspace.exists("/kept.txt")))
        #expect(try await workspace.history().isEmpty)

        let recorder = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        recorder.cancel()
        #expect(await recorder.value == nil)
    }

    @Test
    func `checkpoint revisions support reads trees globs and structured diffs`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/note.txt", "hello world\n")
        let before = try await workspace.createCheckpoint(label: "before")

        try await workspace.writeText("/note.txt", "hello swift\nsecond\n")
        try await workspace.writeData(Data([0, 1, 2]), to: "/binary.dat")
        let after = try await workspace.createCheckpoint(label: "after")

        #expect(try await workspace.readText("/note.txt", at: .checkpoint(before.id)) == "hello world\n")
        #expect(try await workspace.glob("/**/*.txt", at: .checkpoint(after.id)) == ["/note.txt"])
        #expect(try await workspace.tree(revision: .checkpoint(after.id)).summary.fileCount == 2)

        let diff = try await workspace.diff(from: .checkpoint(before.id), to: .checkpoint(after.id))
        #expect(diff.statistics.changedFileCount == 2)
        #expect(diff.statistics.additions == 2)
        #expect(diff.statistics.deletions == 1)
        #expect(diff.textDiffOmissions == [.init(path: "/binary.dat", reason: .binary)])
        let textDiff = try #require(diff.changes.first { $0.path == "/note.txt" }?.diff)
        #expect(textDiff.originalLineCount == 1)
        #expect(textDiff.updatedLineCount == 2)
        #expect(textDiff.hunks.flatMap(\.lines).contains { !$0.intralineRanges.isEmpty })
    }

    @Test
    func `search and replacement share file selection and pattern behavior`() async throws {
        let workspace = Workspace()
        _ = try await workspace.apply([
            .writeText("/root.swift", "let OldName = 1\n"),
            .createDirectory("/Sources/Nested"),
            .writeText("/Sources/Nested/a.swift", "// OldName\nlet value = OldName\n"),
            .writeText("/Sources/Nested/ignored.txt", "OldName\n"),
        ])
        let selection = FileSelection(root: "/", include: ["**/*.swift"], exclude: ["**/Generated/**"])
        let search = try await workspace.search(
            SearchRequest(pattern: .literal("oldname", caseSensitive: false), files: selection, contextLines: 1)
        )
        #expect(search.matches.count == 3)
        #expect(search.matches.map(\.path).contains("/root.swift"))
        #expect(search.matches.contains { $0.before.count == 1 })

        let result = try await workspace.apply([
            .replace(files: selection, pattern: .literal("OldName"), with: "NewName")
        ])
        #expect(result.changes.statistics.changedFileCount == 2)
        #expect(try await workspace.readText("/root.swift") == "let NewName = 1\n")
        #expect(try await workspace.readText("/Sources/Nested/ignored.txt") == "OldName\n")
    }

    @Test
    func `archives are portable materialized subtrees`() async throws {
        let source = Workspace()
        _ = try await source.apply([
            .createDirectory("/docs/sub"),
            .writeText("/docs/sub/note.txt", "portable"),
            .createSymbolicLink("/docs/link", target: "sub/note.txt"),
        ])
        let archive = try await source.archive(at: "/docs")

        let destination = Workspace()
        let changes = try await destination.restore(archive, at: "/imported")
        #expect(!changes.isEmpty)
        #expect(try await destination.readText("/imported/sub/note.txt") == "portable")
        #expect(try await destination.readText("/imported/link") == "portable")
    }

    @Test
    func `JSON helpers and revision restore use the simplified surface`() async throws {
        struct Value: Codable, Equatable, Sendable { var name: String }
        let workspace = Workspace()
        try await workspace.writeJSON(Value(name: "one"), to: "/value.json")
        let checkpoint = try await workspace.createCheckpoint()
        try await workspace.writeJSON(Value(name: "two"), to: "/value.json")
        _ = try await workspace.restore(to: checkpoint)
        #expect(try await workspace.readJSON(Value.self, from: "/value.json") == Value(name: "one"))
        #expect(try await workspace.history().last?.operation == .rollback)
    }
}
