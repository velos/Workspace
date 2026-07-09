import Foundation
import Testing
@testable import Workspace

@Suite("Tracking policy")
struct TrackingPolicyTests {
    @Test
    func `full tracking exposes public mutation history with diffs`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem())
        try await workspace.writeFile("/note.txt", content: "one\n")
        try await workspace.writeFile("/note.txt", content: "two\n")

        let mutations = try await workspace.mutationRecords()
        #expect(mutations.map(\.kind) == [.writeFile, .writeFile])
        #expect(mutations.map(\.sequence) == [1, 2])
        #expect(mutations[1].diff?.hunks.isEmpty == false)
        #expect(mutations[1].touchedPaths == ["/note.txt"])
    }

    @Test
    func `pathsOnly tracking records effects without diffs`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem(), tracking: .pathsOnly)
        try await workspace.writeFile("/note.txt", content: "one")
        try await workspace.writeFile("/note.txt", content: "two")
        try await workspace.removeItem(at: "/note.txt")

        let mutations = try await workspace.mutationRecords()
        #expect(mutations.map(\.kind) == [.writeFile, .writeFile, .removeItem])
        #expect(mutations.allSatisfy { $0.diff == nil })
        #expect(mutations.allSatisfy { record in record.fileChanges.allSatisfy { $0.diff == nil } })
        #expect(mutations[1].fileChanges.first?.effect == .modified)
        #expect(mutations[1].touchedPaths == ["/note.txt"])
        #expect(mutations[2].fileChanges.first?.effect == .deleted)
    }

    @Test
    func `pathsOnly tracking keeps replacement counts and change events`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem(), tracking: .pathsOnly)
        try await workspace.writeFile("/a.txt", content: "old old")

        let stream = await workspace.watchChanges(at: "/a.txt", recursive: false)
        var iterator = stream.makeAsyncIterator()

        let result = try await workspace.applyReplacement(
            ReplacementRequest(pattern: "/a.txt", search: "old", replacement: "new")
        )

        #expect(result.changes.first?.replacements == 2)
        #expect(result.changes.first?.diff.hunks.isEmpty == true)
        #expect(try await workspace.readFile("/a.txt") == "new new")

        let event = await iterator.next()
        #expect(event?.kind == .modified)
        #expect(event?.path == "/a.txt")
    }

    @Test
    func `disabled tracking records nothing but still emits change events`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem(), tracking: .disabled)

        let stream = await workspace.watchChanges(at: "/", recursive: true)
        var iterator = stream.makeAsyncIterator()

        try await workspace.writeFile("/note.txt", content: "one")
        try await workspace.appendFile("/note.txt", content: " two")
        try await workspace.writeData(Data([0xFF]), to: "/bin.dat")

        #expect(try await workspace.readFile("/note.txt") == "one two")
        #expect(try await workspace.mutationRecords().isEmpty)

        let event = await iterator.next()
        #expect(event?.kind == .created)
        #expect(event?.path == "/note.txt")
    }

    @Test
    func `diff size cap suppresses diffs for large contents only`() async throws {
        let workspace = Workspace(
            filesystem: InMemoryFilesystem(),
            tracking: .fullDiffs(maxDiffBytes: 16)
        )
        try await workspace.writeFile("/small.txt", content: "tiny\n")
        try await workspace.writeFile("/big.txt", content: String(repeating: "x", count: 64))

        let mutations = try await workspace.mutationRecords()
        #expect(mutations[0].fileChanges.first?.diff != nil)
        #expect(mutations[1].fileChanges.first?.diff == nil)
        #expect(mutations[1].fileChanges.first?.effect == .created)
    }

    @Test
    func `branches inherit the parent tracking policy`() async throws {
        let workspace = Workspace(filesystem: InMemoryFilesystem(), tracking: .pathsOnly)
        try await workspace.writeFile("/base.txt", content: "base")
        _ = try await workspace.createCheckpoint(label: "base")

        let branch = try await workspace.branch()
        #expect(branch.tracking == .pathsOnly)

        try await branch.writeFile("/base.txt", content: "branch")
        let mutations = try await branch.mutationRecords()
        #expect(mutations.allSatisfy { record in record.fileChanges.allSatisfy { $0.diff == nil } })
    }
}
