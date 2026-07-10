import Foundation
import Testing
@testable import Workspace

@Suite("TextDiff")
struct TextDiffTests {
    @Test
    func `lineBased returns no hunks for identical content`() {
        let diff = TextDiff.lineBased(from: "alpha\nbravo\n", to: "alpha\nbravo\n")
        #expect(diff.hunks.isEmpty)
    }

    @Test
    func `lineBased returns no hunks for two empty strings`() {
        let diff = TextDiff.lineBased(from: "", to: "")
        #expect(diff.hunks.isEmpty)
    }

    @Test
    func `lineBased treats creation from empty as a single added hunk`() {
        let diff = TextDiff.lineBased(from: "", to: "hello\nworld\n")
        let hunk = try! #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)

        let added = hunk.lines.filter { $0.kind == .added }
        #expect(added.map(\.text) == ["hello", "world"])
        #expect(added.allSatisfy { $0.hasTrailingNewline })
        #expect(added.compactMap(\.newLineNumber) == [1, 2])
        #expect(hunk.lines.allSatisfy { $0.kind != .removed })
    }

    @Test
    func `lineBased treats deletion to empty as a single removed hunk`() {
        let diff = TextDiff.lineBased(from: "keep\nme\n", to: "")
        let hunk = try! #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)

        let removed = hunk.lines.filter { $0.kind == .removed }
        #expect(removed.map(\.text) == ["keep", "me"])
        #expect(removed.compactMap(\.oldLineNumber) == [1, 2])
        #expect(hunk.lines.allSatisfy { $0.kind != .added })
    }

    @Test
    func `lineBased emits add and remove with surrounding context for a single-line change`() {
        let original = """
        one
        two
        three
        four
        five
        """
        let updated = """
        one
        two
        THREE
        four
        five
        """

        let diff = TextDiff.lineBased(from: original, to: updated)
        let hunk = try! #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)

        let removedTexts = hunk.lines.filter { $0.kind == .removed }.map(\.text)
        let addedTexts = hunk.lines.filter { $0.kind == .added }.map(\.text)
        #expect(removedTexts == ["three"])
        #expect(addedTexts == ["THREE"])

        let contextTexts = hunk.lines.filter { $0.kind == .context }.map(\.text)
        #expect(contextTexts == ["one", "two", "four", "five"])
    }

    @Test
    func `lineBased preserves trailing-newline metadata on the last line`() {
        let withNewline = TextDiff.lineBased(from: "", to: "x\n")
        let withoutNewline = TextDiff.lineBased(from: "", to: "x")

        let firstWithNewline = try! #require(withNewline.hunks.first?.lines.first)
        let firstWithoutNewline = try! #require(withoutNewline.hunks.first?.lines.first)

        #expect(firstWithNewline.hasTrailingNewline == true)
        #expect(firstWithoutNewline.hasTrailingNewline == false)
    }

    @Test
    func `lineBased matches Workspace replacement preview for the same edit`() async throws {
        let original = """
        red
        green
        blue
        """
        let updated = """
        red
        teal
        blue
        """

        let workspace = Workspace(fileSystem: InMemoryFileSystem())
        try await workspace.writeText("/colors.txt", original)

        let preview = try await workspace.preview([
            .replace(
                files: FileSelection(include: ["/colors.txt"]),
                pattern: .literal("green"),
                with: "teal"
            )
        ])
        let workspaceDiff = try #require(preview.changes.first?.diff)

        let utilityDiff = TextDiff.lineBased(from: original, to: updated)

        #expect(workspaceDiff == utilityDiff)
    }
}
