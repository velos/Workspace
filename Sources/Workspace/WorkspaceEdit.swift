import Foundation

/// A filesystem edit that can be applied as part of a batch.
public enum WorkspaceEdit: Sendable, Equatable {
    /// Writes UTF-8 content to a file, replacing any existing contents.
    case writeFile(path: WorkspacePath, content: String)
    /// Appends UTF-8 content to a file.
    case appendFile(path: WorkspacePath, content: String)
    /// Removes a file or directory.
    case delete(path: WorkspacePath, recursive: Bool = true)
    /// Creates a directory.
    case createDirectory(path: WorkspacePath, recursive: Bool = true)
    /// Moves or renames an entry.
    case move(from: WorkspacePath, to: WorkspacePath)
    /// Copies an entry.
    case copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool = true)

    /// Whether a requested edit materially changes the workspace.
    public enum ChangeState: String, Sendable, Codable {
        /// The edit changes the workspace.
        case changed
        /// The edit leaves the workspace unchanged.
        case unchanged
    }

    /// The predicted or observed effect of a file-level change.
    public enum Effect: String, Sendable, Codable {
        /// The operation creates a new entry.
        case created
        /// The operation changes an existing entry.
        case modified
        /// The operation removes an existing entry.
        case deleted
        /// The operation moves an entry to a new path.
        case moved
        /// The operation copies an entry to a new path.
        case copied
        /// The operation leaves the filesystem unchanged.
        case unchanged
    }

    /// A file-level change contained within a batch edit result.
    public struct FileChange: Sendable {
        /// The affected file or symlink path.
        public var path: WorkspacePath
        /// The original path for move and copy operations when applicable.
        public var sourcePath: WorkspacePath?
        /// The logical kind of the affected node.
        public var kind: WorkspaceTree.Kind
        /// The predicted or observed effect of the change.
        public var effect: Effect
        /// The execution status of the change.
        public var status: MutationStatus
        /// A structured text diff when the change represents UTF-8 file content.
        public var diff: TextDiff?

        /// Creates a file-level change description.
        public init(
            path: WorkspacePath,
            sourcePath: WorkspacePath? = nil,
            kind: WorkspaceTree.Kind,
            effect: Effect,
            status: MutationStatus = .planned,
            diff: TextDiff? = nil
        ) {
            self.path = path
            self.sourcePath = sourcePath
            self.kind = kind
            self.effect = effect
            self.status = status
            self.diff = diff
        }
    }

    /// A preview or result entry for a single batch edit operation.
    public struct Entry: Sendable {
        /// The requested edit.
        public var edit: WorkspaceEdit
        /// Whether the requested edit materially changes the workspace.
        public var changeState: ChangeState
        /// The execution status of the operation.
        public var status: MutationStatus
        /// Paths touched by the edit.
        public var touchedPaths: [WorkspacePath]
        /// File-level details for text and structural file changes under this edit.
        public var fileChanges: [FileChange]

        /// Creates a batch edit entry.
        public init(
            edit: WorkspaceEdit,
            changeState: ChangeState,
            status: MutationStatus = .planned,
            touchedPaths: [WorkspacePath],
            fileChanges: [FileChange] = []
        ) {
            self.edit = edit
            self.changeState = changeState
            self.status = status
            self.touchedPaths = touchedPaths
            self.fileChanges = fileChanges
        }
    }

    /// A failure encountered while executing a single batch edit.
    public struct Failure: Sendable {
        /// The index of the failed edit in the original request.
        public var index: Int
        /// The edit that failed.
        public var edit: WorkspaceEdit
        /// A human-readable failure message.
        public var message: String

        /// Creates a batch edit failure.
        public init(index: Int, edit: WorkspaceEdit, message: String) {
            self.index = index
            self.edit = edit
            self.message = message
        }
    }

    /// The result of applying a batch of workspace edits.
    public struct Result: Sendable {
        /// Whether the operation was previewed or executed.
        public var mode: MutationMode
        /// Canonicalized paths touched by the batch.
        public var touchedPaths: [WorkspacePath]
        /// Per-edit preview or result entries.
        public var edits: [Entry]
        /// Execution failures encountered while applying the batch.
        public var failures: [Failure]
        /// Whether the batch rolled back after an error.
        public var rolledBack: Bool

        /// Creates a batch edit result.
        public init(
            mode: MutationMode,
            touchedPaths: [WorkspacePath],
            edits: [Entry],
            failures: [Failure] = [],
            rolledBack: Bool
        ) {
            self.mode = mode
            self.touchedPaths = touchedPaths
            self.edits = edits
            self.failures = failures
            self.rolledBack = rolledBack
        }
    }
}
