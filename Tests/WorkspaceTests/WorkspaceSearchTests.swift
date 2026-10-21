import Foundation
import Testing
@testable import Workspace

@Suite("Workspace search")
struct WorkspaceSearchTests {
    @Test
    func `library search is unbounded unless an output budget is supplied`() async throws {
        let workspace = Workspace(recording: .off)
        let line = "TODO" + String(repeating: "x", count: 80_000)
        try await workspace.writeText("/note", line)

        let result = try await workspace.search(SearchRequest(pattern: .literal("TODO")))
        let match = try #require(result.matches.first)
        #expect(match.line.utf8.count == 80_004)
        #expect(!match.truncated)
        #expect(!result.truncated)
        #expect(try JSONEncoder().encode(result).count > 65_536)

        var limits = SearchRequest.Limits.default
        limits.maxOutputBytes = 1_024
        let bounded = try await workspace.search(SearchRequest(pattern: .literal("TODO"), limits: limits))
        #expect(bounded.truncated)
        #expect(try JSONEncoder().encode(bounded).count <= 1_024)
    }

    @Test
    func `search truncation is computed and encoded without aggregate byte totals`() throws {
        var result = SearchResult(matches: [], skippedFiles: [], searchedFileCount: 0, truncation: nil)
        result.truncation = .matchLimit
        #expect(result.truncated)
        let truncatedJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(truncatedJSON["truncated"] as? Bool == true)
        #expect(truncatedJSON["totalBytes"] == nil)
        result.truncation = nil
        #expect(!result.truncated)
        let completeJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(completeJSON["truncated"] as? Bool == false)
    }
}
