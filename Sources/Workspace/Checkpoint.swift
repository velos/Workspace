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

    var provenanceCheckpointID: UUID? {
        switch origin {
        case let .rollback(from): from
        case let .transaction(base): base
        case .manual, .archiveRestore: nil
        }
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

    static func orderedBefore(_ lhs: Checkpoint, _ rhs: Checkpoint) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    static func lineageHeadID(in checkpoints: [Checkpoint]) -> UUID? {
        guard !checkpoints.isEmpty else { return nil }
        let referencedParents = Set(checkpoints.compactMap(\.parentID))
        let tips = checkpoints.filter { !referencedParents.contains($0.id) }
        return (tips.isEmpty ? checkpoints : tips).max(by: orderedBefore)?.id
    }

    static func make(
        snapshot: Snapshot,
        draft: CheckpointDraft,
        parent: Checkpoint?,
        parentSnapshot: Snapshot?
    ) -> Checkpoint {
        let metadata = revisionMetadata(
            snapshot: snapshot,
            parent: parent,
            parentSnapshot: parentSnapshot,
            mutationCursor: draft.mutationCursor
        )
        return Checkpoint(
            workspaceId: draft.workspaceID,
            label: draft.label,
            parentCheckpointId: parent?.id,
            origin: draft.origin,
            firstMutationSequence: metadata.firstMutationSequence,
            lastMutationSequence: metadata.lastMutationSequence,
            mutationCursor: draft.mutationCursor,
            snapshotId: snapshot.id,
            summary: metadata.summary
        )
    }

    func rebased(to parent: Checkpoint?, snapshot: Snapshot, parentSnapshot: Snapshot?) -> Checkpoint {
        var copy = self
        copy.parentID = parent?.id
        let metadata = Self.revisionMetadata(
            snapshot: snapshot,
            parent: parent,
            parentSnapshot: parentSnapshot,
            mutationCursor: mutationCursor
        )
        copy.firstMutationSequence = metadata.firstMutationSequence
        copy.lastMutationSequence = metadata.lastMutationSequence
        copy.summary = metadata.summary
        return copy
    }

    private static func revisionMetadata(
        snapshot: Snapshot,
        parent: Checkpoint?,
        parentSnapshot: Snapshot?,
        mutationCursor: Int
    ) -> (firstMutationSequence: Int?, lastMutationSequence: Int?, summary: ChangeSet.Summary) {
        let baseline = parentSnapshot ?? Snapshot(
            rootPath: snapshot.rootPath,
            entry: .missing(.init(path: snapshot.rootPath))
        )
        let previousCursor = parent?.mutationCursor ?? 0
        return (
            mutationCursor > previousCursor ? previousCursor + 1 : nil,
            mutationCursor > previousCursor ? mutationCursor : nil,
            ChangeSet.compare(before: baseline, after: snapshot, maxTextBytes: 1_000_000).summary
        )
    }
}

struct CheckpointDraft: Sendable {
    var workspaceID: UUID
    var label: String?
    var preferredParentID: UUID?
    var origin: Checkpoint.Origin
    var mutationCursor: Int
}
