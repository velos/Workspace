import Foundation
import Testing
@testable import Workspace

@Suite("Workspace tool adapter")
struct WorkspaceToolAdapterTests {
    @Test
    func `definitions encode as vendor neutral JSON schemas`() throws {
        let definitions = WorkspaceToolAdapter.definitions
        #expect(definitions.map(\.name) == [
            "workspace_read", "workspace_glob", "workspace_search", "workspace_apply",
            "workspace_diff", "workspace_checkpoint",
        ])
        let data = try JSONEncoder().encode(definitions)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect((json[0]["inputSchema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test
    func `apply read checkpoint and diff share one workspace`() async throws {
        let workspace = Workspace()
        let adapter = WorkspaceToolAdapter(workspace: workspace)

        let applied = try await adapter.call(
            name: "workspace_apply",
            arguments: Data(#"{"edits":[{"kind":"write_text","path":"/note","content":"one\n"}]}"#.utf8)
        )
        let result = try JSONDecoder().decode(EditResult.self, from: applied)
        #expect(result.changes.touchedPaths == ["/note"])

        let checkpointData = try await adapter.call(
            name: "workspace_checkpoint",
            arguments: Data(#"{"label":"before"}"#.utf8)
        )
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: checkpointData)
        _ = try await workspace.writeText("/note", "two\n")

        let read = try await adapter.call(
            name: "workspace_read",
            arguments: Data("{\"path\":\"/note\",\"checkpoint_id\":\"\(checkpoint.id)\"}".utf8)
        )
        let readJSON = try #require(JSONSerialization.jsonObject(with: read) as? [String: Any])
        #expect(readJSON["content"] as? String == "one\n")

        let diff = try await adapter.call(
            name: "workspace_diff",
            arguments: Data("{\"from_checkpoint_id\":\"\(checkpoint.id)\",\"unified_patch\":true}".utf8)
        )
        let diffJSON = try #require(JSONSerialization.jsonObject(with: diff) as? [String: Any])
        #expect((diffJSON["unifiedPatch"] as? String)?.contains("-one") == true)
        #expect((diffJSON["unifiedPatch"] as? String)?.contains("+two") == true)
    }

    @Test
    func `invalid tool arguments report adapter errors`() async throws {
        let adapter = WorkspaceToolAdapter(workspace: Workspace())
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await adapter.call(
                name: "workspace_apply",
                arguments: Data(#"{"edits":[{"kind":"write_text","path":"/note"}]}"#.utf8)
            )
        }
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await adapter.call(name: "missing", arguments: Data("{}".utf8))
        }
    }

    @Test(arguments: [false, true])
    func `search clamps maximum integer context without overflow`(throughAdapter: Bool) async throws {
        let workspace = Workspace()
        let lines = (0..<205).map { $0 == 102 ? "TODO" : "line \($0)" }
        try await workspace.writeText("/note", lines.joined(separator: "\n"))
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let result: SearchResult
        if throughAdapter {
            let data = try await adapter.call(
                name: "workspace_search",
                arguments: Data(#"{"pattern":"TODO","context_lines":9223372036854775807}"#.utf8)
            )
            result = try JSONDecoder().decode(SearchResult.self, from: data)
        } else {
            result = try await workspace.search(SearchRequest(pattern: .literal("TODO"), contextLines: Int.max))
        }
        let match = try #require(result.matches.first)
        #expect(match.lineNumber == 103)
        #expect(match.before.count == 100)
        #expect(match.after.count == 100)
    }

    @Test
    func `numeric tool arguments reject negative fractional and out of range values`() async throws {
        let adapter = WorkspaceToolAdapter(workspace: Workspace())
        for (name, json) in [
            ("workspace_search", #"{"pattern":"TODO","context_lines":-1}"#),
            ("workspace_search", #"{"pattern":"TODO","context_lines":1.5}"#),
            ("workspace_search", #"{"pattern":"TODO","context_lines":9223372036854775808}"#),
            ("workspace_search", #"{"pattern":"TODO","match_offset":-1}"#),
            ("workspace_search", #"{"pattern":"TODO","max_bytes":-1}"#),
            ("workspace_diff", #"{"max_text_bytes":-1}"#),
            ("workspace_diff", #"{"max_text_bytes":1.5}"#),
            ("workspace_read", #"{"path":"/note","offset":-1}"#),
            ("workspace_read", #"{"path":"/note","offset":1.5}"#),
            ("workspace_read", #"{"path":"/note","offset":18446744073709551616}"#),
            ("workspace_read", #"{"path":"/note","max_bytes":-1}"#),
        ] {
            await #expect(throws: WorkspaceToolError.self) {
                _ = try await adapter.call(name: name, arguments: Data(json.utf8))
            }
        }
    }

    @Test
    func `read pages are bounded lossless UTF8 and report total bytes`() async throws {
        let workspace = Workspace(recording: .off)
        // Keep the line count small to avoid the existing quadratic checkpoint diff cost.
        let content = "abc" + String(repeating: String(repeating: "abc😀", count: 999) + "\n", count: 52)
        try await workspace.writeText("/note", content)
        let checkpoint = try await workspace.createCheckpoint()
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        for checkpointID in [nil, checkpoint.id.uuidString] {
            var offset: UInt64 = 0
            var reconstructed = ""
            repeat {
                var arguments: [String: JSONValue] = ["path": .string("/note"), "offset": .number(Double(offset))]
                if let checkpointID { arguments["checkpoint_id"] = .string(checkpointID) }
                let data = try await adapter.call(name: "workspace_read", arguments: JSONEncoder().encode(arguments))
                let page = try JSONDecoder().decode(ReadPage.self, from: data)
                #expect(page.totalBytes == UInt64(content.utf8.count))
                #expect(page.content.utf8.count <= 65_536)
                #expect(data.count < 400_000) // Includes worst-case JSON escaping and metadata.
                #expect(page.offset == offset)
                #expect(page.nextOffset > offset)
                reconstructed += page.content
                offset = page.nextOffset
                if !page.truncated { break }
            } while true
            #expect(reconstructed == content)
        }
        let capped = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/note","max_bytes":9223372036854775807}"#.utf8))
        let cappedPage = try JSONDecoder().decode(ReadPage.self, from: capped)
        #expect(cappedPage.content.utf8.count <= 262_144)
        #expect(cappedPage.truncated)
        let huge = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/note","offset":18446744073709551615,"max_bytes":9223372036854775807}"#.utf8))
        let eof = try JSONDecoder().decode(ReadPage.self, from: huge)
        #expect(eof.content.isEmpty)
        #expect(!eof.truncated)
    }

    @Test
    func `search pages bound encoded output including repeated context and escaping`() async throws {
        let workspace = Workspace(recording: .off)
        let line = "TODO" + String(repeating: "\u{1}", count: 500)
        try await workspace.writeText("/note", Array(repeating: line, count: 50).joined(separator: "\r\n"))
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        var offset = 0
        var lineNumbers: [Int] = []
        repeat {
            let json = "{\"pattern\":\"TODO\",\"context_lines\":100,\"max_bytes\":4096,\"match_offset\":\(offset)}"
            let data = try await adapter.call(name: "workspace_search", arguments: Data(json.utf8))
            #expect(data.count <= 4096)
            let page = try JSONDecoder().decode(SearchPage.self, from: data)
            #expect(page.totalMatches == 50)
            #expect(!page.matches.isEmpty)
            lineNumbers += page.matches.map(\.lineNumber)
            guard let next = page.nextMatchOffset else {
                #expect(page.truncated == page.matches.contains { $0.truncated })
                break
            }
            #expect(page.truncated)
            #expect(next > offset)
            offset = next
        } while true
        #expect(lineNumbers == Array(1...50))
    }

    @Test
    func `diff caps maximum integer byte limits before comparing text`() async throws {
        struct Output: Decodable { var changes: ChangeSet }
        let workspace = Workspace(recording: .off)
        let checkpoint = try await workspace.createCheckpoint()
        try await workspace.writeText("/large", String(repeating: "x", count: 1_000_001))
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let arguments = "{\"from_checkpoint_id\":\"\(checkpoint.id)\",\"max_text_bytes\":9223372036854775807}"
        let data = try await adapter.call(name: "workspace_diff", arguments: Data(arguments.utf8))
        let output = try JSONDecoder().decode(Output.self, from: data)
        #expect(output.changes.changes.first?.diff == nil)
        #expect(output.changes.textDiffOmissions == [.init(path: "/large", reason: .sizeLimitExceeded)])
    }

    @Test
    func `read rejects invalid encoding and offsets within UTF8 scalars`() async throws {
        let workspace = Workspace(recording: .off)
        try await workspace.writeText("/unicode", "a😀b")
        // An incomplete prefix of an out-of-range scalar must not be accepted as a page.
        try await workspace.writeData(Data([0x61, 0xF4, 0x90, 0x80, 0x80, 0x62]), to: "/invalid")
        try await workspace.writeData(Data([0x61, 0x80, 0x62]), to: "/orphan")
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        await #expect(throws: WorkspaceToolError.invalidArguments(
            "offset 2 is inside a UTF-8 character; use a nextOffset value from a previous read"
        )) {
            _ = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/unicode","offset":2,"max_bytes":4}"#.utf8))
        }
        for (path, arguments) in [
            (WorkspacePath("/invalid"), #"{"path":"/invalid","max_bytes":4}"#),
            (WorkspacePath("/orphan"), #"{"path":"/orphan","offset":1,"max_bytes":4}"#),
        ] {
            do {
                _ = try await adapter.call(name: "workspace_read", arguments: Data(arguments.utf8))
                Issue.record("expected invalidEncoding for malformed bytes")
            } catch let error as WorkspaceError {
                guard case let .invalidEncoding(invalidPath) = error else {
                    Issue.record("expected invalidEncoding, received \(error)")
                    continue
                }
                #expect(invalidPath == path)
            }
        }
        let first = try JSONDecoder().decode(ReadPage.self, from: await adapter.call(
            name: "workspace_read", arguments: Data(#"{"path":"/unicode","max_bytes":4}"#.utf8)))
        #expect(first.content == "a")
        #expect(first.nextOffset == 1)
        let second = try JSONDecoder().decode(ReadPage.self, from: await adapter.call(
            name: "workspace_read", arguments: Data(#"{"path":"/unicode","offset":1,"max_bytes":4}"#.utf8)))
        #expect(second.content == "😀")
        #expect(second.nextOffset == 5)
    }

    @Test
    func `read uses shared revision errors and symlink target sizes`() async throws {
        let workspace = Workspace(recording: .off)
        try await workspace.writeText("/note", "abcdefghijklmnopqrst")
        try await workspace.createDirectory("/links")
        try await workspace.createSymbolicLink("/links/note", target: "../note")
        let checkpoint = try await workspace.createCheckpoint()
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        for checkpointID in [nil, checkpoint.id.uuidString] {
            let suffix = checkpointID.map { ",\"checkpoint_id\":\"\($0)\"" } ?? ""
            let data = try await adapter.call(name: "workspace_read",
                arguments: Data("{\"path\":\"/links/note\",\"max_bytes\":4\(suffix)}".utf8))
            let page = try JSONDecoder().decode(ReadPage.self, from: data)
            #expect(page.content == "abcd")
            #expect(page.totalBytes == 20)
            #expect(page.nextOffset == 4)
            #expect(page.truncated)
            do {
                _ = try await adapter.call(name: "workspace_read",
                    arguments: Data("{\"path\":\"/missing\"\(suffix)}".utf8))
                Issue.record("expected ENOENT for missing file")
            } catch {
                let posix = error as NSError
                #expect(posix.domain == NSPOSIXErrorDomain)
                #expect(posix.code == Int(ENOENT))
            }
        }
    }

    @Test
    func `read resolves intermediate symlinks before measuring and reading content`() async throws {
        let workspace = Workspace(recording: .off)
        try await workspace.createDirectory("/x")
        try await workspace.createDirectory("/y/real")
        try await workspace.writeText("/x/note", "SHORT")
        try await workspace.writeText("/y/note", "a much longer file body here")
        try await workspace.createSymbolicLink("/x/a", target: "/y/real")
        try await workspace.createSymbolicLink("/y/real/link", target: "../note")
        let expected = try await workspace.readText("/x/a/link")
        #expect(expected == "a much longer file body here")

        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let data = try await adapter.call(name: "workspace_read",
            arguments: Data(#"{"path":"/x/a/link"}"#.utf8))
        let page = try JSONDecoder().decode(ReadPage.self, from: data)
        #expect(page.content == expected)
        #expect(page.totalBytes == UInt64(expected.utf8.count))
        #expect(page.nextOffset == UInt64(expected.utf8.count))
        #expect(!page.truncated)
    }

    @Test
    func `search shortens oversized lines and reserves space after skipped files`() async throws {
        let workspace = Workspace(recording: .off)
        for index in 0..<20 {
            try await workspace.writeData(Data([0]), to: WorkspacePath("/binary-\(index)"))
        }
        let line = "TODO" + String(repeating: "😀", count: 20_000)
        try await workspace.writeText("/z-note", line)
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let data = try await adapter.call(name: "workspace_search", arguments: Data(#"{"pattern":"TODO","max_bytes":1024}"#.utf8))
        #expect(data.count <= 1024)
        let page = try JSONDecoder().decode(SearchResult.self, from: data)
        let match = try #require(page.matches.first)
        #expect(match.path == "/z-note")
        #expect(match.truncated)
        #expect(match.totalBytes == UInt64(line.utf8.count))
        #expect(match.line.hasPrefix("TODO"))
        #expect(line.hasPrefix(match.line))
        #expect(page.totalMatches == 1)
        #expect(page.nextMatchOffset == nil)
        #expect(page.truncated)
        let beyond = try await adapter.call(name: "workspace_search", arguments: Data(#"{"pattern":"TODO","match_offset":9223372036854775807,"max_bytes":9223372036854775807}"#.utf8))
        #expect(try JSONDecoder().decode(SearchResult.self, from: beyond).matches.isEmpty)
    }

    private struct ReadPage: Decodable {
        var content: String
        var offset: UInt64
        var nextOffset: UInt64
        var totalBytes: UInt64
        var truncated: Bool
    }
    private struct SearchPage: Decodable {
        var matches: [SearchResult.Match]
        var totalMatches: Int
        var truncated: Bool
        var nextMatchOffset: Int?
    }
}
