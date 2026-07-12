import Foundation

/// A recorded high-level workspace mutation.
public struct Mutation: Sendable, Codable, Equatable {
    public enum Operation: String, Sendable, Codable {
        case edit
        case rollback
        case transaction
        case archiveRestore
    }

    public internal(set) var sequence: Int
    public var workspaceID: UUID
    public var timestamp: Date
    public var operation: Operation
    public var changes: ChangeSet

    public init(
        sequence: Int,
        workspaceID: UUID,
        timestamp: Date = Date(),
        operation: Operation,
        changes: ChangeSet
    ) {
        self.sequence = sequence
        self.workspaceID = workspaceID
        self.timestamp = timestamp
        self.operation = operation
        self.changes = changes
    }
}

extension Workspace {
    /// Returns recorded mutations in ascending sequence order.
    public func history() async throws -> [Mutation] {
        try await ensureLoaded()
        return mutations
    }
}
