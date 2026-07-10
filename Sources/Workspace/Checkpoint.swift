import Foundation

/// Metadata for a persisted workspace revision.
public struct Checkpoint: Sendable, Codable, Equatable {
    public enum Origin: Sendable, Codable, Equatable {
        case manual
        case rollback(from: UUID)
        case transaction(base: UUID?)
        case archiveRestore
    }

    public var id: UUID
    public var workspaceID: UUID
    public var label: String?
    public var createdAt: Date
    public var parentID: UUID?
    public var origin: Origin
    public var summary: ChangeSet.Summary

    // Persistence cursors and the content-addressed snapshot identifier stay behind the public API.
    var firstMutationSequence: Int?
    var lastMutationSequence: Int?
    var mutationCursor: Int
    var snapshotId: UUID

    var workspaceId: UUID { workspaceID }
    var parentCheckpointId: UUID? { parentID }
    var rollbackSourceCheckpointId: UUID? {
        if case let .rollback(from) = origin { return from }
        return nil
    }

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        label: String?,
        createdAt: Date = Date(),
        parentCheckpointId: UUID?,
        origin: Origin = .manual,
        firstMutationSequence: Int?,
        lastMutationSequence: Int?,
        mutationCursor: Int,
        snapshotId: UUID,
        summary: ChangeSet.Summary
    ) {
        self.id = id
        self.workspaceID = workspaceId
        self.label = label
        self.createdAt = createdAt
        self.parentID = parentCheckpointId
        self.origin = origin
        self.firstMutationSequence = firstMutationSequence
        self.lastMutationSequence = lastMutationSequence
        self.mutationCursor = mutationCursor
        self.snapshotId = snapshotId
        self.summary = summary
    }
}
