import Foundation

/// A labeled, parented moment in workspace history.
///
/// A `Checkpoint` records when a workspace state was captured, the parent checkpoint it follows,
/// and a compact summary of the changes relative to that parent. The actual file contents live in a
/// separate ``Snapshot`` artifact that can be loaded on demand with ``Workspace/snapshot(for:)``.
public struct Checkpoint: Sendable, Codable, Equatable {
    /// A lightweight summary of changes relative to the parent checkpoint.
    public struct Summary: Sendable, Codable, Equatable {
        /// The number of paths that differ from the parent checkpoint.
        public var changeCount: Int
        /// The paths that changed relative to the parent checkpoint.
        public var touchedPaths: [WorkspacePath]
        /// Whether any changed file paths involve UTF-8 decodable text.
        public var hasTextDiffs: Bool

        /// Creates a checkpoint summary.
        public init(changeCount: Int, touchedPaths: [WorkspacePath], hasTextDiffs: Bool) {
            self.changeCount = changeCount
            self.touchedPaths = touchedPaths
            self.hasTextDiffs = hasTextDiffs
        }
    }

    /// The checkpoint identifier.
    public var id: UUID
    /// The workspace that owns this checkpoint.
    public var workspaceId: UUID
    /// An optional human-readable label.
    public var label: String?
    /// The checkpoint creation timestamp.
    public var createdAt: Date
    /// The previous checkpoint in the same workspace, when present.
    public var parentCheckpointId: UUID?
    /// The parent workspace's head checkpoint when this workspace was branched.
    public var baseCheckpointId: UUID?
    /// The workspace that was merged to create this checkpoint, when applicable.
    public var mergedFromWorkspaceId: UUID?
    /// The merged workspace's head checkpoint when this checkpoint was created.
    public var mergedFromCheckpointId: UUID?
    /// The source checkpoint a rollback restored from when applicable.
    public var rollbackSourceCheckpointId: UUID?
    /// A summary of what changed relative to the parent checkpoint.
    public var summary: Summary

    var firstMutationSequence: Int?
    var lastMutationSequence: Int?
    var mutationCursor: Int
    var snapshotId: UUID

    var inferredEventKind: CheckpointEvent.Kind {
        if rollbackSourceCheckpointId != nil { return .rolledBack }
        if mergedFromWorkspaceId != nil { return .merged }
        return .created
    }

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        label: String?,
        createdAt: Date = Date(),
        parentCheckpointId: UUID?,
        baseCheckpointId: UUID? = nil,
        mergedFromWorkspaceId: UUID? = nil,
        mergedFromCheckpointId: UUID? = nil,
        rollbackSourceCheckpointId: UUID? = nil,
        firstMutationSequence: Int?,
        lastMutationSequence: Int?,
        mutationCursor: Int,
        snapshotId: UUID,
        summary: Summary
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.label = label
        self.createdAt = createdAt
        self.parentCheckpointId = parentCheckpointId
        self.baseCheckpointId = baseCheckpointId
        self.mergedFromWorkspaceId = mergedFromWorkspaceId
        self.mergedFromCheckpointId = mergedFromCheckpointId
        self.rollbackSourceCheckpointId = rollbackSourceCheckpointId
        self.firstMutationSequence = firstMutationSequence
        self.lastMutationSequence = lastMutationSequence
        self.mutationCursor = mutationCursor
        self.snapshotId = snapshotId
        self.summary = summary
    }
}

/// A checkpoint event emitted by ``Workspace``.
public struct CheckpointEvent: Sendable, Codable, Equatable {
    /// The event kind.
    public enum Kind: String, Sendable, Codable {
        /// A checkpoint was created.
        case created
        /// A rollback restored a prior checkpoint.
        case rolledBack
        /// A branch workspace was merged.
        case merged
    }

    /// The event kind.
    public var kind: Kind
    /// The checkpoint that triggered this event.
    public var checkpoint: Checkpoint

    /// Creates a checkpoint event.
    public init(kind: Kind, checkpoint: Checkpoint) {
        self.kind = kind
        self.checkpoint = checkpoint
    }
}
