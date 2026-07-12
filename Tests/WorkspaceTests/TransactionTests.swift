import Foundation
import Testing
@testable import Workspace

@Suite("Transactions")
struct TransactionTests {
    @Test
    func `transaction previews and commits as one parent mutation`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/a.txt", "base\n")
        let transaction = try await workspace.beginTransaction(label: "draft")
        try await transaction.writeText("/a.txt", "draft\n")
        try await transaction.writeText("/b.txt", "new\n")

        let preview = try await transaction.preview()
        #expect(preview.statistics.changedFileCount == 2)
        #expect(try await workspace.readText("/a.txt") == "base\n")

        let commit = try await transaction.commit()
        #expect(commit.applied)
        #expect(commit.preview == preview)
        #expect(commit.checkpoint?.origin == .transaction(base: nil))
        #expect(try await workspace.readText("/a.txt") == "draft\n")
        #expect(try await workspace.history().last?.operation == .transaction)
    }

    @Test
    func `discard and no-op commit create no parent artifacts`() async throws {
        let workspace = Workspace()
        let discarded = try await workspace.beginTransaction()
        try await discarded.writeText("/x", "x")
        try await discarded.discard()
        #expect(!(await workspace.exists("/x")))

        let noOp = try await workspace.beginTransaction()
        let commit = try await noOp.commit()
        #expect(commit.applied)
        #expect(commit.checkpoint == nil)
        #expect(try await workspace.checkpoints().isEmpty)
    }

    @Test
    func `three-way commit merges non-overlapping parent changes`() async throws {
        let workspace = Workspace()
        _ = try await workspace.apply([.writeText("/a", "a0"), .writeText("/b", "b0")])
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "a1")
        try await workspace.writeText("/b", "b1")

        let commit = try await transaction.commit(strategy: .threeWay)
        #expect(commit.applied)
        #expect(try await workspace.readText("/a") == "a1")
        #expect(try await workspace.readText("/b") == "b1")
    }

    @Test
    func `conflicted transaction remains active for preview and discard`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/a", "base")
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        try await workspace.writeText("/a", "parent")

        let commit = try await transaction.commit()
        #expect(!commit.applied)
        #expect(commit.conflicts.map(\.path) == ["/a"])
        #expect(try await transaction.preview().changes.first?.path == "/a")
        try await transaction.discard()
        #expect(try await workspace.readText("/a") == "parent")
    }

    @Test
    func `strict commit rejects any parent change`() async throws {
        let workspace = Workspace()
        _ = try await workspace.apply([.writeText("/a", "a"), .writeText("/b", "b")])
        let transaction = try await workspace.beginTransaction()
        try await transaction.writeText("/a", "draft")
        try await workspace.writeText("/b", "parent")
        let commit = try await transaction.commit(strategy: .strict)
        #expect(commit.conflicts.contains { $0.kind == .parentChanged && $0.path == "/b" })
    }

    @Test
    func `scoped transaction returns value and commit`() async throws {
        let workspace = Workspace()
        let result = try await workspace.transaction { transaction in
            try await transaction.writeText("/value", "42")
            return 42
        }
        #expect(result.value == 42)
        #expect(result.commit.applied)
        #expect(try await workspace.readText("/value") == "42")
    }
}
