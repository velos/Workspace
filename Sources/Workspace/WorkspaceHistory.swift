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
    /// Returns retained mutation records in ascending sequence order.
    ///
    /// History is read from the persistence store, so it includes records appended by other
    /// workspace instances sharing the store and throws if the stored log can't be read. The call
    /// waits for this workspace's in-flight mutating operations so it never reports a change whose
    /// record hasn't been written yet, or one that is about to be retracted.
    public func history() async throws -> [Mutation] {
        await acquireOperation()
        defer { releaseOperation() }
        try await ensureLoaded()
        try await refreshPersistedHistory()
        return mutations
    }

    /// Returns at most `limit` mutations strictly after `after`, oldest first.
    /// A zero limit returns an empty page; a negative limit throws `WorkspaceError.unsupported`.
    /// Sequence gaps are preserved.
    /// Like `history()`, waits for this instance's mutating operations and reads the store.
    public func history(after: Int, limit: Int) async throws -> [Mutation] {
        await acquireOperation()
        defer { releaseOperation() }
        return try await store.listMutations(workspaceId: workspaceId, query: .after(after, limit: limit)).records
    }

    /// Returns at most `limit` mutations strictly before `before`, newest first.
    /// Pass `nil` explicitly to start at the newest record. A zero limit returns an empty page;
    /// a negative limit throws `WorkspaceError.unsupported`. Sequence gaps are preserved.
    public func history(before: Int?, limit: Int) async throws -> [Mutation] {
        await acquireOperation()
        defer { releaseOperation() }
        return try await store.listMutations(workspaceId: workspaceId, query: .before(before, limit: limit)).records
    }

    func refreshPersistedHistory() async throws {
        // A complete suffix read may cross permanent gaps from retractions or reservations.
        // An epoch change invalidates the prefix too, including when the log is now empty.
        var page = try await store.listMutations(workspaceId: workspaceId, afterSequence: historyRefreshSequence)
        if page.retractionEpoch != historyRetractionEpoch {
            page = try await store.listMutations(workspaceId: workspaceId, afterSequence: 0)
            mutations = page.records
            historyRefreshSequence = page.records.last?.sequence ?? 0
            historyRetractionEpoch = page.retractionEpoch
        } else {
            cachePersistedMutations(page.records)
            historyRefreshSequence = max(historyRefreshSequence, page.records.last?.sequence ?? 0)
        }
    }

    func cachePersistedMutations(_ records: [Mutation]) {
        var cachedSequences = Set(mutations.map(\.sequence))
        for record in records where cachedSequences.insert(record.sequence).inserted {
            mutations.append(record)
        }
        mutations.sort { $0.sequence < $1.sequence }
    }
}
