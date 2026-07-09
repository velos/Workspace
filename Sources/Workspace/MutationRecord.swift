import Foundation

/// A recorded filesystem mutation emitted by ``Workspace``.
struct MutationRecord: Sendable, Codable, Equatable {
    /// The coarse operation kind for filtering and tooling.
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
        case restoreSnapshot
        case rollback
        case mergeWorkspace
    }

    var sequence: Int
    var workspaceId: UUID
    var timestamp: Date
    var kind: Kind
    var touchedPaths: [WorkspacePath]
    var fileChanges: [FileEdit.FileChange]
    var diff: TextDiff?

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
