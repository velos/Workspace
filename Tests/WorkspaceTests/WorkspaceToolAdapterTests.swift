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
            ("workspace_glob", #"{"pattern":"*","match_offset":-1}"#),
            ("workspace_glob", #"{"pattern":"*","max_matches":0}"#),
            ("workspace_glob", #"{"pattern":"*","max_matches":1.5}"#),
            ("workspace_glob", #"{"pattern":"*","max_bytes":1023}"#),
            ("workspace_apply", #"{"edits":[],"max_bytes":-1}"#),
            ("workspace_apply", #"{"edits":[],"max_file_bytes":-1}"#),
            ("workspace_diff", #"{"change_offset":-1}"#),
            ("workspace_diff", #"{"max_file_bytes":1.5}"#),
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

    @Test(arguments: [false, true])
    func `read resolves intermediate symlinks before measuring and reading content`(diskBacked: Bool) async throws {
        let root = try TestSupport.temporaryDirectory("RevisionSymlinks")
        defer { TestSupport.remove(root) }
        let workspace = Workspace(persistence: diskBacked ? .directory(root) : .memory, recording: .off)
        try await workspace.createDirectory("/x")
        try await workspace.createDirectory("/y/real")
        try await workspace.writeText("/x/note", "SHORT")
        try await workspace.writeText("/y/note", "a much longer file body here")
        try await workspace.createSymbolicLink("/x/a", target: "/y/real")
        try await workspace.createSymbolicLink("/y/real/link", target: "../note")
        try await workspace.createSymbolicLink("/x/out", target: "../../../../y")
        try await workspace.createSymbolicLink("/loop-a", target: "/loop-b")
        try await workspace.createSymbolicLink("/loop-b", target: "/loop-a")
        try await workspace.createSymbolicLink("/dangling", target: "/absent")
        let expected = try await workspace.readText("/x/a/link")
        #expect(expected == "a much longer file body here")

        let checkpoint = try await workspace.createCheckpoint()
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        for (path, code) in [("/loop-a/note", ELOOP), ("/dangling/note", ENOENT),
                             ("/x/note/child", ENOTDIR), ("/x/a", EISDIR)] {
            do {
                _ = try await workspace.readData(from: WorkspacePath(path), at: .checkpoint(checkpoint.id))
                Issue.record("expected POSIX error for \(path)")
            } catch {
                #expect((error as NSError).domain == NSPOSIXErrorDomain)
                #expect((error as NSError).code == Int(code))
            }
        }
        #expect(try await workspace.readText("/x/out/note", at: .checkpoint(checkpoint.id)) == expected)
        for revision in [Revision.current, .checkpoint(checkpoint.id)] {
            #expect(try await workspace.readText("/x/a/link", at: revision) == expected)
            let suffix = revision == .current ? "" : ",\"checkpoint_id\":\"\(checkpoint.id)\""
            let data = try await adapter.call(name: "workspace_read",
                arguments: Data("{\"path\":\"/x/a/link\"\(suffix)}".utf8))
            let page = try JSONDecoder().decode(ReadPage.self, from: data)
            #expect(page.content == expected)
            #expect(page.totalBytes == UInt64(expected.utf8.count))
            #expect(page.nextOffset == UInt64(expected.utf8.count))
            #expect(!page.truncated)
        }
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

    @Test
    func `glob bounds escaped paths and pages without gaps`() async throws {
        struct Page: Decodable {
            var matches: [WorkspacePath]
            var totalMatches: Int
            var truncated: Bool
            var nextMatchOffset: Int?
            var omittedMatches: Int
        }
        let workspace = Workspace(recording: .off)
        for index in 0..<40 {
            let path = try WorkspacePath("/file-\(index)-" + String(repeating: "\u{1}", count: 80))
            try await workspace.writeText(path, "value")
        }
        let expected = try await workspace.glob("/file-*")
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        var offset = 0
        var collected: [WorkspacePath] = []
        repeat {
            let args = "{\"pattern\":\"/file-*\",\"max_bytes\":1024,\"max_matches\":3,\"match_offset\":\(offset)}"
            let data = try await adapter.call(name: "workspace_glob", arguments: Data(args.utf8))
            #expect(data.count <= 1024)
            let page = try JSONDecoder().decode(Page.self, from: data)
            #expect(page.totalMatches == 40)
            #expect(page.matches.count <= 3)
            #expect(!page.matches.isEmpty)
            #expect(page.omittedMatches == 0)
            collected += page.matches
            guard let next = page.nextMatchOffset else { break }
            #expect(page.truncated)
            #expect(next > offset)
            offset = next
        } while true
        #expect(collected == expected)
        let countLimited = try await adapter.call(name: "workspace_glob", arguments: Data(#"{"pattern":"/file-*","max_matches":3,"max_bytes":9223372036854775807}"#.utf8))
        let countPage = try JSONDecoder().decode(Page.self, from: countLimited)
        #expect(countPage.matches.count == 3)
        #expect(countPage.nextMatchOffset == 3)
        #expect(countPage.truncated)
        let beyond = try await adapter.call(name: "workspace_glob", arguments: Data(#"{"pattern":"*","match_offset":9223372036854775807,"max_bytes":9223372036854775807}"#.utf8))
        let empty = try JSONDecoder().decode(Page.self, from: beyond)
        #expect(empty.matches.isEmpty)
        #expect(!empty.truncated)
    }

    @Test
    func `diff pages bound text patch and metadata while apply preserves the full effect`() async throws {
        struct Page: Decodable {
            var changes: ChangeSet
            var statistics: ChangeSet.Statistics
            var totalChanges: Int
            var omittedFiles: Int
            var omittedTextDiffs: Int
            var truncated: Bool
            var nextChangeOffset: Int?
            var unifiedPatch: String?
            var failures: [EditFailure]?
        }
        let workspace = Workspace(recording: .off)
        let checkpoint = try await workspace.createCheckpoint()
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let text = String(repeating: "changed\u{1}😀\n", count: 100)
        var edits: [JSONValue] = []
        for index in 0..<40 {
            edits.append(.object(["kind": .string("write_text"), "path": .string("/file-\(index)"), "content": .string(text)]))
        }
        let applied = try await adapter.call(name: "workspace_apply", arguments: JSONEncoder().encode([
            "edits": JSONValue.array(edits), "max_bytes": .number(1024), "max_file_bytes": .number(512),
        ]))
        #expect(applied.count <= 1024)
        let result = try JSONDecoder().decode(Page.self, from: applied)
        #expect(result.totalChanges == 40)
        #expect(result.statistics.changedFileCount == 40)
        #expect(result.statistics.additions == 4000)
        #expect(result.truncated)
        #expect(result.omittedFiles > 0)
        #expect(result.omittedTextDiffs > 0)
        #expect(result.failures?.isEmpty == true)
        for index in 0..<40 {
            #expect(try await workspace.readText(WorkspacePath("/file-\(index)")) == text)
        }
        var offset = 0
        var paths: [WorkspacePath] = []
        repeat {
            let args: [String: JSONValue] = ["from_checkpoint_id": .string(checkpoint.id.uuidString),
                "unified_patch": .boolean(true), "max_bytes": .number(1024), "max_file_bytes": .number(512),
                "change_offset": .number(Double(offset))]
            let data = try await adapter.call(name: "workspace_diff", arguments: JSONEncoder().encode(args))
            #expect(data.count <= 1024)
            let page = try JSONDecoder().decode(Page.self, from: data)
            #expect(page.totalChanges == 40)
            #expect(page.statistics.additions == 4000)
            #expect(page.truncated)
            #expect(page.omittedTextDiffs == page.changes.changes.count)
            #expect(page.unifiedPatch == "")
            #expect(page.changes.textDiffOmissions.allSatisfy { $0.reason.rawValue == "outputBudgetExceeded" })
            paths += page.changes.changes.map(\.path)
            guard let next = page.nextChangeOffset else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(paths == (0..<40).map { WorkspacePath(normalizing: "/file-\($0)") }.sorted())
        let narrowed = try await adapter.call(name: "workspace_diff", arguments: JSONEncoder().encode([
            "from_checkpoint_id": JSONValue.string(checkpoint.id.uuidString), "paths": .array([.string("/file-0")]),
            "max_file_bytes": .number(65_536), "unified_patch": .boolean(true),
        ]))
        #expect(narrowed.count <= 65_536)
        let page = try JSONDecoder().decode(Page.self, from: narrowed)
        #expect(page.totalChanges == 1)
        #expect(page.changes.changes.first?.diff?.statistics.additions == 100)
        #expect(page.unifiedPatch?.contains("+changed") == true)
        #expect(!page.truncated)
    }

    @Test
    func `diff default and maximum budgets include escaped text and patch bytes`() async throws {
        struct Page: Decodable {
            var changes: ChangeSet
            var statistics: ChangeSet.Statistics
            var truncated: Bool
            var omittedTextDiffs: Int
            var unifiedPatch: String?
        }
        let workspace = Workspace(recording: .off)
        let before = try await workspace.createCheckpoint()
        let text = String(repeating: "\u{1}😀", count: 20_000)
        try await workspace.writeText("/large", text)
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        for extra in ["", ",\"max_bytes\":9223372036854775807,\"max_file_bytes\":9223372036854775807"] {
            let args = "{\"from_checkpoint_id\":\"\(before.id)\",\"unified_patch\":true\(extra)}"
            let data = try await adapter.call(name: "workspace_diff", arguments: Data(args.utf8))
            #expect(data.count <= (extra.isEmpty ? 65_536 : 262_144))
            let page = try JSONDecoder().decode(Page.self, from: data)
            #expect(page.truncated)
            #expect(page.omittedTextDiffs == 1)
            #expect(page.changes.changes.first?.diff == nil)
            #expect(page.statistics.additions == 1)
            #expect(page.unifiedPatch == "")
        }
        let applied = try await adapter.call(name: "workspace_apply", arguments: JSONEncoder().encode([
            "edits": JSONValue.array([.object(["kind": .string("write_text"), "path": .string("/default"), "content": .string(text)])]),
        ]))
        #expect(applied.count <= 65_536)
        let page = try JSONDecoder().decode(Page.self, from: applied)
        #expect(page.truncated)
        #expect(page.omittedTextDiffs == 1)
        #expect(try await workspace.readText("/default") == text)
    }

    @Test
    func `oversized path metadata is reported and pagination makes progress`() async throws {
        struct GlobPage: Decodable { var matches: [WorkspacePath]; var omittedMatches: Int; var truncated: Bool }
        struct DiffPage: Decodable { var changes: ChangeSet; var omittedFiles: Int; var truncated: Bool }
        let workspace = Workspace(recording: .off)
        let checkpoint = try await workspace.createCheckpoint()
        try await workspace.writeText(WorkspacePath("/a" + String(repeating: "x", count: 2000)), "value")
        try await workspace.writeText("/z", "value")
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let glob = try await adapter.call(name: "workspace_glob", arguments: Data(#"{"pattern":"/[az]*","max_bytes":1024}"#.utf8))
        #expect(glob.count <= 1024)
        let globPage = try JSONDecoder().decode(GlobPage.self, from: glob)
        #expect(globPage.matches == ["/z"])
        #expect(globPage.omittedMatches == 1)
        #expect(globPage.truncated)
        let diff = try await adapter.call(name: "workspace_diff", arguments: Data("{\"from_checkpoint_id\":\"\(checkpoint.id)\",\"max_bytes\":1024}".utf8))
        #expect(diff.count <= 1024)
        let diffPage = try JSONDecoder().decode(DiffPage.self, from: diff)
        #expect(diffPage.changes.touchedPaths == ["/z"])
        #expect(diffPage.omittedFiles == 1)
        #expect(diffPage.truncated)
    }

    @Test(arguments: [false, true])
    func `committed apply returns a minimal success envelope when detail encoding fails`(encoderThrows: Bool) async throws {
        struct Page: Decodable {
            var changes: ChangeSet
            var statistics: ChangeSet.Statistics
            var totalChanges: Int
            var failures: [EditFailure]
            var truncated: Bool
        }
        let workspace = Workspace(recording: .off)
        let result = try await workspace.apply([.appendText("/one", "first"), .writeText("/two", "second")])
        let data = boundedApplyOutput(result.changes, maxBytes: 1024, maxFileBytes: 8192,
                                      encoder: ResponseFaultEncoder(encoderThrows: encoderThrows))
        #expect(data.count <= 1024)
        let page = try JSONDecoder().decode(Page.self, from: data)
        #expect(page.changes.isEmpty)
        #expect(page.statistics.changedFileCount == 2)
        #expect(page.totalChanges == 2)
        #expect(page.failures.isEmpty)
        #expect(page.truncated)
        #expect(try await workspace.readText("/one") == "first")
        #expect(try await workspace.readText("/two") == "second")
    }

    /// Exercise both post-commit failure routes without a test-only adapter flag.
    private final class ResponseFaultEncoder: JSONEncoder, @unchecked Sendable {
        let encoderThrows: Bool
        init(encoderThrows: Bool) { self.encoderThrows = encoderThrows; super.init() }
        override func encode<T: Encodable>(_ value: T) throws -> Data {
            if encoderThrows { throw WorkspaceToolError.invalidArguments("injected encoding failure") }
            var data = try super.encode(value)
            if let output = value as? ToolChangesOutput, output.totalChanges != Int.max {
                // Valid JSON whitespace simulates a final result exceeding the estimate.
                data.append(Data(repeating: 0x20, count: 1024))
            }
            return data
        }
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
