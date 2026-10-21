import Foundation
import Testing
@testable import Workspace

@Suite("Bounded follow-up work")
struct FollowupPerformanceTests {
    @Test
    func `large line diffs have bounded search work and complete statistics`() throws {
        let count = 10_000
        let content = (0..<count).map { "line \($0)\n" }.joined()
        var work = TextDiff.Work()
        let inserted = TextDiff.lineBased(from: "", to: content, work: &work)
        #expect(work.lines.steps == 0)
        #expect(work.lines.usedTrivialCase)
        #expect(inserted.statistics == .init(originalLineCount: 0, updatedLineCount: count, additions: count, deletions: 0))
        work = TextDiff.Work()
        let deleted = TextDiff.lineBased(from: content, to: "", work: &work)
        #expect(work.lines.steps == 0)
        #expect(work.lines.usedTrivialCase)
        #expect(deleted.statistics.additions == 0)
        #expect(deleted.statistics.deletions == count)

        let updated = "line 0\n" + (1..<(count - 1)).map { "changed \($0)\n" }.joined() + "line \(count - 1)\n"
        work = TextDiff.Work()
        let replaced = TextDiff.lineBased(from: content, to: updated, work: &work)
        #expect(work.lines.steps > 0)
        #expect(work.lines.steps <= TextDiff.maximumSearchSteps)
        #expect(work.lines.usedCoarseFallback)
        #expect(work.maximumIntralineSteps <= TextDiff.maximumSearchSteps)
        #expect(replaced.statistics == .init(originalLineCount: count, updatedLineCount: count, additions: count - 2, deletions: count - 2))
        let hunk = try #require(replaced.hunks.first)
        #expect(replaced.hunks.count == 1)
        let reconstructed = hunk.lines.filter { $0.kind != .removed }.map {
            $0.text + ($0.hasTrailingNewline ? "\n" : "")
        }.joined()
        #expect(reconstructed == updated)
        work = TextDiff.Work()
        let longLine = TextDiff.lineBased(from: String(repeating: "a", count: count),
                                          to: String(repeating: "b", count: count), work: &work)
        #expect(work.intralineFallbacks == 1)
        #expect(work.maximumIntralineSteps <= TextDiff.maximumSearchSteps)
        #expect(longLine.hunks.first?.lines.first?.intralineRanges == [.init(location: 0, length: count)])
        work = TextDiff.Work()
        let identical = TextDiff.lineBased(from: content, to: content, work: &work)
        #expect(work.lines.steps == 0)
        #expect(identical.hunks.isEmpty)
    }

    @Test
    func `checkpoint paging builds its immutable revision index exactly once`() async throws {
        struct Page: Decodable { var content: String; var nextOffset: UInt64; var truncated: Bool }
        let workspace = Workspace(recording: .off)
        let checkpointStore = await workspace.store
        let store = try #require(checkpointStore as? InMemoryCheckpointStore)
        let content = String(repeating: "x\n", count: 4_096)
        try await workspace.writeText("/pages", content)
        try await workspace.writeData(Data(repeating: 0, count: 32_000), to: "/unrelated")
        let checkpoint = try await workspace.createCheckpoint()
        #expect(await store.revisionIndexBuildCount == 0)
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        var offset: UInt64 = 0
        var reconstructed = ""
        var pages = 0
        repeat {
            let args = "{\"path\":\"/pages\",\"checkpoint_id\":\"\(checkpoint.id)\",\"offset\":\(offset),\"max_bytes\":128}"
            let page = try JSONDecoder().decode(Page.self, from: await adapter.call(name: "workspace_read", arguments: Data(args.utf8)))
            #expect(page.nextOffset > offset)
            reconstructed += page.content
            offset = page.nextOffset
            pages += 1
            if !page.truncated { break }
        } while true
        #expect(pages == 64)
        #expect(await store.revisionIndexBuildCount == 1)
        #expect(reconstructed == content)
        try await workspace.writeText("/pages", "new current content")
        #expect(try await workspace.readText("/pages", at: .checkpoint(checkpoint.id)) == content)
        #expect(await store.revisionIndexBuildCount == 1)
    }

    @Test
    func `paging thousands of changes and glob matches encodes each entry once`() throws {
        struct DiffPage: Decodable { var changes: ChangeSet; var nextChangeOffset: Int?; var unifiedPatch: String? }
        struct GlobPage: Decodable { var matches: [WorkspacePath]; var nextMatchOffset: Int? }
        let diff = TextDiff.lineBased(from: "old\n", to: "new\n")
        let source = ChangeSet(changes: (0..<3_000).map {
            .init(path: WorkspacePath(normalizing: "/file-\($0)"), kind: .file, effect: .modified, diff: diff)
        })
        let expected = source.changes.map(\.path)
        var offset = 0
        var collected: [WorkspacePath] = []
        repeat {
            let encoder = CountingOutputEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try boundedChangesOutput(source, offset: offset, maxBytes: 262_144, maxFileBytes: 8_192,
                                                patch: true, applying: false, encoder: encoder)
            #expect(data.count <= 262_144)
            let page = try JSONDecoder().decode(DiffPage.self, from: data)
            #expect(encoder.changeEncodes >= page.changes.changes.count)
            #expect(encoder.diffEncodes == encoder.changeEncodes)
            #expect(encoder.patchEncodes == encoder.changeEncodes)
            #expect(encoder.changeEncodes <= page.changes.changes.count + 1)
            #expect(encoder.envelopeEncodes == 1)
            #expect(encoder.finalEncodes == 1)
            #expect(encoder.totalEncodes <= encoder.changeEncodes * 4 + 2)
            #expect(page.unifiedPatch == page.changes.unifiedPatch())
            collected += page.changes.changes.map(\.path)
            guard let next = page.nextChangeOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(collected == expected)
        offset = 0
        collected = []
        repeat {
            let encoder = CountingOutputEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try boundedGlobOutput(expected, offset: offset, maxMatches: 500, maxBytes: 65_536,
                                             encoder: encoder)
            #expect(data.count <= 65_536)
            let page = try JSONDecoder().decode(GlobPage.self, from: data)
            #expect(encoder.matchEncodes >= page.matches.count)
            #expect(encoder.matchEncodes <= page.matches.count + 1)
            #expect(encoder.envelopeEncodes == 1)
            #expect(encoder.finalEncodes == 1)
            #expect(encoder.totalEncodes == encoder.matchEncodes + 2)
            collected += page.matches
            guard let next = page.nextMatchOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(collected == expected)
    }
    /// Count actual top-level encoder calls, including any future accidental
    /// re-encoding of a growing envelope, without instrumentation in production.
    private final class CountingOutputEncoder: JSONEncoder, @unchecked Sendable {
        var changeEncodes = 0
        var diffEncodes = 0
        var patchEncodes = 0
        var matchEncodes = 0
        var envelopeEncodes = 0
        var finalEncodes = 0
        var totalEncodes = 0
        override func encode<T: Encodable>(_ value: T) throws -> Data {
            totalEncodes += 1
            if value is FileChange { changeEncodes += 1 }
            if value is TextDiff { diffEncodes += 1 }
            if value is String { patchEncodes += 1 }
            if value is WorkspacePath { matchEncodes += 1 }
            if let output = value as? ToolChangesOutput {
                if output.totalChanges == Int.max { envelopeEncodes += 1 } else { finalEncodes += 1 }
            }
            if let output = value as? ToolGlobOutput {
                if output.totalMatches == Int.max { envelopeEncodes += 1 } else { finalEncodes += 1 }
            }
            return try super.encode(value)
        }
    }

}
