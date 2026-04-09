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

        /// A lightweight summary of changes relative to the parent checkpoint.
        public struct Summary: Sendable, Codable, Equatable {
            /// The number of paths that differ from the parent checkpoint.
            public var changeCount: Int
            /// The paths that changed relative to the parent checkpoint.
            public var touchedPaths: [WorkspacePath]
            /// Whether any changed file paths involve UTF-8 decodable text.
            public var hasTextDiffs: Bool
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
        /// A summary of what changed relative to the parent checkpoint.
        public var summary: Summary

        var parentCheckpointId: UUID?
        var baseSharedCheckpointId: UUID?
        var firstMutationSequence: Int?
        var lastMutationSequence: Int?
        var mutationCursor: Int
        var originSessionId: UUID?
        var rollbackSourceCheckpointId: UUID?
        var snapshotId: UUID

        var inferredEventKind: CheckpointEvent.Kind {
            if rollbackSourceCheckpointId != nil { return .rolledBack }
            if originSessionId != nil, scope == .shared { return .published }
            return .created
        }

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
            snapshotId: UUID,
            summary: Summary
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
            self.snapshotId = snapshotId
            self.summary = summary
        }
    }
}

struct MutationRecord: Sendable, Codable, Equatable {
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

    var sequence: Int
    var workspaceId: UUID
    var sessionId: UUID?
    var scope: History.Checkpoint.Scope
    var timestamp: Date
    var kind: Kind
    var touchedPaths: [WorkspacePath]
    var fileChanges: [FileEdit.FileChange]
    var diff: TextDiff?

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

/// A checkpoint event emitted by `History`.
public struct CheckpointEvent: Sendable, Codable, Equatable {
    /// The event kind.
    public enum Kind: String, Sendable, Codable {
        /// A checkpoint was created.
        case created
        /// A rollback restored a prior checkpoint.
        case rolledBack
        /// A session head was published to the shared workspace.
        case published
    }

    /// The event kind.
    public var kind: Kind
    /// The checkpoint that triggered this event.
    public var checkpoint: History.Checkpoint

    /// Creates a checkpoint event.
    public init(kind: Kind, checkpoint: History.Checkpoint) {
        self.kind = kind
        self.checkpoint = checkpoint
    }

    /// The checkpoint scope.
    public var scope: History.Checkpoint.Scope {
        checkpoint.scope
    }
}

/// Errors produced by `History` operations.
public enum HistoryError: Error, CustomStringConvertible, Sendable {
    case sessionNotFound(UUID)
    case checkpointNotFound(UUID)
    case snapshotNotFound(UUID)
    case checkpointScopeMismatch(expected: History.Checkpoint.Scope, actual: History.Checkpoint.Scope)
    case checkpointSessionMismatch(checkpointId: UUID, expectedSessionId: UUID, actualSessionId: UUID?)
    case publishConflict(sessionId: UUID, expectedBaseSharedCheckpointId: UUID?, actualSharedCheckpointId: UUID?)
    case mutationFailed(String)

    public var description: String {
        switch self {
        case let .sessionNotFound(sessionId):
            return "workspace session not found: \(sessionId.uuidString)"
        case let .checkpointNotFound(checkpointId):
            return "workspace checkpoint not found: \(checkpointId.uuidString)"
        case let .snapshotNotFound(snapshotId):
            return "workspace snapshot not found: \(snapshotId.uuidString)"
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
