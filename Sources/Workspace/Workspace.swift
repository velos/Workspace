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

/// A single text replacement result produced by ``Workspace/previewReplacement(_:)`` or
/// ``Workspace/applyReplacement(_:failurePolicy:)``.
public struct WorkspaceTextChange: Sendable {
    /// The file path that was changed.
    public var path: WorkspacePath
    /// The number of replacements applied to the file.
    public var replacements: Int
    /// The original file contents.
    public var originalContent: String
    /// The updated file contents after replacement.
    public var updatedContent: String

    /// Creates a text change result.
    public init(path: WorkspacePath, replacements: Int, originalContent: String, updatedContent: String) {
        self.path = path
        self.replacements = replacements
        self.originalContent = originalContent
        self.updatedContent = updatedContent
    }

    /// Convenience initializer that accepts a string path.
    public init(path: String, replacements: Int, originalContent: String, updatedContent: String) {
        self.init(
            path: WorkspacePath(normalizing: path),
            replacements: replacements,
            originalContent: originalContent,
            updatedContent: updatedContent
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
    /// Paths touched by the edit.
    public var touchedPaths: [WorkspacePath]
    /// The original file contents when relevant.
    public var originalContent: String?
    /// The updated file contents when relevant.
    public var updatedContent: String?

    /// Creates a batch edit entry.
    public init(
        operation: WorkspaceBatchEditOperation,
        effect: WorkspaceBatchEditEffect,
        touchedPaths: [WorkspacePath],
        originalContent: String? = nil,
        updatedContent: String? = nil
    ) {
        self.operation = operation
        self.effect = effect
        self.touchedPaths = touchedPaths
        self.originalContent = originalContent
        self.updatedContent = updatedContent
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
        let data = try await filesystem.readFile(path: normalize(path))
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.unsupported("file is not valid UTF-8: \(normalize(path))")
        }
        return string
    }

    /// Convenience overload for ``Workspace/readFile(_:)`` that accepts a string path.
    public func readFile(_ path: String) async throws -> String {
        try await readFile(WorkspacePath(validating: path))
    }

    /// Writes UTF-8 text to a file, replacing any existing contents.
    public func writeFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: normalize(path), data: Data(content.utf8), append: false)
    }

    /// Convenience overload for ``Workspace/writeFile(_:content:)`` that accepts a string path.
    public func writeFile(_ path: String, content: String) async throws {
        try await writeFile(WorkspacePath(validating: path), content: content)
    }

    /// Appends UTF-8 text to a file.
    public func appendFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: normalize(path), data: Data(content.utf8), append: true)
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
        let data = try await filesystem.readFile(path: normalize(path))
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WorkspaceError.unsupported("invalid JSON: \(normalize(path))")
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
        try await filesystem.writeFile(path: normalize(path), data: data, append: false)
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
        await filesystem.exists(path: normalize(path))
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
        try await filesystem.stat(path: normalize(path))
    }

    /// Convenience overload for ``Workspace/stat(_:)`` that accepts a string path.
    public func stat(_ path: String) async throws -> FileInfo {
        try await stat(WorkspacePath(validating: path))
    }

    /// Lists the direct children of the directory at `path`.
    public func readdir(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await filesystem.listDirectory(path: normalize(path))
    }

    /// Convenience overload for ``Workspace/readdir(_:)`` that accepts a string path.
    public func readdir(_ path: String) async throws -> [DirectoryEntry] {
        try await readdir(WorkspacePath(validating: path))
    }

    /// Expands a glob pattern relative to `currentDirectory`.
    public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
        try await filesystem.glob(
            pattern: pattern,
            currentDirectory: normalize(currentDirectory)
        )
    }

    /// Convenience overload for ``Workspace/glob(_:currentDirectory:)`` that accepts a string current directory.
    public func glob(_ pattern: String, currentDirectory: String) async throws -> [WorkspacePath] {
        try await glob(pattern, currentDirectory: WorkspacePath(validating: currentDirectory))
    }

    /// Creates a directory at `path`.
    public func mkdir(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.createDirectory(path: normalize(path), recursive: recursive)
    }

    /// Convenience overload for ``Workspace/mkdir(_:recursive:)`` that accepts a string path.
    public func mkdir(_ path: String, recursive: Bool = true) async throws {
        try await mkdir(WorkspacePath(validating: path), recursive: recursive)
    }

    /// Removes the entry at `path`.
    public func rm(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.remove(path: normalize(path), recursive: recursive)
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
            from: normalize(sourcePath),
            to: normalize(destinationPath),
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
            from: normalize(sourcePath),
            to: normalize(destinationPath)
        )
    }

    /// Convenience overload for ``Workspace/mv(_:_:)`` that accepts string paths.
    public func mv(_ sourcePath: String, _ destinationPath: String) async throws {
        try await mv(WorkspacePath(validating: sourcePath), WorkspacePath(validating: destinationPath))
    }

    /// Builds a recursive tree representation for the entry at `path`.
    public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await buildTree(path: normalize(path), depth: 0, maxDepth: maxDepth)
    }

    /// Convenience overload for ``Workspace/walkTree(_:maxDepth:)`` that accepts a string path.
    public func walkTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await walkTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    /// Summarizes the subtree rooted at `path`.
    public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await buildSummary(path: normalize(path), depth: 0, maxDepth: maxDepth)
    }

    /// Convenience overload for ``Workspace/summarizeTree(_:maxDepth:)`` that accepts a string path.
    public func summarizeTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await summarizeTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    /// Returns a preview of a replacement request without mutating the workspace.
    public func previewReplacement(_ request: WorkspaceReplaceRequest) async throws -> WorkspaceReplaceResult {
        let normalizedRequest = normalize(request: request)
        let changes = try await replacementChanges(for: normalizedRequest)
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
        let normalizedRequest = normalize(request: request)
        let changes = try await replacementChanges(for: normalizedRequest)
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

        for change in changes {
            do {
                try await write(change: change)
            } catch {
                let failure = WorkspaceReplaceFailure(path: change.path, message: describe(error))
                if failurePolicy == .rollback {
                    try await rollback(snapshots)
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
                    break
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
        let normalizedEdits = edits.map(normalize(edit:))
        return WorkspaceBatchEditResult(
            mode: .preview,
            touchedPaths: canonicalizedTouchedPaths(for: normalizedEdits),
            edits: try await previewEntries(for: normalizedEdits),
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
        let normalizedEdits = edits.map(normalize(edit:))
        let touchedPaths = canonicalizedTouchedPaths(for: normalizedEdits)
        let previewEntries = try await previewEntries(for: normalizedEdits)

        guard !normalizedEdits.isEmpty else {
            return WorkspaceBatchEditResult(
                mode: .execution,
                touchedPaths: touchedPaths,
                edits: previewEntries,
                rolledBack: false
            )
        }

        let snapshots = failurePolicy == .rollback ? try await snapshotPaths(touchedPaths) : []
        var failures: [WorkspaceBatchEditFailure] = []

        for (index, edit) in normalizedEdits.enumerated() {
            do {
                try await apply(edit)
            } catch {
                let failure = WorkspaceBatchEditFailure(
                    index: index,
                    edit: edit,
                    message: describe(error)
                )
                if failurePolicy == .rollback {
                    try await rollback(snapshots)
                    return WorkspaceBatchEditResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        edits: previewEntries,
                        failures: [failure],
                        rolledBack: true
                    )
                }

                failures.append(failure)
                if failurePolicy == .failFast {
                    break
                }
            }
        }

        return WorkspaceBatchEditResult(
            mode: .execution,
            touchedPaths: touchedPaths,
            edits: previewEntries,
            failures: failures,
            rolledBack: false
        )
    }

    private func normalize(_ path: WorkspacePath) -> WorkspacePath {
        WorkspacePath(normalizing: path.string)
    }

    private func normalize(request: WorkspaceReplaceRequest) -> WorkspaceReplaceRequest {
        WorkspaceReplaceRequest(
            scope: normalize(request.scope),
            include: request.include,
            exclude: request.exclude,
            search: request.search,
            replacement: request.replacement
        )
    }

    private func readUTF8IfPresent(_ path: WorkspacePath) async throws -> String? {
        guard await filesystem.exists(path: path) else {
            return nil
        }
        let info = try await filesystem.stat(path: path)
        guard !info.isDirectory else {
            return nil
        }
        let data = try await filesystem.readFile(path: path)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.unsupported("file is not valid UTF-8: \(path)")
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

    private func normalize(edit: WorkspaceEdit) -> WorkspaceEdit {
        switch edit {
        case let .writeFile(path, content):
            return .writeFile(path: normalize(path), content: content)
        case let .appendFile(path, content):
            return .appendFile(path: normalize(path), content: content)
        case let .delete(path, recursive):
            return .delete(path: normalize(path), recursive: recursive)
        case let .createDirectory(path, recursive):
            return .createDirectory(path: normalize(path), recursive: recursive)
        case let .move(from, to):
            return .move(from: normalize(from), to: normalize(to))
        case let .copy(from, to, recursive):
            return .copy(from: normalize(from), to: normalize(to), recursive: recursive)
        }
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
        guard await filesystem.exists(path: path) else {
            return nil
        }
        return try await filesystem.stat(path: path)
    }

    private func replacementChanges(for request: WorkspaceReplaceRequest) async throws -> [WorkspaceTextChange] {
        let paths = try await matchedPaths(for: request)
        var changes: [WorkspaceTextChange] = []

        for path in paths {
            guard let originalContent = try await readUTF8IfPresent(path) else {
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
                WorkspaceTextChange(
                    path: path,
                    replacements: replacement.count,
                    originalContent: originalContent,
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

    private func previewEntries(for edits: [WorkspaceEdit]) async throws -> [WorkspaceBatchEditEntry] {
        var entries: [WorkspaceBatchEditEntry] = []
        for edit in edits {
            switch edit {
            case let .writeFile(path, content):
                let original = try await readUTF8IfPresent(path)
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .writeFile,
                        effect: effect(forOriginalContent: original, updatedContent: content),
                        touchedPaths: [path],
                        originalContent: original,
                        updatedContent: content
                    )
                )
            case let .appendFile(path, content):
                let original = try await readUTF8IfPresent(path)
                let updated = (original ?? "") + content
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .appendFile,
                        effect: effect(forOriginalContent: original, updatedContent: updated),
                        touchedPaths: [path],
                        originalContent: original,
                        updatedContent: updated
                    )
                )
            case let .delete(path, _):
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .delete,
                        effect: await filesystem.exists(path: path) ? .deleted : .unchanged,
                        touchedPaths: [path]
                    )
                )
            case let .createDirectory(path, _):
                let existing = try await statIfPresent(path)
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .createDirectory,
                        effect: existing == nil ? .created : .unchanged,
                        touchedPaths: [path]
                    )
                )
            case let .move(from, to):
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .move,
                        effect: from == to ? .unchanged : .moved,
                        touchedPaths: [from, to]
                    )
                )
            case let .copy(from, to, _):
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: .copy,
                        effect: .copied,
                        touchedPaths: [from, to]
                    )
                )
            }
        }
        return entries
    }

    private func effect(forOriginalContent originalContent: String?, updatedContent: String) -> WorkspaceBatchEditEffect {
        guard let originalContent else {
            return .created
        }
        return originalContent == updatedContent ? .unchanged : .modified
    }

    private func write(change: WorkspaceTextChange) async throws {
        try await filesystem.writeFile(
            path: change.path,
            data: Data(change.updatedContent.utf8),
            append: false
        )
    }

    private func apply(_ edit: WorkspaceEdit) async throws {
        switch edit {
        case let .writeFile(path, content):
            try await filesystem.writeFile(path: path, data: Data(content.utf8), append: false)
        case let .appendFile(path, content):
            try await filesystem.writeFile(path: path, data: Data(content.utf8), append: true)
        case let .delete(path, recursive):
            try await filesystem.remove(path: path, recursive: recursive)
        case let .createDirectory(path, recursive):
            try await filesystem.createDirectory(path: path, recursive: recursive)
        case let .move(from, to):
            try await filesystem.move(from: from, to: to)
        case let .copy(from, to, recursive):
            try await filesystem.copy(from: from, to: to, recursive: recursive)
        }
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
            try await restore(snapshot)
        }
    }

    private func restore(_ snapshot: SnapshotEntry) async throws {
        switch snapshot {
        case let .missing(path):
            if await filesystem.exists(path: path) {
                try await filesystem.remove(path: path, recursive: true)
            }
        case let .file(path, data, permissions):
            if await filesystem.exists(path: path) {
                try await filesystem.remove(path: path, recursive: true)
            }
            try await filesystem.writeFile(path: path, data: data, append: false)
            try await filesystem.setPermissions(path: path, permissions: permissions)
        case let .symlink(path, target, permissions):
            if await filesystem.exists(path: path) {
                try await filesystem.remove(path: path, recursive: true)
            }
            try await filesystem.createSymlink(path: path, target: target)
            try await filesystem.setPermissions(path: path, permissions: permissions)
        case let .directory(path, permissions, children):
            if await filesystem.exists(path: path) {
                try await filesystem.remove(path: path, recursive: true)
            }
            try await filesystem.createDirectory(path: path, recursive: true)
            try await filesystem.setPermissions(path: path, permissions: permissions)
            for child in children {
                try await restore(child)
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
