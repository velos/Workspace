import Foundation
import Testing
@testable import Workspace

@Suite("Three-way merge")
struct ThreeWayMergeTests {
    @Test
    func `non-overlapping changes on both sides merge cleanly`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/a.txt", content: "base a\n")
        try await workspace.writeFile("/b.txt", content: "base b\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/b.txt", content: "branch b\n")
        try await branch.writeFile("/new-branch.txt", content: "from branch\n")

        // Parent edits after branching, without a checkpoint — merge(_:) would refuse this.
        try await workspace.writeFile("/a.txt", content: "parent a\n")

        let result = try await workspace.mergeThreeWay(branch, label: "merge branch")

        #expect(result.applied)
        #expect(result.conflicts.isEmpty)
        #expect(try await workspace.readFile("/a.txt") == "parent a\n")
        #expect(try await workspace.readFile("/b.txt") == "branch b\n")
        #expect(try await workspace.readFile("/new-branch.txt") == "from branch\n")

        let checkpoint = try #require(result.checkpoint)
        #expect(checkpoint.mergedFromWorkspaceId == branch.workspaceId)
        #expect((try await workspace.mutationRecords()).last?.kind == .mergeWorkspace)
    }

    @Test
    func `identical changes on both sides do not conflict`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/shared.txt", content: "base\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/shared.txt", content: "same change\n")
        try await branch.writeFile("/dup.txt", content: "identical\n")
        try await workspace.writeFile("/shared.txt", content: "same change\n")
        try await workspace.writeFile("/dup.txt", content: "identical\n")

        let result = try await workspace.mergeThreeWay(branch)

        #expect(result.applied)
        #expect(result.conflicts.isEmpty)
        #expect(try await workspace.readFile("/shared.txt") == "same change\n")
    }

    @Test
    func `deletions on the branch propagate when ours is unchanged`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.createDirectory(at: "/doomed")
        try await workspace.writeFile("/doomed/file.txt", content: "bye\n")
        try await workspace.writeFile("/keep.txt", content: "keep\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.removeItem(at: "/doomed", recursive: true)

        let result = try await workspace.mergeThreeWay(branch)

        #expect(result.applied)
        #expect(!(await workspace.exists("/doomed")))
        #expect(try await workspace.readFile("/keep.txt") == "keep\n")
    }

    @Test
    func `conflicting edits report bothModified with diffs and apply nothing`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/contested.txt", content: "base\n")
        _ = try await workspace.createCheckpoint(label: "base")
        let checkpointsBefore = try await workspace.listCheckpoints().count

        let branch = try await workspace.branch()
        try await branch.writeFile("/contested.txt", content: "theirs\n")
        try await workspace.writeFile("/contested.txt", content: "ours\n")

        let result = try await workspace.mergeThreeWay(branch)

        #expect(!result.applied)
        #expect(result.checkpoint == nil)
        #expect(result.conflicts.map(\.path) == ["/contested.txt"])
        #expect(result.conflicts.first?.kind == .bothModified)
        #expect(result.conflicts.first?.oursDiff?.hunks.isEmpty == false)
        #expect(result.conflicts.first?.theirsDiff?.hunks.isEmpty == false)

        // Nothing changed: ours content intact, no merge checkpoint or mutation appended.
        #expect(try await workspace.readFile("/contested.txt") == "ours\n")
        #expect(try await workspace.listCheckpoints().count == checkpointsBefore)
        #expect((try await workspace.mutationRecords()).last?.kind != .mergeWorkspace)
    }

    @Test
    func `modify versus delete is reported as a conflict`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/contested.txt", content: "base\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/contested.txt", content: "modified\n")
        try await workspace.removeItem(at: "/contested.txt")

        let result = try await workspace.mergeThreeWay(branch)

        #expect(!result.applied)
        #expect(result.conflicts.map(\.kind) == [.modifiedAndDeleted])
        #expect(!(await workspace.exists("/contested.txt")))
    }

    @Test
    func `divergent creations at the same path are reported as bothCreated`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/base.txt", content: "base\n")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        try await branch.writeFile("/fresh.txt", content: "theirs\n")
        try await workspace.writeFile("/fresh.txt", content: "ours\n")

        let result = try await workspace.mergeThreeWay(branch)

        #expect(!result.applied)
        #expect(result.conflicts.map(\.kind) == [.bothCreated])
        #expect(try await workspace.readFile("/fresh.txt") == "ours\n")
    }

    @Test
    func `three-way merge requires a branch base checkpoint`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/a.txt", content: "no checkpoints yet")
        let branch = try await workspace.branch()

        do {
            _ = try await workspace.mergeThreeWay(branch)
            Issue.record("expected unsupported error for a base-less branch")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("three-way merge requires"))
        }
    }
}
