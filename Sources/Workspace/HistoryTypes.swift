import Foundation

extension History {
    /// A durable checkpoint over a managed workspace or session overlay.
    public struct Checkpoint: Sendable, Codable, Equatable {
        /// The checkpoint scope.
        public enum Scope: String, Sendable, Codable {
            /// A checkpoint over a session-local overlay.
            case session
            /// A checkpoint over the shared workspace head.
            case shared
        }

        /// The checkpoint identifier.
        public var id: UUID
        /// The managed workspace identifier.
        var workspaceId: UUID
        /// The session that created or owns the checkpoint when available.
        public var sessionId: UUID?
        /// Whether the checkpoint belongs to a session overlay or the shared head.
        public var scope: Scope
        /// An optional human-readable label.
        public var label: String?
        /// The checkpoint creation timestamp.
        public var createdAt: Date
        /// The prior checkpoint in the same scope lineage.
        var parentCheckpointId: UUID?
        /// The shared checkpoint the session was based on when this checkpoint was created.
        var baseSharedCheckpointId: UUID?
        /// The first mutation sequence captured by this checkpoint, if any.
        var firstMutationSequence: Int?
        /// The last mutation sequence captured by this checkpoint, if any.
        var lastMutationSequence: Int?
        /// The latest visible mutation sequence when the checkpoint was created.
        var mutationCursor: Int
        /// The originating session for shared publish checkpoints when available.
        var originSessionId: UUID?
        /// The source checkpoint for rollback checkpoints when available.
        var rollbackSourceCheckpointId: UUID?
        /// The captured restorable workspace state for this checkpoint.
        var snapshot: Snapshot

        /// Creates a workspace checkpoint.
        init(
            id: UUID = UUID(),
            workspaceId: UUID,
            sessionId: UUID?,
            scope: Scope,
            label: String?,
            createdAt: Date = Date(),
            parentCheckpointId: UUID?,
            baseSharedCheckpointId: UUID?,
            firstMutationSequence: Int?,
            lastMutationSequence: Int?,
            mutationCursor: Int,
            originSessionId: UUID? = nil,
            rollbackSourceCheckpointId: UUID? = nil,
            snapshot: Snapshot
        ) {
            self.id = id
            self.workspaceId = workspaceId
            self.sessionId = sessionId
            self.scope = scope
            self.label = label
            self.createdAt = createdAt
            self.parentCheckpointId = parentCheckpointId
            self.baseSharedCheckpointId = baseSharedCheckpointId
            self.firstMutationSequence = firstMutationSequence
            self.lastMutationSequence = lastMutationSequence
            self.mutationCursor = mutationCursor
            self.originSessionId = originSessionId
            self.rollbackSourceCheckpointId = rollbackSourceCheckpointId
            self.snapshot = snapshot
        }
    }
}

/// A normalized mutation record stored between checkpoints.
struct MutationRecord: Sendable, Codable, Equatable {
    /// The tracked mutation kind.
    enum Kind: String, Sendable, Codable {
        case writeFile
        case appendFile
        case writeData
        case writeJSON
        case createDirectory
        case removeItem
        case copyItem
        case moveItem
        case applyEdits
        case applyReplacement
        case publishSessionHead
    }

    /// The monotonically increasing mutation sequence.
    var sequence: Int
    /// The managed workspace identifier.
    var workspaceId: UUID
    /// The originating session when available.
    var sessionId: UUID?
    /// Whether the mutation targeted a session overlay or the shared head.
    var scope: History.Checkpoint.Scope
    /// The mutation timestamp.
    var timestamp: Date
    /// The tracked mutation kind.
    var kind: Kind
    /// The canonicalized paths touched by the mutation.
    var touchedPaths: [WorkspacePath]
    /// The normalized file-level changes described by the mutation.
    var fileChanges: [FileEdit.FileChange]
    /// A primary text diff when the mutation naturally maps to one.
    var diff: TextDiff?

    /// Creates a workspace mutation record.
    init(
        sequence: Int,
        workspaceId: UUID,
        sessionId: UUID?,
        scope: History.Checkpoint.Scope,
        timestamp: Date = Date(),
        kind: Kind,
        touchedPaths: [WorkspacePath],
        fileChanges: [FileEdit.FileChange],
        diff: TextDiff? = nil
    ) {
        self.sequence = sequence
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.scope = scope
        self.timestamp = timestamp
        self.kind = kind
        self.touchedPaths = touchedPaths
        self.fileChanges = fileChanges
        self.diff = diff
    }
}

/// A durable checkpoint event emitted by `History`.
struct CheckpointEvent: Sendable, Codable, Equatable {
    /// The event kind.
    enum Kind: String, Sendable, Codable {
        /// A checkpoint was created manually.
        case created
        /// A rollback restored a prior checkpoint and emitted a new rollback checkpoint.
        case rolledBack
        /// A session head was published to the shared workspace.
        case published
    }

    /// The event kind.
    var kind: Kind
    /// The resulting checkpoint metadata.
    var checkpoint: History.Checkpoint

    /// Creates a checkpoint event.
    init(kind: Kind, checkpoint: History.Checkpoint) {
        self.kind = kind
        self.checkpoint = checkpoint
    }

    /// The managed workspace identifier.
    var workspaceId: UUID {
        checkpoint.workspaceId
    }

    /// The originating session identifier when available.
    var sessionId: UUID? {
        checkpoint.sessionId
    }

    /// The checkpoint scope.
    var scope: History.Checkpoint.Scope {
        checkpoint.scope
    }
}

/// Errors produced by session-scoped checkpointing and publish flows.
enum HistoryError: Error, CustomStringConvertible, Sendable {
    case sessionNotFound(UUID)
    case checkpointNotFound(UUID)
    case checkpointScopeMismatch(expected: History.Checkpoint.Scope, actual: History.Checkpoint.Scope)
    case checkpointSessionMismatch(checkpointId: UUID, expectedSessionId: UUID, actualSessionId: UUID?)
    case publishConflict(sessionId: UUID, expectedBaseSharedCheckpointId: UUID?, actualSharedCheckpointId: UUID?)
    case mutationFailed(String)

    /// A human-readable description of the error.
    var description: String {
        switch self {
        case let .sessionNotFound(sessionId):
            return "workspace session not found: \(sessionId.uuidString)"
        case let .checkpointNotFound(checkpointId):
            return "workspace checkpoint not found: \(checkpointId.uuidString)"
        case let .checkpointScopeMismatch(expected, actual):
            return "checkpoint scope mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case let .checkpointSessionMismatch(checkpointId, expectedSessionId, actualSessionId):
            let actual = actualSessionId?.uuidString ?? "nil"
            return "checkpoint \(checkpointId.uuidString) belongs to session \(actual), expected \(expectedSessionId.uuidString)"
        case let .publishConflict(sessionId, expectedBaseSharedCheckpointId, actualSharedCheckpointId):
            let expected = expectedBaseSharedCheckpointId?.uuidString ?? "nil"
            let actual = actualSharedCheckpointId?.uuidString ?? "nil"
            return "cannot publish session \(sessionId.uuidString): expected shared head \(expected), current shared head is \(actual)"
        case let .mutationFailed(message):
            return message
        }
    }
}
