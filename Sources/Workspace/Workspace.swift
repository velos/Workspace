import Foundation

/// The logical kind of a node in a workspace tree.
public enum WorkspaceTreeNodeKind: String, Sendable, Codable {
    /// A regular file.
    case file
    /// A directory.
    case directory
    /// A symbolic link.
    case symlink
}

/// A recursive tree node returned from workspace tree traversal APIs.
public struct WorkspaceTreeNode: Sendable {
    /// The normalized path for the node.
    public var path: WorkspacePath
    /// The node's kind.
    public var kind: WorkspaceTreeNodeKind
    /// The size of the node in bytes.
    public var size: UInt64
    /// The node's POSIX permissions.
    public var permissions: Int
    /// The node's last modification timestamp when available.
    public var modificationDate: Date?
    /// Child nodes for directories when the traversal includes them.
    public var children: [WorkspaceTreeNode]?

    /// Creates a tree node.
    public init(
        path: WorkspacePath,
        kind: WorkspaceTreeNodeKind,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?,
        children: [WorkspaceTreeNode]? = nil
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
        kind: WorkspaceTreeNodeKind,
        size: UInt64,
        permissions: Int,
        modificationDate: Date?,
        children: [WorkspaceTreeNode]? = nil
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

/// A summary entry for a direct child in a tree summary.
public struct WorkspaceTreeSummaryEntry: Sendable {
    /// The normalized path for the child entry.
    public var path: WorkspacePath
    /// The child entry's kind.
    public var kind: WorkspaceTreeNodeKind
    /// The child entry's size in bytes.
    public var size: UInt64
    /// The child entry's POSIX permissions.
    public var permissions: Int

    /// Creates a summary entry.
    public init(path: WorkspacePath, kind: WorkspaceTreeNodeKind, size: UInt64, permissions: Int) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
    }

    /// Convenience initializer that accepts a string path.
    public init(path: String, kind: WorkspaceTreeNodeKind, size: UInt64, permissions: Int) {
        self.init(path: WorkspacePath(normalizing: path), kind: kind, size: size, permissions: permissions)
    }
}

/// Aggregate information about a subtree in the workspace.
public struct WorkspaceTreeSummary: Sendable {
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
    public var children: [WorkspaceTreeSummaryEntry]

    /// Creates a tree summary.
    public init(
        path: WorkspacePath,
        fileCount: Int,
        directoryCount: Int,
        symlinkCount: Int,
        totalBytes: UInt64,
        children: [WorkspaceTreeSummaryEntry]
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
        children: [WorkspaceTreeSummaryEntry]
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

/// Whether a workspace mutation was previewed or executed.
public enum WorkspaceMutationMode: String, Sendable, Codable {
    /// The workspace mutation was only previewed.
    case preview
    /// The workspace mutation was executed against the backing filesystem.
    case execution
}

/// The failure handling strategy used when applying a workspace mutation.
public enum WorkspaceMutationFailurePolicy: String, Sendable, Codable {
    /// Restore the original state when any execution step fails.
    case rollback
    /// Stop at the first failure and leave any already-applied changes in place.
    case failFast
    /// Continue after failures and report all failed steps.
    case bestEffort
}

/// The text matching strategy used by a replacement request.
public enum WorkspaceSearchPattern: Sendable, Equatable {
    /// Match a literal substring.
    case literal(String, caseSensitive: Bool = true)
    /// Match a regular expression pattern using Foundation regular expression syntax.
    case regularExpression(String)
}

/// A request describing a multi-file text replacement operation.
public struct WorkspaceReplaceRequest: Sendable, Equatable {
    /// The base directory used to resolve relative include and exclude patterns.
    public var scope: WorkspacePath
    /// Glob patterns selecting candidate files.
    public var include: [String]
    /// Glob patterns removed from the include set after expansion.
    public var exclude: [String]
    /// The text matching strategy to apply to each candidate file.
    public var search: WorkspaceSearchPattern
    /// The replacement string or regular expression template.
    public var replacement: String

    /// Creates a replacement request.
    public init(
        scope: WorkspacePath = .root,
        include: [String],
        exclude: [String] = [],
        search: WorkspaceSearchPattern,
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
        search: WorkspaceSearchPattern,
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

/// The line classification used within a text diff.
public enum WorkspaceTextDiffLineKind: String, Sendable, Codable {
    /// A context line that is unchanged between the old and new content.
    case context
    /// A line present only in the new content.
    case added
    /// A line present only in the old content.
    case removed
}

/// The execution status for a planned or applied workspace change.
public enum WorkspaceChangeStatus: String, Sendable, Codable {
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

/// A single line in a structured text diff.
public struct WorkspaceTextDiffLine: Sendable, Equatable {
    /// The role of the line within the diff.
    public var kind: WorkspaceTextDiffLineKind
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
        kind: WorkspaceTextDiffLineKind,
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

/// A contiguous hunk in a structured text diff.
public struct WorkspaceTextDiffHunk: Sendable, Equatable {
    /// The 1-based starting line number in the original content.
    public var oldStartLine: Int
    /// The number of original lines represented in the hunk.
    public var oldLineCount: Int
    /// The 1-based starting line number in the updated content.
    public var newStartLine: Int
    /// The number of updated lines represented in the hunk.
    public var newLineCount: Int
    /// The context and changed lines in the hunk.
    public var lines: [WorkspaceTextDiffLine]

    /// Creates a diff hunk.
    public init(
        oldStartLine: Int,
        oldLineCount: Int,
        newStartLine: Int,
        newLineCount: Int,
        lines: [WorkspaceTextDiffLine]
    ) {
        self.oldStartLine = oldStartLine
        self.oldLineCount = oldLineCount
        self.newStartLine = newStartLine
        self.newLineCount = newLineCount
        self.lines = lines
    }
}

/// A line-based diff between two text snapshots.
public struct WorkspaceTextDiff: Sendable, Equatable {
    /// The hunks that make up the diff.
    public var hunks: [WorkspaceTextDiffHunk]

    /// Creates a text diff.
    public init(hunks: [WorkspaceTextDiffHunk]) {
        self.hunks = hunks
    }
}

/// A file-level change contained within a batch edit result.
public struct WorkspaceFileChange: Sendable {
    /// The affected file or symlink path.
    public var path: WorkspacePath
    /// The original path for move and copy operations when applicable.
    public var sourcePath: WorkspacePath?
    /// The logical kind of the affected node.
    public var kind: WorkspaceTreeNodeKind
    /// The predicted or observed effect of the change.
    public var effect: WorkspaceBatchEditEffect
    /// The execution status of the change.
    public var status: WorkspaceChangeStatus
    /// A structured text diff when the change represents UTF-8 file content.
    public var diff: WorkspaceTextDiff?

    /// Creates a file-level change description.
    public init(
        path: WorkspacePath,
        sourcePath: WorkspacePath? = nil,
        kind: WorkspaceTreeNodeKind,
        effect: WorkspaceBatchEditEffect,
        status: WorkspaceChangeStatus = .planned,
        diff: WorkspaceTextDiff? = nil
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.kind = kind
        self.effect = effect
        self.status = status
        self.diff = diff
    }
}

/// A single text replacement result produced by ``Workspace/previewReplacement(_:)`` or
/// ``Workspace/applyReplacement(_:failurePolicy:)``.
public struct WorkspaceTextChange: Sendable {
    /// The file path that was changed.
    public var path: WorkspacePath
    /// The number of replacements applied to the file.
    public var replacements: Int
    /// The execution status of the file change.
    public var status: WorkspaceChangeStatus
    /// A line-based diff describing the text change.
    public var diff: WorkspaceTextDiff

    /// Creates a text change result.
    public init(
        path: WorkspacePath,
        replacements: Int,
        status: WorkspaceChangeStatus = .planned,
        diff: WorkspaceTextDiff
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
        status: WorkspaceChangeStatus = .planned,
        diff: WorkspaceTextDiff
    ) {
        self.init(
            path: WorkspacePath(normalizing: path),
            replacements: replacements,
            status: status,
            diff: diff
        )
    }
}

/// The result of a multi-file text replacement operation.
public struct WorkspaceReplaceResult: Sendable {
    /// Whether the operation was previewed or executed.
    public var mode: WorkspaceMutationMode
    /// The distinct paths touched by the operation.
    public var touchedPaths: [WorkspacePath]
    /// Per-file change details.
    public var changes: [WorkspaceTextChange]
    /// Execution failures encountered while applying the replacement.
    public var failures: [WorkspaceReplaceFailure]
    /// Whether the operation rolled back after an error.
    public var rolledBack: Bool

    /// Creates a replacement result.
    public init(
        mode: WorkspaceMutationMode,
        touchedPaths: [WorkspacePath],
        changes: [WorkspaceTextChange],
        failures: [WorkspaceReplaceFailure] = [],
        rolledBack: Bool
    ) {
        self.mode = mode
        self.touchedPaths = touchedPaths
        self.changes = changes
        self.failures = failures
        self.rolledBack = rolledBack
    }
}

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
}

/// The requested operation type for a batch edit entry.
public enum WorkspaceBatchEditOperation: String, Sendable, Codable {
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
public enum WorkspaceBatchEditEffect: String, Sendable, Codable {
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

/// A preview or result entry for a single batch edit operation.
public struct WorkspaceBatchEditEntry: Sendable {
    /// The requested operation.
    public var operation: WorkspaceBatchEditOperation
    /// The predicted or observed effect of the operation.
    public var effect: WorkspaceBatchEditEffect
    /// The execution status of the operation.
    public var status: WorkspaceChangeStatus
    /// Paths touched by the edit.
    public var touchedPaths: [WorkspacePath]
    /// File-level details for text and structural file changes under this edit.
    public var fileChanges: [WorkspaceFileChange]

    /// Creates a batch edit entry.
    public init(
        operation: WorkspaceBatchEditOperation,
        effect: WorkspaceBatchEditEffect,
        status: WorkspaceChangeStatus = .planned,
        touchedPaths: [WorkspacePath],
        fileChanges: [WorkspaceFileChange] = []
    ) {
        self.operation = operation
        self.effect = effect
        self.status = status
        self.touchedPaths = touchedPaths
        self.fileChanges = fileChanges
    }
}

/// A failure encountered while executing a single replacement write.
public struct WorkspaceReplaceFailure: Sendable {
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

/// A failure encountered while executing a single batch edit.
public struct WorkspaceBatchEditFailure: Sendable {
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
public struct WorkspaceBatchEditResult: Sendable {
    /// Whether the operation was previewed or executed.
    public var mode: WorkspaceMutationMode
    /// Canonicalized paths touched by the batch.
    public var touchedPaths: [WorkspacePath]
    /// Per-edit preview or result entries.
    public var edits: [WorkspaceBatchEditEntry]
    /// Execution failures encountered while applying the batch.
    public var failures: [WorkspaceBatchEditFailure]
    /// Whether the batch rolled back after an error.
    public var rolledBack: Bool

    /// Creates a batch edit result.
    public init(
        mode: WorkspaceMutationMode,
        touchedPaths: [WorkspacePath],
        edits: [WorkspaceBatchEditEntry],
        failures: [WorkspaceBatchEditFailure] = [],
        rolledBack: Bool
    ) {
        self.mode = mode
        self.touchedPaths = touchedPaths
        self.edits = edits
        self.failures = failures
        self.rolledBack = rolledBack
    }
}

/// A high-level API for reading, editing, and summarizing a workspace.
public actor Workspace {
    private let filesystem: any WorkspaceFilesystem

    /// Creates a workspace backed by `filesystem`.
    public init(filesystem: any WorkspaceFilesystem) {
        self.filesystem = filesystem
    }

    /// Reads a UTF-8 file from the workspace.
    public func readFile(_ path: WorkspacePath) async throws -> String {
        let data = try await filesystem.readFile(path: path)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.unsupported("file is not valid UTF-8: \(path)")
        }
        return string
    }

    /// Convenience overload for ``Workspace/readFile(_:)`` that accepts a string path.
    public func readFile(_ path: String) async throws -> String {
        try await readFile(WorkspacePath(validating: path))
    }

    /// Writes UTF-8 text to a file, replacing any existing contents.
    public func writeFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: path, data: Data(content.utf8), append: false)
    }

    /// Convenience overload for ``Workspace/writeFile(_:content:)`` that accepts a string path.
    public func writeFile(_ path: String, content: String) async throws {
        try await writeFile(WorkspacePath(validating: path), content: content)
    }

    /// Appends UTF-8 text to a file.
    public func appendFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: path, data: Data(content.utf8), append: true)
    }

    /// Convenience overload for ``Workspace/appendFile(_:content:)`` that accepts a string path.
    public func appendFile(_ path: String, content: String) async throws {
        try await appendFile(WorkspacePath(validating: path), content: content)
    }

    /// Reads and decodes JSON from a UTF-8 file.
    public func readJson<T: Decodable>(
        _ path: WorkspacePath,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await filesystem.readFile(path: path)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WorkspaceError.unsupported("invalid JSON: \(path)")
        }
    }

    /// Convenience overload for ``Workspace/readJson(_:as:)`` that accepts a string path.
    public func readJson<T: Decodable>(
        _ path: String,
        as type: T.Type = T.self
    ) async throws -> T {
        try await readJson(WorkspacePath(validating: path), as: type)
    }

    /// Encodes a value as JSON and writes it to a file.
    public func writeJson<T: Encodable>(
        _ path: WorkspacePath,
        value: T,
        prettyPrinted: Bool = true
    ) async throws {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        try await filesystem.writeFile(path: path, data: data, append: false)
    }

    /// Convenience overload for ``Workspace/writeJson(_:value:prettyPrinted:)`` that accepts a string path.
    public func writeJson<T: Encodable>(
        _ path: String,
        value: T,
        prettyPrinted: Bool = true
    ) async throws {
        try await writeJson(WorkspacePath(validating: path), value: value, prettyPrinted: prettyPrinted)
    }

    /// Returns whether an entry exists at `path`.
    public func exists(_ path: WorkspacePath) async -> Bool {
        await filesystem.exists(path: path)
    }

    /// Convenience overload for ``Workspace/exists(_:)`` that accepts a string path.
    public func exists(_ path: String) async -> Bool {
        guard let path = WorkspacePath(path) else {
            return false
        }
        return await exists(path)
    }

    /// Returns metadata for the entry at `path`.
    public func stat(_ path: WorkspacePath) async throws -> FileInfo {
        try await filesystem.stat(path: path)
    }

    /// Convenience overload for ``Workspace/stat(_:)`` that accepts a string path.
    public func stat(_ path: String) async throws -> FileInfo {
        try await stat(WorkspacePath(validating: path))
    }

    /// Lists the direct children of the directory at `path`.
    public func readdir(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await filesystem.listDirectory(path: path)
    }

    /// Convenience overload for ``Workspace/readdir(_:)`` that accepts a string path.
    public func readdir(_ path: String) async throws -> [DirectoryEntry] {
        try await readdir(WorkspacePath(validating: path))
    }

    /// Expands a glob pattern relative to `currentDirectory`.
    public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
        try await filesystem.glob(
            pattern: pattern,
            currentDirectory: currentDirectory
        )
    }

    /// Convenience overload for ``Workspace/glob(_:currentDirectory:)`` that accepts a string current directory.
    public func glob(_ pattern: String, currentDirectory: String) async throws -> [WorkspacePath] {
        try await glob(pattern, currentDirectory: WorkspacePath(validating: currentDirectory))
    }

    /// Creates a directory at `path`.
    public func mkdir(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.createDirectory(path: path, recursive: recursive)
    }

    /// Convenience overload for ``Workspace/mkdir(_:recursive:)`` that accepts a string path.
    public func mkdir(_ path: String, recursive: Bool = true) async throws {
        try await mkdir(WorkspacePath(validating: path), recursive: recursive)
    }

    /// Removes the entry at `path`.
    public func rm(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.remove(path: path, recursive: recursive)
    }

    /// Convenience overload for ``Workspace/rm(_:recursive:)`` that accepts a string path.
    public func rm(_ path: String, recursive: Bool = true) async throws {
        try await rm(WorkspacePath(validating: path), recursive: recursive)
    }

    /// Copies an entry from `sourcePath` to `destinationPath`.
    public func cp(_ sourcePath: WorkspacePath, _ destinationPath: WorkspacePath, recursive: Bool = true)
        async throws
    {
        try await filesystem.copy(
            from: sourcePath,
            to: destinationPath,
            recursive: recursive
        )
    }

    /// Convenience overload for ``Workspace/cp(_:_:recursive:)`` that accepts string paths.
    public func cp(_ sourcePath: String, _ destinationPath: String, recursive: Bool = true) async throws {
        try await cp(
            WorkspacePath(validating: sourcePath),
            WorkspacePath(validating: destinationPath),
            recursive: recursive
        )
    }

    /// Moves or renames an entry from `sourcePath` to `destinationPath`.
    public func mv(_ sourcePath: WorkspacePath, _ destinationPath: WorkspacePath) async throws {
        try await filesystem.move(
            from: sourcePath,
            to: destinationPath
        )
    }

    /// Convenience overload for ``Workspace/mv(_:_:)`` that accepts string paths.
    public func mv(_ sourcePath: String, _ destinationPath: String) async throws {
        try await mv(WorkspacePath(validating: sourcePath), WorkspacePath(validating: destinationPath))
    }

    /// Builds a recursive tree representation for the entry at `path`.
    public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await buildTree(path: path, depth: 0, maxDepth: maxDepth)
    }

    /// Convenience overload for ``Workspace/walkTree(_:maxDepth:)`` that accepts a string path.
    public func walkTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await walkTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    /// Summarizes the subtree rooted at `path`.
    public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await buildSummary(path: path, depth: 0, maxDepth: maxDepth)
    }

    /// Convenience overload for ``Workspace/summarizeTree(_:maxDepth:)`` that accepts a string path.
    public func summarizeTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await summarizeTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    private struct PlannedReplacement {
        var change: WorkspaceTextChange
        var updatedContent: String
    }

    private struct PlannedBatchEdit {
        var edit: WorkspaceEdit
        var entry: WorkspaceBatchEditEntry
    }

    private struct DiffToken: Hashable {
        var text: String
        var hasTrailingNewline: Bool
    }

    /// Returns a preview of a replacement request without mutating the workspace.
    public func previewReplacement(_ request: WorkspaceReplaceRequest) async throws -> WorkspaceReplaceResult {
        let changes = try await plannedReplacementChanges(for: request).map(\.change)
        return WorkspaceReplaceResult(
            mode: .preview,
            touchedPaths: canonicalizedTouchedPaths(for: changes),
            changes: changes,
            rolledBack: false
        )
    }

    /// Applies a replacement request across matching files.
    ///
    /// - Parameters:
    ///   - request: The replacement request to execute.
    ///   - failurePolicy: The behavior to use when a write fails.
    public func applyReplacement(
        _ request: WorkspaceReplaceRequest,
        failurePolicy: WorkspaceMutationFailurePolicy = .rollback
    ) async throws -> WorkspaceReplaceResult {
        let plannedChanges = try await plannedReplacementChanges(for: request)
        var changes = plannedChanges.map(\.change)
        let touchedPaths = canonicalizedTouchedPaths(for: changes)

        guard !changes.isEmpty else {
            return WorkspaceReplaceResult(
                mode: .execution,
                touchedPaths: touchedPaths,
                changes: changes,
                rolledBack: false
            )
        }

        let snapshots = failurePolicy == .rollback ? try await snapshotPaths(touchedPaths) : []
        var failures: [WorkspaceReplaceFailure] = []
        var appliedIndices: [Int] = []

        for (index, plannedChange) in plannedChanges.enumerated() {
            do {
                try await write(change: plannedChange, to: filesystem)
                changes[index].status = .applied
                appliedIndices.append(index)
            } catch {
                changes[index].status = .failed
                let failure = WorkspaceReplaceFailure(path: plannedChange.change.path, message: describe(error))
                if failurePolicy == .rollback {
                    try await rollback(snapshots)
                    for appliedIndex in appliedIndices {
                        changes[appliedIndex].status = .rolledBack
                    }
                    for skippedIndex in changes.indices where skippedIndex > index {
                        changes[skippedIndex].status = .skipped
                    }
                    return WorkspaceReplaceResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        changes: changes,
                        failures: [failure],
                        rolledBack: true
                    )
                }

                failures.append(failure)
                if failurePolicy == .failFast {
                    for skippedIndex in changes.indices where skippedIndex > index {
                        changes[skippedIndex].status = .skipped
                    }
                    return WorkspaceReplaceResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        changes: changes,
                        failures: failures,
                        rolledBack: false
                    )
                }
            }
        }

        return WorkspaceReplaceResult(
            mode: .execution,
            touchedPaths: touchedPaths,
            changes: changes,
            failures: failures,
            rolledBack: false
        )
    }

    /// Returns a preview of a batch edit request without mutating the workspace.
    public func previewEdits(_ edits: [WorkspaceEdit]) async throws -> WorkspaceBatchEditResult {
        let plannedEdits = try await planBatchEdits(edits)
        return WorkspaceBatchEditResult(
            mode: .preview,
            touchedPaths: canonicalizedTouchedPaths(for: edits),
            edits: plannedEdits.map(\.entry),
            rolledBack: false
        )
    }

    /// Applies a batch of filesystem edits.
    ///
    /// - Parameters:
    ///   - edits: The edits to execute.
    ///   - failurePolicy: The behavior to use when an edit fails.
    public func applyEdits(
        _ edits: [WorkspaceEdit],
        failurePolicy: WorkspaceMutationFailurePolicy = .rollback
    ) async throws -> WorkspaceBatchEditResult {
        let touchedPaths = canonicalizedTouchedPaths(for: edits)
        let plannedEdits = try await planBatchEdits(edits)
        var executionEntries = plannedEdits.map(\.entry)

        guard !plannedEdits.isEmpty else {
            return WorkspaceBatchEditResult(
                mode: .execution,
                touchedPaths: touchedPaths,
                edits: executionEntries,
                rolledBack: false
            )
        }

        let snapshots = failurePolicy == .rollback ? try await snapshotPaths(touchedPaths) : []
        var failures: [WorkspaceBatchEditFailure] = []
        var appliedIndices: [Int] = []

        for (index, plannedEdit) in plannedEdits.enumerated() {
            do {
                try await apply(plannedEdit.edit, on: filesystem)
                setStatus(.applied, for: &executionEntries[index])
                appliedIndices.append(index)
            } catch {
                setStatus(.failed, for: &executionEntries[index])
                let failure = WorkspaceBatchEditFailure(
                    index: index,
                    edit: plannedEdit.edit,
                    message: describe(error)
                )
                if failurePolicy == .rollback {
                    try await rollback(snapshots)
                    for appliedIndex in appliedIndices {
                        setStatus(.rolledBack, for: &executionEntries[appliedIndex])
                    }
                    for skippedIndex in executionEntries.indices where skippedIndex > index {
                        setStatus(.skipped, for: &executionEntries[skippedIndex])
                    }
                    return WorkspaceBatchEditResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        edits: executionEntries,
                        failures: [failure],
                        rolledBack: true
                    )
                }

                failures.append(failure)
                if failurePolicy == .failFast {
                    for skippedIndex in executionEntries.indices where skippedIndex > index {
                        setStatus(.skipped, for: &executionEntries[skippedIndex])
                    }
                    return WorkspaceBatchEditResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        edits: executionEntries,
                        failures: failures,
                        rolledBack: false
                    )
                }
            }
        }

        return WorkspaceBatchEditResult(
            mode: .execution,
            touchedPaths: touchedPaths,
            edits: executionEntries,
            failures: failures,
            rolledBack: false
        )
    }

    private func readUTF8IfPresent(
        _ path: WorkspacePath,
        on target: any WorkspaceFilesystem,
        strictInvalidUTF8: Bool = true
    ) async throws -> String? {
        guard await target.exists(path: path) else {
            return nil
        }
        let info = try await target.stat(path: path)
        guard !info.isDirectory else {
            return nil
        }
        let data = try await target.readFile(path: path)
        guard let string = String(data: data, encoding: .utf8) else {
            if strictInvalidUTF8 {
                throw WorkspaceError.unsupported("file is not valid UTF-8: \(path)")
            }
            return nil
        }
        return string
    }

    private func buildTree(path: WorkspacePath, depth: Int, maxDepth: Int?) async throws -> WorkspaceTreeNode {
        let info = try await filesystem.stat(path: path)
        let kind = treeKind(for: info)
        let children: [WorkspaceTreeNode]?

        if info.isDirectory, maxDepth.map({ depth < $0 }) ?? true {
            let entries = try await filesystem.listDirectory(path: path)
            children = try await entries
                .sorted { $0.name < $1.name }
                .asyncMap { [self] entry in
                    try await self.buildTree(
                        path: path.appending(entry.name),
                        depth: depth + 1,
                        maxDepth: maxDepth
                    )
                }
        } else {
            children = nil
        }

        return WorkspaceTreeNode(
            path: path,
            kind: kind,
            size: info.size,
            permissions: info.permissions,
            modificationDate: info.modificationDate,
            children: children
        )
    }

    private func buildSummary(path: WorkspacePath, depth: Int, maxDepth: Int?) async throws -> WorkspaceTreeSummary {
        let info = try await filesystem.stat(path: path)
        var fileCount = info.isDirectory ? 0 : 1
        var directoryCount = info.isDirectory ? 1 : 0
        var symlinkCount = info.isSymbolicLink ? 1 : 0
        var totalBytes = info.size
        var childSummaries: [WorkspaceTreeSummaryEntry] = []

        if info.isDirectory, maxDepth.map({ depth < $0 }) ?? true {
            let entries = try await filesystem.listDirectory(path: path)
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let childPath = path.appending(entry.name)
                let childSummary = try await buildSummary(path: childPath, depth: depth + 1, maxDepth: maxDepth)
                fileCount += childSummary.fileCount
                directoryCount += childSummary.directoryCount
                symlinkCount += childSummary.symlinkCount
                totalBytes += childSummary.totalBytes
                childSummaries.append(
                    WorkspaceTreeSummaryEntry(
                        path: childPath,
                        kind: treeKind(for: entry.info),
                        size: entry.info.size,
                        permissions: entry.info.permissions
                    )
                )
            }
        }

        return WorkspaceTreeSummary(
            path: path,
            fileCount: fileCount,
            directoryCount: directoryCount,
            symlinkCount: symlinkCount,
            totalBytes: totalBytes,
            children: childSummaries
        )
    }

    private func treeKind(for info: FileInfo) -> WorkspaceTreeNodeKind {
        if info.isDirectory {
            return .directory
        }
        if info.isSymbolicLink {
            return .symlink
        }
        return .file
    }

    private func touchedPaths(for edit: WorkspaceEdit) -> [WorkspacePath] {
        switch edit {
        case let .writeFile(path, _):
            return [path]
        case let .appendFile(path, _):
            return [path]
        case let .delete(path, _):
            return [path]
        case let .createDirectory(path, _):
            return [path]
        case let .move(from, to):
            return [from, to]
        case let .copy(from, to, _):
            return [from, to]
        }
    }

    private func canonicalizedTouchedPaths(for changes: [WorkspaceTextChange]) -> [WorkspacePath] {
        Array(Set(changes.map(\.path))).sorted()
    }

    private func canonicalizedTouchedPaths(for edits: [WorkspaceEdit]) -> [WorkspacePath] {
        let paths = Set(edits.flatMap(touchedPaths(for:)))
        return paths.sorted().filter { candidate in
            !paths.contains { other in
                other != candidate && candidate.string.hasPrefix(other.string + "/")
            }
        }
    }

    private func statIfPresent(_ path: WorkspacePath) async throws -> FileInfo? {
        try await statIfPresent(path, on: filesystem)
    }

    private func statIfPresent(_ path: WorkspacePath, on target: any WorkspaceFilesystem) async throws -> FileInfo? {
        guard await target.exists(path: path) else {
            return nil
        }
        return try await target.stat(path: path)
    }

    private func plannedReplacementChanges(for request: WorkspaceReplaceRequest) async throws -> [PlannedReplacement] {
        let paths = try await matchedPaths(for: request)
        var changes: [PlannedReplacement] = []

        for path in paths {
            guard let originalContent = try await readUTF8IfPresent(path, on: filesystem) else {
                continue
            }

            let replacement = try replacement(
                in: originalContent,
                matching: request.search,
                replacement: request.replacement
            )
            guard replacement.count > 0 else {
                continue
            }

            changes.append(
                PlannedReplacement(
                    change: WorkspaceTextChange(
                        path: path,
                        replacements: replacement.count,
                        diff: textDiff(from: originalContent, to: replacement.updatedContent)
                    ),
                    updatedContent: replacement.updatedContent
                )
            )
        }

        return changes
    }

    private func matchedPaths(for request: WorkspaceReplaceRequest) async throws -> [WorkspacePath] {
        let included = try await expandedPaths(for: request.include, currentDirectory: request.scope)
        guard !included.isEmpty else {
            return []
        }

        let excluded = Set(try await expandedPaths(for: request.exclude, currentDirectory: request.scope))
        return included.filter { !excluded.contains($0) }
    }

    private func expandedPaths(
        for patterns: [String],
        currentDirectory: WorkspacePath
    ) async throws -> [WorkspacePath] {
        var matched: Set<WorkspacePath> = []
        for pattern in patterns {
            let paths = try await filesystem.glob(pattern: pattern, currentDirectory: currentDirectory)
            matched.formUnion(paths)
        }
        return matched.sorted()
    }

    private func replacement(
        in content: String,
        matching pattern: WorkspaceSearchPattern,
        replacement: String
    ) throws -> (count: Int, updatedContent: String) {
        switch pattern {
        case let .literal(search, caseSensitive):
            guard !search.isEmpty else {
                throw WorkspaceError.unsupported("search pattern must not be empty")
            }

            if caseSensitive {
                let count = content.components(separatedBy: search).count - 1
                let updated = content.replacingOccurrences(of: search, with: replacement)
                return (count, updated)
            }

            let regex = try NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: search),
                options: [.caseInsensitive]
            )
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            return (
                regex.numberOfMatches(in: content, range: range),
                regex.stringByReplacingMatches(
                    in: content,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
            )
        case let .regularExpression(expression):
            guard !expression.isEmpty else {
                throw WorkspaceError.unsupported("search pattern must not be empty")
            }

            let regex = try NSRegularExpression(pattern: expression)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            return (
                regex.numberOfMatches(in: content, range: range),
                regex.stringByReplacingMatches(
                    in: content,
                    range: range,
                    withTemplate: replacement
                )
            )
        }
    }

    private func planBatchEdits(_ edits: [WorkspaceEdit]) async throws -> [PlannedBatchEdit] {
        let planningFilesystem = try await makePlanningFilesystem(for: canonicalizedTouchedPaths(for: edits))
        var plannedEdits: [PlannedBatchEdit] = []

        for edit in edits {
            let entry = try await planEntry(for: edit, on: planningFilesystem)
            plannedEdits.append(PlannedBatchEdit(edit: edit, entry: entry))
            try? await apply(edit, on: planningFilesystem)
        }

        return plannedEdits
    }

    private func makePlanningFilesystem(for paths: [WorkspacePath]) async throws -> InMemoryFilesystem {
        let planningFilesystem = InMemoryFilesystem()
        let snapshots = try await snapshotPaths(paths)
        for snapshot in snapshots {
            try await restore(snapshot, on: planningFilesystem)
        }
        return planningFilesystem
    }

    private func planEntry(
        for edit: WorkspaceEdit,
        on target: any WorkspaceFilesystem
    ) async throws -> WorkspaceBatchEditEntry {
        switch edit {
        case let .writeFile(path, content):
            let original = try await readUTF8IfPresent(path, on: target)
            let info = try await statIfPresent(path, on: target)
            return WorkspaceBatchEditEntry(
                operation: .writeFile,
                effect: effect(forOriginalContent: original, updatedContent: content),
                touchedPaths: [path],
                fileChanges: [
                    textFileChange(
                        path: path,
                        kind: info.map(treeKind(for:)) ?? .file,
                        originalContent: original,
                        updatedContent: content
                    )
                ]
            )
        case let .appendFile(path, content):
            let original = try await readUTF8IfPresent(path, on: target)
            let updated = (original ?? "") + content
            let info = try await statIfPresent(path, on: target)
            return WorkspaceBatchEditEntry(
                operation: .appendFile,
                effect: effect(forOriginalContent: original, updatedContent: updated),
                touchedPaths: [path],
                fileChanges: [
                    textFileChange(
                        path: path,
                        kind: info.map(treeKind(for:)) ?? .file,
                        originalContent: original,
                        updatedContent: updated
                    )
                ]
            )
        case let .delete(path, _):
            let existing = try await statIfPresent(path, on: target)
            return WorkspaceBatchEditEntry(
                operation: .delete,
                effect: existing == nil ? .unchanged : .deleted,
                touchedPaths: [path],
                fileChanges: try await deletionFileChanges(at: path, on: target)
            )
        case let .createDirectory(path, _):
            let existing = try await statIfPresent(path, on: target)
            return WorkspaceBatchEditEntry(
                operation: .createDirectory,
                effect: existing == nil ? .created : .unchanged,
                touchedPaths: [path]
            )
        case let .move(from, to):
            return WorkspaceBatchEditEntry(
                operation: .move,
                effect: from == to ? .unchanged : .moved,
                touchedPaths: [from, to],
                fileChanges: from == to ? [] : try await transferFileChanges(from: from, to: to, effect: .moved, on: target)
            )
        case let .copy(from, to, _):
            return WorkspaceBatchEditEntry(
                operation: .copy,
                effect: .copied,
                touchedPaths: [from, to],
                fileChanges: try await transferFileChanges(from: from, to: to, effect: .copied, on: target)
            )
        }
    }

    private func effect(forOriginalContent originalContent: String?, updatedContent: String) -> WorkspaceBatchEditEffect {
        guard let originalContent else {
            return .created
        }
        return originalContent == updatedContent ? .unchanged : .modified
    }

    private func textFileChange(
        path: WorkspacePath,
        kind: WorkspaceTreeNodeKind,
        originalContent: String?,
        updatedContent: String
    ) -> WorkspaceFileChange {
        WorkspaceFileChange(
            path: path,
            kind: kind,
            effect: effect(forOriginalContent: originalContent, updatedContent: updatedContent),
            diff: textDiff(from: originalContent ?? "", to: updatedContent)
        )
    }

    private func deletionFileChanges(
        at path: WorkspacePath,
        on target: any WorkspaceFilesystem
    ) async throws -> [WorkspaceFileChange] {
        guard let info = try await statIfPresent(path, on: target) else {
            return []
        }

        if info.isDirectory {
            let entries = try await target.listDirectory(path: path)
            var fileChanges: [WorkspaceFileChange] = []
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                fileChanges += try await deletionFileChanges(at: path.appending(entry.name), on: target)
            }
            return fileChanges
        }

        let diff: WorkspaceTextDiff?
        if info.isSymbolicLink {
            diff = nil
        } else if let originalContent = try await readUTF8IfPresent(
            path,
            on: target,
            strictInvalidUTF8: false
        ) {
            diff = textDiff(from: originalContent, to: "")
        } else {
            diff = nil
        }

        return [
            WorkspaceFileChange(
                path: path,
                kind: treeKind(for: info),
                effect: .deleted,
                diff: diff
            )
        ]
    }

    private func transferFileChanges(
        from sourcePath: WorkspacePath,
        to destinationPath: WorkspacePath,
        effect: WorkspaceBatchEditEffect,
        on target: any WorkspaceFilesystem
    ) async throws -> [WorkspaceFileChange] {
        guard let info = try await statIfPresent(sourcePath, on: target) else {
            return []
        }

        if info.isDirectory {
            let entries = try await target.listDirectory(path: sourcePath)
            var fileChanges: [WorkspaceFileChange] = []
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                fileChanges += try await transferFileChanges(
                    from: sourcePath.appending(entry.name),
                    to: destinationPath.appending(entry.name),
                    effect: effect,
                    on: target
                )
            }
            return fileChanges
        }

        return [
            WorkspaceFileChange(
                path: destinationPath,
                sourcePath: sourcePath,
                kind: treeKind(for: info),
                effect: effect
            )
        ]
    }

    private func write(change: PlannedReplacement, to target: any WorkspaceFilesystem) async throws {
        try await target.writeFile(
            path: change.change.path,
            data: Data(change.updatedContent.utf8),
            append: false
        )
    }

    private func apply(_ edit: WorkspaceEdit, on target: any WorkspaceFilesystem) async throws {
        switch edit {
        case let .writeFile(path, content):
            try await target.writeFile(path: path, data: Data(content.utf8), append: false)
        case let .appendFile(path, content):
            try await target.writeFile(path: path, data: Data(content.utf8), append: true)
        case let .delete(path, recursive):
            try await target.remove(path: path, recursive: recursive)
        case let .createDirectory(path, recursive):
            try await target.createDirectory(path: path, recursive: recursive)
        case let .move(from, to):
            try await target.move(from: from, to: to)
        case let .copy(from, to, recursive):
            try await target.copy(from: from, to: to, recursive: recursive)
        }
    }

    private func setStatus(_ status: WorkspaceChangeStatus, for entry: inout WorkspaceBatchEditEntry) {
        entry.status = status
        for index in entry.fileChanges.indices {
            entry.fileChanges[index].status = status
        }
    }

    private func textDiff(from originalContent: String, to updatedContent: String) -> WorkspaceTextDiff {
        let originalLines = diffTokens(in: originalContent)
        let updatedLines = diffTokens(in: updatedContent)
        let changes = Array(updatedLines.difference(from: originalLines))

        let removals = Dictionary(grouping: changes.compactMap { change in
            if case let .remove(offset, element, _) = change {
                return (offset, element)
            }
            return nil
        }, by: \.0)

        let insertions = Dictionary(grouping: changes.compactMap { change in
            if case let .insert(offset, element, _) = change {
                return (offset, element)
            }
            return nil
        }, by: \.0)

        var lines: [WorkspaceTextDiffLine] = []
        var originalIndex = 0
        var updatedIndex = 0
        var originalLineNumber = 1
        var updatedLineNumber = 1

        while originalIndex < originalLines.count || updatedIndex < updatedLines.count {
            if let removed = removals[originalIndex] {
                for (_, token) in removed {
                    lines.append(
                        WorkspaceTextDiffLine(
                            kind: .removed,
                            text: token.text,
                            hasTrailingNewline: token.hasTrailingNewline,
                            oldLineNumber: originalLineNumber
                        )
                    )
                    originalIndex += 1
                    originalLineNumber += 1
                }
                continue
            }

            if let inserted = insertions[updatedIndex] {
                for (_, token) in inserted {
                    lines.append(
                        WorkspaceTextDiffLine(
                            kind: .added,
                            text: token.text,
                            hasTrailingNewline: token.hasTrailingNewline,
                            newLineNumber: updatedLineNumber
                        )
                    )
                    updatedIndex += 1
                    updatedLineNumber += 1
                }
                continue
            }

            guard originalIndex < originalLines.count, updatedIndex < updatedLines.count else {
                break
            }

            let updatedLine = updatedLines[updatedIndex]
            lines.append(
                WorkspaceTextDiffLine(
                    kind: .context,
                    text: updatedLine.text,
                    hasTrailingNewline: updatedLine.hasTrailingNewline,
                    oldLineNumber: originalLineNumber,
                    newLineNumber: updatedLineNumber
                )
            )
            originalIndex += 1
            updatedIndex += 1
            originalLineNumber += 1
            updatedLineNumber += 1
        }

        let changedIndices = lines.indices.filter { lines[$0].kind != .context }
        guard !changedIndices.isEmpty else {
            return WorkspaceTextDiff(hunks: [])
        }

        var ranges: [Range<Int>] = []
        for index in changedIndices {
            let lowerBound = max(0, index - 3)
            let upperBound = min(lines.count, index + 4)
            if let last = ranges.last, lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upperBound)
            } else {
                ranges.append(lowerBound..<upperBound)
            }
        }

        let hunks = ranges.map { range in
            let hunkLines = Array(lines[range])
            let originalLineNumbers = hunkLines.compactMap(\.oldLineNumber)
            let updatedLineNumbers = hunkLines.compactMap(\.newLineNumber)
            return WorkspaceTextDiffHunk(
                oldStartLine: originalLineNumbers.first ?? 1,
                oldLineCount: originalLineNumbers.count,
                newStartLine: updatedLineNumbers.first ?? 1,
                newLineCount: updatedLineNumbers.count,
                lines: hunkLines
            )
        }

        return WorkspaceTextDiff(hunks: hunks)
    }

    private func diffTokens(in text: String) -> [DiffToken] {
        guard !text.isEmpty else {
            return []
        }

        var tokens: [DiffToken] = []
        var current = ""
        for character in text {
            if character == "\n" {
                tokens.append(DiffToken(text: current, hasTrailingNewline: true))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty || text.last != "\n" {
            tokens.append(DiffToken(text: current, hasTrailingNewline: false))
        }

        return tokens
    }

    private func describe(_ error: any Error) -> String {
        if let error = error as? WorkspaceError {
            return error.description
        }
        return String(describing: error)
    }

    private enum SnapshotEntry: Sendable {
        case missing(path: WorkspacePath)
        case file(path: WorkspacePath, data: Data, permissions: Int)
        case directory(path: WorkspacePath, permissions: Int, children: [SnapshotEntry])
        case symlink(path: WorkspacePath, target: String, permissions: Int)
    }

    private func snapshotPaths(_ paths: [WorkspacePath]) async throws -> [SnapshotEntry] {
        try await paths.asyncMap { [self] path in
            try await self.snapshot(path: path)
        }
    }

    private func snapshot(path: WorkspacePath) async throws -> SnapshotEntry {
        guard await filesystem.exists(path: path) else {
            return .missing(path: path)
        }

        let info = try await filesystem.stat(path: path)
        if info.isDirectory {
            let entries = try await filesystem.listDirectory(path: path)
            let children = try await entries
                .sorted { $0.name < $1.name }
                .asyncMap { [self] entry in
                    try await self.snapshot(path: path.appending(entry.name))
                }
            return .directory(path: path, permissions: info.permissions, children: children)
        }

        if info.isSymbolicLink {
            let target = try await filesystem.readSymlink(path: path)
            return .symlink(path: path, target: target, permissions: info.permissions)
        }

        return .file(
            path: path,
            data: try await filesystem.readFile(path: path),
            permissions: info.permissions
        )
    }

    private func rollback(_ snapshots: [SnapshotEntry]) async throws {
        for snapshot in snapshots.sorted(by: { path(of: $0).string.count < path(of: $1).string.count }) {
            try await restore(snapshot, on: filesystem)
        }
    }

    private func restore(_ snapshot: SnapshotEntry, on target: any WorkspaceFilesystem) async throws {
        switch snapshot {
        case let .missing(path):
            if await target.exists(path: path) {
                try await target.remove(path: path, recursive: true)
            }
        case let .file(path, data, permissions):
            if await target.exists(path: path) {
                try await target.remove(path: path, recursive: true)
            }
            if !path.dirname.isRoot {
                try await target.createDirectory(path: path.dirname, recursive: true)
            }
            try await target.writeFile(path: path, data: data, append: false)
            try await target.setPermissions(path: path, permissions: permissions)
        case let .symlink(path, symlinkTarget, permissions):
            if await target.exists(path: path) {
                try await target.remove(path: path, recursive: true)
            }
            if !path.dirname.isRoot {
                try await target.createDirectory(path: path.dirname, recursive: true)
            }
            try await target.createSymlink(path: path, target: symlinkTarget)
            try await target.setPermissions(path: path, permissions: permissions)
        case let .directory(path, permissions, children):
            if await target.exists(path: path) {
                try await target.remove(path: path, recursive: true)
            }
            try await target.createDirectory(path: path, recursive: true)
            try await target.setPermissions(path: path, permissions: permissions)
            for child in children {
                try await restore(child, on: target)
            }
        }
    }

    private func path(of snapshot: SnapshotEntry) -> WorkspacePath {
        switch snapshot {
        case let .missing(path),
             let .file(path, _, _),
             let .directory(path, _, _),
             let .symlink(path, _, _):
            return path
        }
    }
}

/// Deprecated alias for ``Workspace``.
@available(*, deprecated, renamed: "Workspace")
public typealias WorkspaceState = Workspace

private extension Array {
    func asyncMap<T: Sendable>(
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
