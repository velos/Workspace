import Foundation

/// A recorded filesystem mutation emitted by ``Workspace``.
///
/// Every tracked write appends one record (unless the workspace's ``Workspace/TrackingPolicy``
/// disables history). Records are ordered by `sequence`, which the checkpoint store assigns
/// monotonically per workspace.
public struct MutationRecord: Sendable, Codable, Equatable {
    /// The coarse operation kind for filtering and tooling.
    public enum Kind: String, Sendable, Codable {
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
        case restoreSnapshot
        case rollback
        case mergeWorkspace
    }

    /// The store-assigned, per-workspace monotonic sequence number.
    public internal(set) var sequence: Int
    /// The workspace that performed the mutation.
    public var workspaceId: UUID
    /// When the mutation was recorded.
    public var timestamp: Date
    /// The coarse operation kind.
    public var kind: Kind
    /// The canonicalized paths the mutation touched.
    public var touchedPaths: [WorkspacePath]
    /// Per-file effects, including text diffs when the tracking policy records them.
    public var fileChanges: [FileEdit.FileChange]
    /// A convenience diff populated when the mutation changed exactly one text file.
    public var diff: TextDiff?

    init(
        sequence: Int,
        workspaceId: UUID,
        timestamp: Date = Date(),
        kind: Kind,
        touchedPaths: [WorkspacePath],
        fileChanges: [FileEdit.FileChange],
        diff: TextDiff? = nil
    ) {
        self.sequence = sequence
        self.workspaceId = workspaceId
        self.timestamp = timestamp
        self.kind = kind
        self.touchedPaths = touchedPaths
        self.fileChanges = fileChanges
        self.diff = diff
    }
}
