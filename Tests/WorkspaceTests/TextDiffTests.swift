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

    @Test
    func `CRLF and mixed endings retain CR content and line statistics`() throws {
        let diff = TextDiff.lineBased(from: "one\r\ntwo\r\nthree\nlast\r", to: "one\r\nTWO\r\nthree\nlast\r\n")
        #expect(diff.statistics == .init(originalLineCount: 4, updatedLineCount: 4, additions: 2, deletions: 2))
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.oldLineCount == 4)
        #expect(hunk.newLineCount == 4)
        #expect(hunk.lines.filter { $0.kind == .context }.map(\.text) == ["one\r", "three"])
        #expect(hunk.lines.filter { $0.kind == .removed }.map(\.text) == ["two\r", "last\r"])
        #expect(hunk.lines.filter { !$0.hasTrailingNewline }.map(\.text) == ["last\r"])
        #expect(hunk.lines.filter { $0.kind == .added }.allSatisfy { $0.hasTrailingNewline })
        #expect(TextDiff.lineBased(from: "\r\n\r\n", to: "\r\n\r\n").originalLineCount == 2)
    }
    @Test(arguments: [1_500, 20_000])
    func `distant sparse edits retain separate precise hunks`(count: Int) {
        let original = (1...count).map { "line \($0)" }
        var updated = original
        updated[9] = "changed ten"
        updated[count - 11] = "changed near end"
        let diff = TextDiff.lineBased(from: original.joined(separator: "\n"), to: updated.joined(separator: "\n"))
        #expect(diff.statistics.additions == 2)
        #expect(diff.statistics.deletions == 2)
        #expect(diff.hunks.count == 2)
    }

    @Test
    func `a small edit and a pasted function retain minimal separate hunks`() {
        let original = (0..<10_000).map { "let value\($0) = \($0)" }
        var updated = original
        updated[10] = "let value10 = -1"
        let function = ["func pastedFunction() {"] + (0..<298).map { "    consume(\($0))" } + ["}"]
        updated.insert(contentsOf: function, at: 9_000)
        var work = TextDiff.Work()
        let diff = TextDiff.lineBased(from: original.joined(separator: "\n"),
                                      to: updated.joined(separator: "\n"), work: &work)
        #expect(diff.statistics == .init(originalLineCount: 10_000, updatedLineCount: 10_300, additions: 301, deletions: 1))
        #expect(diff.hunks.count == 2)
        #expect(!work.lines.usedCoarseFallback)
        #expect(work.lines.steps <= TextDiff.maximumSearchSteps)
    }

    @Test
    func `scattered code edits retain minimal separate hunks`() {
        let original = (0..<20_000).map { "let value\($0) = \($0)" }
        var updated = original
        for index in stride(from: 0, to: 20_000, by: 100) {
            // The first of 200 candidate edits is unchanged; 199 are actual edits.
            updated[index] = "let value\(index) = \(index * 2)"
        }
        var work = TextDiff.Work()
        let diff = TextDiff.lineBased(from: original.joined(separator: "\n"),
                                      to: updated.joined(separator: "\n"), work: &work)
        #expect(diff.statistics == .init(originalLineCount: 20_000, updatedLineCount: 20_000, additions: 199, deletions: 199))
        #expect(diff.hunks.count == 199)
        #expect(!work.lines.usedCoarseFallback)
        #expect(work.lines.steps <= TextDiff.maximumSearchSteps)
    }

    @Test
    func `long line pairs retain independent precise character highlights`() throws {
        let original = String(repeating: "a", count: 1_000) + "x" + String(repeating: "b", count: 1_000)
        let updated = String(repeating: "a", count: 1_000) + "y" + String(repeating: "b", count: 1_000)
        let diff = TextDiff.lineBased(from: original + "\n" + original, to: updated + "\n" + updated)
        let lines = try #require(diff.hunks.first).lines.filter { $0.kind != .context }
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0.intralineRanges == [.init(location: 1_000, length: 1)] })
        // Each edge-edited 500-character pair used to consume the entire shared
        // square-size budget, making the second pair a whole-line highlight.
        let first = "a" + String(repeating: "x", count: 498) + "b"
        let second = "A" + String(repeating: "y", count: 498) + "B"
        let firstUpdated = "c" + String(repeating: "x", count: 498) + "d"
        let secondUpdated = "C" + String(repeating: "y", count: 498) + "D"
        let edgeDiff = TextDiff.lineBased(from: first + "\n" + second, to: firstUpdated + "\n" + secondUpdated)
        let edgeLines = try #require(edgeDiff.hunks.first).lines.filter { $0.kind != .context }
        #expect(edgeLines.count == 4)
        #expect(edgeLines.allSatisfy {
            $0.intralineRanges == [.init(location: 0, length: 1), .init(location: 499, length: 1)]
        })

    }

    @Test(arguments: [
        ("a\nb\nc\n", "a\nx\nb\nc\n", 1, 0),
        ("a\nb\nc\n", "a\nc\n", 0, 1),
        ("a\nb\na\n", "b\na\nb\n", 1, 1),
        ("a\na\nb\n", "a\nb\nb\n", 1, 1),
        ("a\nb\nc\n", "c\nb\na\n", 2, 2),
        ("a\na\na\nb\n", "b\na\na\na\n", 1, 1),
        ("a\nb\nc\n", "x", 1, 3),
    ])
    func `shortest scripts preserve both sides through uneven and repeated lines`(
        original: String, updated: String, additions: Int, deletions: Int
    ) {
        let diff = TextDiff.lineBased(from: original, to: updated)
        #expect(diff.statistics.additions == additions)
        #expect(diff.statistics.deletions == deletions)
        let lines = diff.hunks.flatMap(\.lines)
        #expect(lines.filter { $0.kind != .added }.map { $0.text + ($0.hasTrailingNewline ? "\n" : "") }.joined() == original)
        #expect(lines.filter { $0.kind != .removed }.map { $0.text + ($0.hasTrailingNewline ? "\n" : "") }.joined() == updated)
    }

}
