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
}
