import Foundation

// MARK: - WorkspaceTree

/// A recursive tree node returned from workspace tree traversal APIs.
public struct WorkspaceTree: Sendable {
    /// The logical kind of a node in a workspace tree.
    public enum Kind: String, Sendable, Codable {
        /// A regular file.
        case file
        /// A directory.
        case directory
        /// A symbolic link.
        case symlink
    }

    /// The normalized path for the node.
    public var path: WorkspacePath
    /// The node's kind.
    public var kind: Kind
    /// The size of the node in bytes.
    public var size: UInt64
    /// The node's POSIX permissions.
    public var permissions: Int
    /// The node's last modification timestamp when available.
    public var modificationDate: Date?
    /// Child nodes for directories when the traversal includes them.
    public var children: [WorkspaceTree]?

    /// Creates a tree node.
    public init(
        path: WorkspacePath,
        kind: Kind,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?,
        children: [WorkspaceTree]? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.modificationDate = modificationDate
        self.children = children
    }

    /// Convenience initializer that accepts a string path.
    public init(
        path: String,
        kind: Kind,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?,
        children: [WorkspaceTree]? = nil
    ) {
        self.init(
            path: WorkspacePath(normalizing: path),
            kind: kind,
            size: size,
            permissions: permissions,
            modificationDate: modificationDate,
            children: children
        )
    }
}

/// Aggregate information about a subtree in the workspace.
public struct WorkspaceTreeSummary: Sendable {
    /// A summary entry for a direct child in a tree summary.
    public struct Entry: Sendable {
        /// The normalized path for the child entry.
        public var path: WorkspacePath
        /// The child entry's kind.
        public var kind: WorkspaceTree.Kind
        /// The child entry's size in bytes.
        public var size: UInt64
        /// The child entry's POSIX permissions.
        public var permissions: Int

        /// Creates a summary entry.
        public init(path: WorkspacePath, kind: WorkspaceTree.Kind, size: UInt64, permissions: Int) {
            self.path = path
            self.kind = kind
            self.size = size
            self.permissions = permissions
        }

        /// Convenience initializer that accepts a string path.
        public init(path: String, kind: WorkspaceTree.Kind, size: UInt64, permissions: Int) {
            self.init(path: WorkspacePath(normalizing: path), kind: kind, size: size, permissions: permissions)
        }
    }

    /// The root path that was summarized.
    public var path: WorkspacePath
    /// The number of files in the summarized subtree.
    public var fileCount: Int
    /// The number of directories in the summarized subtree.
    public var directoryCount: Int
    /// The number of symlinks in the summarized subtree.
    public var symlinkCount: Int
    /// The total size in bytes across the summarized subtree.
    public var totalBytes: UInt64
    /// Direct child entries of the summarized root.
    public var children: [Entry]

    /// Creates a tree summary.
    public init(
        path: WorkspacePath,
        fileCount: Int,
        directoryCount: Int,
        symlinkCount: Int,
        totalBytes: UInt64,
        children: [Entry]
    ) {
        self.path = path
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.totalBytes = totalBytes
        self.children = children
    }

    /// Convenience initializer that accepts a string path.
    public init(
        path: String,
        fileCount: Int,
        directoryCount: Int,
        symlinkCount: Int,
        totalBytes: UInt64,
        children: [Entry]
    ) {
        self.init(
            path: WorkspacePath(normalizing: path),
            fileCount: fileCount,
            directoryCount: directoryCount,
            symlinkCount: symlinkCount,
            totalBytes: totalBytes,
            children: children
        )
    }
}

// MARK: - Mutation

/// Whether a workspace mutation was previewed or executed.
public enum MutationMode: String, Sendable, Codable {
    /// The workspace mutation was only previewed.
    case preview
    /// The workspace mutation was executed against the backing filesystem.
    case execution
}

/// The failure handling strategy used when applying a workspace mutation.
public enum MutationFailurePolicy: String, Sendable, Codable {
    /// Restore the original state when any execution step fails.
    case rollback
    /// Stop at the first failure and leave any already-applied changes in place.
    case failFast
    /// Continue after failures and report all failed steps.
    case bestEffort
}

/// The execution status for a planned or applied workspace change.
public enum MutationStatus: String, Sendable, Codable {
    /// The change was only planned during preview.
    case planned
    /// The change was successfully applied.
    case applied
    /// The change failed while being applied.
    case failed
    /// The change was applied, then reverted due to rollback.
    case rolledBack
    /// The change was never attempted because execution stopped earlier.
    case skipped
}


// MARK: - Text replacement

/// A request describing a multi-file text replacement operation.
public struct ReplacementRequest: Sendable, Equatable {
    /// The text matching strategy to apply to each candidate file.
    public enum Pattern: Sendable, Equatable {
        /// Match a literal substring.
        case literal(String, caseSensitive: Bool = true)
        /// Match a regular expression pattern using Foundation regular expression syntax.
        case regularExpression(String)
    }

    /// The base directory used to resolve relative include and exclude patterns.
    public var scope: WorkspacePath
    /// Glob patterns selecting candidate files.
    public var include: [String]
    /// Glob patterns removed from the include set after expansion.
    public var exclude: [String]
    /// The text matching strategy to apply to each candidate file.
    public var search: Pattern
    /// The replacement string or regular expression template.
    public var replacement: String

    /// Creates a replacement request.
    public init(
        scope: WorkspacePath = .root,
        include: [String],
        exclude: [String] = [],
        search: Pattern,
        replacement: String
    ) {
        self.scope = scope
        self.include = include
        self.exclude = exclude
        self.search = search
        self.replacement = replacement
    }

    /// Creates a replacement request for a single include pattern and a literal search term.
    public init(
        pattern: String,
        search: String,
        replacement: String,
        scope: WorkspacePath = .root,
        exclude: [String] = []
    ) {
        self.init(
            scope: scope,
            include: [pattern],
            exclude: exclude,
            search: .literal(search),
            replacement: replacement
        )
    }

    /// Creates a replacement request for a single include pattern.
    public init(
        pattern: String,
        search: Pattern,
        replacement: String,
        scope: WorkspacePath = .root,
        exclude: [String] = []
    ) {
        self.init(
            scope: scope,
            include: [pattern],
            exclude: exclude,
            search: search,
            replacement: replacement
        )
    }
}

/// The result of a multi-file text replacement operation.
public struct ReplacementResult: Sendable {
    /// Whether the operation was previewed or executed.
    public var mode: MutationMode
    /// The distinct paths touched by the operation.
    public var touchedPaths: [WorkspacePath]
    /// Per-file change details.
    public var changes: [Change]
    /// Execution failures encountered while applying the replacement.
    public var failures: [Failure]
    /// Whether the operation rolled back after an error.
    public var rolledBack: Bool

    /// A single-file text replacement outcome from ``Workspace/previewReplacement(_:)`` or
    /// ``Workspace/applyReplacement(_:failurePolicy:)``.
    public struct Change: Sendable {
        /// The file path that was changed.
        public var path: WorkspacePath
        /// The number of replacements applied to the file.
        public var replacements: Int
        /// The execution status of the file change.
        public var status: MutationStatus
        /// A line-based diff describing the text change.
        public var diff: TextDiff

        /// Creates a replacement change value.
        public init(
            path: WorkspacePath,
            replacements: Int,
            status: MutationStatus = .planned,
            diff: TextDiff
        ) {
            self.path = path
            self.replacements = replacements
            self.status = status
            self.diff = diff
        }

        /// Convenience initializer that accepts a string path.
        public init(
            path: String,
            replacements: Int,
            status: MutationStatus = .planned,
            diff: TextDiff
        ) {
            self.init(
                path: WorkspacePath(normalizing: path),
                replacements: replacements,
                status: status,
                diff: diff
            )
        }
    }

    /// A failure encountered while executing a single replacement write.
    public struct Failure: Sendable {
        /// The path whose replacement write failed.
        public var path: WorkspacePath
        /// A human-readable failure message.
        public var message: String

        /// Creates a replacement failure.
        public init(path: WorkspacePath, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Creates a replacement result.
    public init(
        mode: MutationMode,
        touchedPaths: [WorkspacePath],
        changes: [Change],
        failures: [Failure] = [],
        rolledBack: Bool
    ) {
        self.mode = mode
        self.touchedPaths = touchedPaths
        self.changes = changes
        self.failures = failures
        self.rolledBack = rolledBack
    }
}

// MARK: - WorkspaceTextDiff

/// A line-based diff between two text snapshots.
public struct TextDiff: Sendable, Equatable {
    /// A contiguous hunk in a structured text diff.
    public struct Hunk: Sendable, Equatable {
        /// The 1-based starting line number in the original content.
        public var oldStartLine: Int
        /// The number of original lines represented in the hunk.
        public var oldLineCount: Int
        /// The 1-based starting line number in the updated content.
        public var newStartLine: Int
        /// The number of updated lines represented in the hunk.
        public var newLineCount: Int
        /// The context and changed lines in the hunk.
        public var lines: [Line]

        /// Creates a diff hunk.
        public init(
            oldStartLine: Int,
            oldLineCount: Int,
            newStartLine: Int,
            newLineCount: Int,
            lines: [Line]
        ) {
            self.oldStartLine = oldStartLine
            self.oldLineCount = oldLineCount
            self.newStartLine = newStartLine
            self.newLineCount = newLineCount
            self.lines = lines
        }
    }

    /// A single line in a structured text diff.
    public struct Line: Sendable, Equatable {
        /// The line classification used within a text diff.
        public enum Kind: String, Sendable, Codable {
            /// A context line that is unchanged between the old and new content.
            case context
            /// A line present only in the new content.
            case added
            /// A line present only in the old content.
            case removed
        }

        /// The role of the line within the diff.
        public var kind: Kind
        /// The line content without a trailing newline character.
        public var text: String
        /// Whether the original line ended with a trailing newline.
        public var hasTrailingNewline: Bool
        /// The original 1-based line number when present.
        public var oldLineNumber: Int?
        /// The updated 1-based line number when present.
        public var newLineNumber: Int?

        /// Creates a diff line.
        public init(
            kind: Kind,
            text: String,
            hasTrailingNewline: Bool,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil
        ) {
            self.kind = kind
            self.text = text
            self.hasTrailingNewline = hasTrailingNewline
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }
    }

    /// The hunks that make up the diff.
    public var hunks: [Hunk]

    /// Creates a text diff.
    public init(hunks: [Hunk]) {
        self.hunks = hunks
    }
}

// MARK: - WorkspaceEdit

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

    /// The requested operation type for a batch edit entry.
    public enum Operation: String, Sendable, Codable {
        /// A file write that replaces the destination contents.
        case writeFile
        /// A file write that appends to the destination contents.
        case appendFile
        /// A delete operation.
        case delete
        /// A directory creation operation.
        case createDirectory
        /// A move or rename operation.
        case move
        /// A copy operation.
        case copy
    }

    /// The predicted or observed effect of a batch edit entry.
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
        /// The requested operation.
        public var operation: Operation
        /// The predicted or observed effect of the operation.
        public var effect: Effect
        /// The execution status of the operation.
        public var status: MutationStatus
        /// Paths touched by the edit.
        public var touchedPaths: [WorkspacePath]
        /// File-level details for text and structural file changes under this edit.
        public var fileChanges: [FileChange]

        /// Creates a batch edit entry.
        public init(
            operation: Operation,
            effect: Effect,
            status: MutationStatus = .planned,
            touchedPaths: [WorkspacePath],
            fileChanges: [FileChange] = []
        ) {
            self.operation = operation
            self.effect = effect
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
