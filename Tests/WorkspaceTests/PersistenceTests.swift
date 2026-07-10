import Foundation
import Testing
@testable import Workspace

@Suite("Persistence")
struct PersistenceTests {
    @Test
    func `directory persistence reloads revisions and new mutation schema`() async throws {
        let root = try TestSupport.temporaryDirectory("Persistence")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let first = Workspace(workspaceID: id, persistence: .directory(root))
        try await first.writeText("/note", "one")
        let checkpoint = try await first.createCheckpoint(label: "saved")

        let second = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await second.checkpoint(id: checkpoint.id) == checkpoint)
        #expect(try await second.readText("/note", at: .checkpoint(checkpoint.id)) == "one")
        #expect(try await second.history().count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).appendingPathComponent("format.json").path))
    }

    @Test
    func `revision diff does not load an unchanged blob`() async throws {
        let root = try TestSupport.temporaryDirectory("LazyDiff")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let workspace = Workspace(workspaceID: id, persistence: .directory(root))
        _ = try await workspace.apply([
            .writeText("/stable", "stable"),
            .writeText("/changed", "before"),
        ])
        let before = try await workspace.createCheckpoint()
        try await workspace.writeText("/changed", "after")
        let after = try await workspace.createCheckpoint()

        let stableHash = SHA256.hexDigest(of: Data("stable".utf8))
        let stableBlob = root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("blobs")
            .appendingPathComponent(stableHash)
        try FileManager.default.removeItem(at: stableBlob)

        let diff = try await workspace.diff(from: .checkpoint(before.id), to: .checkpoint(after.id))
        #expect(diff.changes.map(\.path) == ["/changed"])
        await #expect(throws: WorkspaceError.self) {
            _ = try await workspace.readData(from: "/stable", at: .checkpoint(before.id))
        }
    }

    @Test
    func `torn final JSONL record is ignored and repaired by the next append`() async throws {
        let root = try TestSupport.temporaryDirectory("TornLog")
        defer { TestSupport.remove(root) }
        let id = UUID()
        var workspace = Workspace(workspaceID: id, persistence: .directory(root))
        try await workspace.writeText("/a", "a")
        let log = root.appendingPathComponent(id.uuidString).appendingPathComponent("mutations.jsonl")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":".utf8))
        try handle.close()

        workspace = Workspace(workspaceID: id, persistence: .directory(root))
        #expect(try await workspace.history().count == 1)
        try await workspace.writeText("/b", "b")
        #expect(try await workspace.history().map(\.sequence) == [1, 2])
    }

    @Test
    func `concurrent checkpoint forks retain both tips and select a deterministic parent`() async throws {
        let root = try TestSupport.temporaryDirectory("Forks")
        defer { TestSupport.remove(root) }
        let id = UUID()
        let a = Workspace(workspaceID: id, persistence: .directory(root))
        let b = Workspace(workspaceID: id, persistence: .directory(root))
        async let first = a.createCheckpoint(label: "a")
        async let second = b.createCheckpoint(label: "b")
        let forks = try await [first, second]
        #expect(forks.count == 2)

        let reloaded = Workspace(workspaceID: id, persistence: .directory(root))
        let listed = try await reloaded.checkpoints()
        #expect(listed.count == 2)
        let expectedHead = listed.max {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        let next = try await reloaded.createCheckpoint(label: "next")
        #expect(next.parentID == expectedHead?.id)
    }
}
