import Foundation

/// A high-level API for reading, editing, and summarizing a workspace.
public actor Workspace {
    private let filesystem: any FileSystem
    private var watchers: [UUID: WatchedChangeStream] = [:]

    private struct WatchedChangeStream {
        var path: WorkspacePath
        var recursive: Bool
        var continuation: AsyncStream<ChangeEvent>.Continuation
    }

    /// Creates a workspace backed by `filesystem`.
    public init(filesystem: any FileSystem) {
        self.filesystem = filesystem
    }

    /// Reads raw file contents from the workspace.
    public func readData(from path: WorkspacePath) async throws -> Data {
        try await filesystem.readFile(path: path)
    }

    /// Writes raw file data to the workspace, replacing any existing contents.
    public func writeData(_ data: Data, to path: WorkspacePath) async throws {
        let events = try await plannedWriteEvents(path: path, data: data, append: false, on: filesystem)
        try await filesystem.writeFile(path: path, data: data, append: false)
        emit(events)
    }

    /// Reads a UTF-8 file from the workspace.
    public func readFile(_ path: WorkspacePath) async throws -> String {
        let data = try await filesystem.readFile(path: path)
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalidEncoding(path)
        }
        return string
    }

    /// Writes UTF-8 text to a file, replacing any existing contents.
    public func writeFile(_ path: WorkspacePath, content: String) async throws {
        let data = Data(content.utf8)
        let events = try await plannedWriteEvents(path: path, data: data, append: false, on: filesystem)
        try await filesystem.writeFile(path: path, data: data, append: false)
        emit(events)
    }

    /// Appends UTF-8 text to a file.
    public func appendFile(_ path: WorkspacePath, content: String) async throws {
        let data = Data(content.utf8)
        let events = try await plannedWriteEvents(path: path, data: data, append: true, on: filesystem)
        try await filesystem.writeFile(path: path, data: data, append: true)
        emit(events)
    }

    /// Reads and decodes JSON from a UTF-8 file.
    public func readJSON<T: Decodable>(_ type: T.Type = T.self, from path: WorkspacePath) async throws -> T {
        let data = try await filesystem.readFile(path: path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WorkspaceError.decodingFailed(path, underlying: String(describing: error))
        }
    }

    /// Encodes a value as JSON and writes it to a file.
    public func writeJSON<T: Encodable>(_ value: T, to path: WorkspacePath, prettyPrinted: Bool = true) async throws {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        let events = try await plannedWriteEvents(path: path, data: data, append: false, on: filesystem)
        try await filesystem.writeFile(path: path, data: data, append: false)
        emit(events)
    }

    /// Watches for future changes affecting `path`.
    public func watchChanges(at path: WorkspacePath, recursive: Bool = true) -> AsyncStream<ChangeEvent> {
        let id = UUID()
        var continuation: AsyncStream<ChangeEvent>.Continuation?
        let stream = AsyncStream<ChangeEvent> {
            continuation = $0
        }

        guard let continuation else {
            return stream
        }

        watchers[id] = WatchedChangeStream(
            path: path,
            recursive: recursive,
            continuation: continuation
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeWatcher(id: id)
            }
        }
        return stream
    }

    /// Returns whether an entry exists at `path`.
    public func exists(_ path: WorkspacePath) async -> Bool {
        await filesystem.exists(path: path)
    }

    /// Returns metadata for the entry at `path`.
    public func fileInfo(at path: WorkspacePath) async throws -> FileInfo {
        try await filesystem.stat(path: path)
    }

    /// Lists the direct children of the directory at `path`.
    public func listDirectory(at path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await filesystem.listDirectory(path: path)
    }

    /// Expands a glob pattern relative to `currentDirectory`.
    public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
        try await filesystem.glob(
            pattern: pattern,
            currentDirectory: currentDirectory
        )
    }

    /// Creates a directory at `path`.
    public func createDirectory(at path: WorkspacePath, recursive: Bool = true) async throws {
        let events = try await plannedDirectoryCreationEvents(path: path, recursive: recursive, on: filesystem)
        try await filesystem.createDirectory(path: path, recursive: recursive)
        emit(events)
    }

    /// Removes the entry at `path`.
    public func removeItem(at path: WorkspacePath, recursive: Bool = true) async throws {
        let events = try await plannedDeletionEvents(at: path, on: filesystem)
        try await filesystem.remove(path: path, recursive: recursive)
        emit(events)
    }

    /// Copies an entry from `source` to `destination`.
    public func copyItem(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true)
        async throws
    {
        let events = try await plannedTransferEvents(
            from: source,
            to: destination,
            kind: .copied,
            on: filesystem
        )
        try await filesystem.copy(
            from: source,
            to: destination,
            recursive: recursive
        )
        emit(events)
    }

    /// Moves or renames an entry from `source` to `destination`.
    public func moveItem(from source: WorkspacePath, to destination: WorkspacePath) async throws {
        let events = try await plannedTransferEvents(
            from: source,
            to: destination,
            kind: .moved,
            on: filesystem
        )
        try await filesystem.move(
            from: source,
            to: destination
        )
        emit(events)
    }

    /// Builds a recursive tree representation for the entry at `path`.
    public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTree {
        try await buildTree(path: path, depth: 0, maxDepth: maxDepth)
    }

    /// Summarizes the subtree rooted at `path`.
    public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> FileTreeSummary {
        try await buildSummary(path: path, depth: 0, maxDepth: maxDepth)
    }

    func captureSnapshot(at path: WorkspacePath = .root) async throws -> Snapshot {
        try await Snapshot.capture(from: filesystem, at: path)
    }

    func restoreSnapshot(_ snapshot: Snapshot) async throws {
        try await Snapshot.restore(snapshot, to: filesystem)
    }

    private struct PlannedReplacement {
        var change: ReplacementResult.Change
        var updatedContent: String
        var nodeKind: FileTree.Kind
    }

    private struct PlannedBatchEdit {
        var edit: FileEdit
        var entry: FileEdit.Entry
        var changeEvents: [ChangeEvent]
    }

    private struct DiffToken: Hashable {
        var text: String
        var hasTrailingNewline: Bool
    }

    /// Returns a preview of a replacement request without mutating the workspace.
    public func previewReplacement(_ request: ReplacementRequest) async throws -> ReplacementResult {
        let changes = try await plannedReplacementChanges(for: request).map(\.change)
        return ReplacementResult(
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
        _ request: ReplacementRequest,
        failurePolicy: MutationFailurePolicy = .rollback
    ) async throws -> ReplacementResult {
        let plannedChanges = try await plannedReplacementChanges(for: request)
        var changes = plannedChanges.map(\.change)
        let touchedPaths = canonicalizedTouchedPaths(for: changes)
        var bufferedEvents: [ChangeEvent] = []

        guard !changes.isEmpty else {
            return ReplacementResult(
                mode: .execution,
                touchedPaths: touchedPaths,
                changes: changes,
                rolledBack: false
            )
        }

        let captures = failurePolicy == .rollback ? try await rollbackCaptures(for: touchedPaths) : []
        var failures: [ReplacementResult.Failure] = []
        var appliedIndices: [Int] = []

        for (index, plannedChange) in plannedChanges.enumerated() {
            do {
                try await write(change: plannedChange, to: filesystem)
                changes[index].status = .applied
                appliedIndices.append(index)
                bufferedEvents += changeEvents(for: plannedChange)
            } catch {
                changes[index].status = .failed
                let failure = ReplacementResult.Failure(path: plannedChange.change.path, message: describe(error))
                if failurePolicy == .rollback {
                    try await rollback(captures)
                    for appliedIndex in appliedIndices {
                        changes[appliedIndex].status = .rolledBack
                    }
                    for skippedIndex in changes.indices where skippedIndex > index {
                        changes[skippedIndex].status = .skipped
                    }
                    return ReplacementResult(
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
                    emit(bufferedEvents)
                    return ReplacementResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        changes: changes,
                        failures: failures,
                        rolledBack: false
                    )
                }
            }
        }

        emit(bufferedEvents)
        return ReplacementResult(
            mode: .execution,
            touchedPaths: touchedPaths,
            changes: changes,
            failures: failures,
            rolledBack: false
        )
    }

    /// Returns a preview of a batch edit request without mutating the workspace.
    public func previewEdits(_ edits: [FileEdit]) async throws -> FileEdit.BatchResult {
        let plannedEdits = try await planBatchEdits(edits)
        return FileEdit.BatchResult(
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
        _ edits: [FileEdit],
        failurePolicy: MutationFailurePolicy = .rollback
    ) async throws -> FileEdit.BatchResult {
        let touchedPaths = canonicalizedTouchedPaths(for: edits)
        let plannedEdits = try await planBatchEdits(edits)
        var executionEntries = plannedEdits.map(\.entry)
        var bufferedEvents: [ChangeEvent] = []

        guard !plannedEdits.isEmpty else {
            return FileEdit.BatchResult(
                mode: .execution,
                touchedPaths: touchedPaths,
                edits: executionEntries,
                rolledBack: false
            )
        }

        let captures = failurePolicy == .rollback ? try await rollbackCaptures(for: touchedPaths) : []
        var failures: [FileEdit.Failure] = []
        var appliedIndices: [Int] = []

        for (index, plannedEdit) in plannedEdits.enumerated() {
            do {
                try await apply(plannedEdit.edit, on: filesystem)
                setStatus(.applied, for: &executionEntries[index])
                appliedIndices.append(index)
                bufferedEvents += plannedEdit.changeEvents
            } catch {
                setStatus(.failed, for: &executionEntries[index])
                let failure = FileEdit.Failure(
                    index: index,
                    edit: plannedEdit.edit,
                    message: describe(error)
                )
                if failurePolicy == .rollback {
                    try await rollback(captures)
                    for appliedIndex in appliedIndices {
                        setStatus(.rolledBack, for: &executionEntries[appliedIndex])
                    }
                    for skippedIndex in executionEntries.indices where skippedIndex > index {
                        setStatus(.skipped, for: &executionEntries[skippedIndex])
                    }
                    return FileEdit.BatchResult(
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
                    emit(bufferedEvents)
                    return FileEdit.BatchResult(
                        mode: .execution,
                        touchedPaths: touchedPaths,
                        edits: executionEntries,
                        failures: failures,
                        rolledBack: false
                    )
                }
            }
        }

        emit(bufferedEvents)
        return FileEdit.BatchResult(
            mode: .execution,
            touchedPaths: touchedPaths,
            edits: executionEntries,
            failures: failures,
            rolledBack: false
        )
    }

    private func readUTF8IfPresent(
        _ path: WorkspacePath,
        on target: any FileSystem,
        strictInvalidUTF8: Bool = true
    ) async throws -> String? {
        guard await target.exists(path: path) else {
            return nil
        }
        let info = try await target.stat(path: path)
        guard info.kind != .directory else {
            return nil
        }
        let data = try await target.readFile(path: path)
        guard let string = String(data: data, encoding: .utf8) else {
            if strictInvalidUTF8 {
                throw WorkspaceError.invalidEncoding(path)
            }
            return nil
        }
        return string
    }

    private func buildTree(path: WorkspacePath, depth: Int, maxDepth: Int?) async throws -> FileTree {
        let info = try await filesystem.stat(path: path)
        let children: [FileTree]?

        if info.kind == .directory, maxDepth.map({ depth < $0 }) ?? true {
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

        return FileTree(
            path: path,
            kind: info.kind,
            size: info.size,
            permissions: info.permissions,
            modificationDate: info.modificationDate,
            children: children
        )
    }

    private func buildSummary(path: WorkspacePath, depth: Int, maxDepth: Int?) async throws -> FileTreeSummary {
        let info = try await filesystem.stat(path: path)
        var fileCount = info.kind == .directory ? 0 : 1
        var directoryCount = info.kind == .directory ? 1 : 0
        var symlinkCount = info.kind == .symlink ? 1 : 0
        var totalBytes = info.size
        var childSummaries: [FileTreeSummary.Entry] = []

        if info.kind == .directory, maxDepth.map({ depth < $0 }) ?? true {
            let entries = try await filesystem.listDirectory(path: path)
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                let childPath = path.appending(entry.name)
                let childSummary = try await buildSummary(path: childPath, depth: depth + 1, maxDepth: maxDepth)
                fileCount += childSummary.fileCount
                directoryCount += childSummary.directoryCount
                symlinkCount += childSummary.symlinkCount
                totalBytes += childSummary.totalBytes
                childSummaries.append(
                    FileTreeSummary.Entry(
                        path: childPath,
                        kind: entry.info.kind,
                        size: entry.info.size,
                        permissions: entry.info.permissions
                    )
                )
            }
        }

        return FileTreeSummary(
            path: path,
            fileCount: fileCount,
            directoryCount: directoryCount,
            symlinkCount: symlinkCount,
            totalBytes: totalBytes,
            children: childSummaries
        )
    }

    private func touchedPaths(for edit: FileEdit) -> [WorkspacePath] {
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

    private func canonicalizedTouchedPaths(for changes: [ReplacementResult.Change]) -> [WorkspacePath] {
        Array(Set(changes.map(\.path))).sorted()
    }

    private func canonicalizedTouchedPaths(for edits: [FileEdit]) -> [WorkspacePath] {
        let paths = Set(edits.flatMap(touchedPaths(for:)))
        return paths.sorted().filter { candidate in
            !paths.contains { other in
                other != candidate && candidate.string.hasPrefix(other.string + "/")
            }
        }
    }

    private func removeWatcher(id: UUID) {
        watchers.removeValue(forKey: id)
    }

    private func emit(_ events: [ChangeEvent]) {
        guard !events.isEmpty, !watchers.isEmpty else {
            return
        }

        let activeWatchers = Array(watchers.values)
        for event in events {
            for watcher in activeWatchers where shouldDeliver(event, to: watcher) {
                watcher.continuation.yield(event)
            }
        }
    }

    private func shouldDeliver(_ event: ChangeEvent, to watcher: WatchedChangeStream) -> Bool {
        watchedPathMatches(event.path, watchedPath: watcher.path, recursive: watcher.recursive)
            || watchedPathMatches(event.sourcePath, watchedPath: watcher.path, recursive: watcher.recursive)
    }

    private func watchedPathMatches(
        _ candidate: WorkspacePath?,
        watchedPath: WorkspacePath,
        recursive: Bool
    ) -> Bool {
        guard let candidate else {
            return false
        }

        if recursive {
            return isEqualOrDescendant(candidate, of: watchedPath)
        }

        return candidate == watchedPath
    }

    private func isEqualOrDescendant(_ candidate: WorkspacePath, of ancestor: WorkspacePath) -> Bool {
        if ancestor.isRoot {
            return true
        }
        return candidate == ancestor || candidate.string.hasPrefix(ancestor.string + "/")
    }

    private func statIfPresent(_ path: WorkspacePath, on target: any FileSystem) async throws -> FileInfo? {
        guard await target.exists(path: path) else {
            return nil
        }
        return try await target.stat(path: path)
    }

    private func plannedReplacementChanges(for request: ReplacementRequest) async throws -> [PlannedReplacement] {
        let paths = try await matchedPaths(for: request)
        var changes: [PlannedReplacement] = []

        for path in paths {
            let info = try await filesystem.stat(path: path)
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
                    change: .init(
                        path: path,
                        replacements: replacement.count,
                        diff: textDiff(from: originalContent, to: replacement.updatedContent)
                    ),
                    updatedContent: replacement.updatedContent,
                    nodeKind: info.kind
                )
            )
        }

        return changes
    }

    private func matchedPaths(for request: ReplacementRequest) async throws -> [WorkspacePath] {
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
        matching pattern: ReplacementRequest.Pattern,
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

    private func planBatchEdits(_ edits: [FileEdit]) async throws -> [PlannedBatchEdit] {
        let planningFilesystem = try await makePlanningFilesystem(for: canonicalizedTouchedPaths(for: edits))
        var plannedEdits: [PlannedBatchEdit] = []

        for edit in edits {
            let entry = try await planEntry(for: edit, on: planningFilesystem)
            let changeEvents = try await plannedChangeEvents(for: edit, on: planningFilesystem)
            plannedEdits.append(PlannedBatchEdit(edit: edit, entry: entry, changeEvents: changeEvents))
            try? await apply(edit, on: planningFilesystem)
        }

        return plannedEdits
    }

    private func makePlanningFilesystem(for paths: [WorkspacePath]) async throws -> InMemoryFilesystem {
        let planningFilesystem = InMemoryFilesystem()
        let ancestors = Set(paths.flatMap(ancestorPaths(for:))).sorted()
        for ancestor in ancestors {
            let capture = try await shallowRollbackCapture(path: ancestor, on: filesystem)
            try await restore(capture, on: planningFilesystem)
        }

        let captures = try await rollbackCaptures(for: paths)
        for capture in captures {
            try await restore(capture, on: planningFilesystem)
        }
        return planningFilesystem
    }

    private func ancestorPaths(for path: WorkspacePath) -> [WorkspacePath] {
        var ancestors: [WorkspacePath] = []
        var current = path.dirname
        while !current.isRoot {
            ancestors.append(current)
            current = current.dirname
        }
        return ancestors.reversed()
    }

    private func planEntry(
        for edit: FileEdit,
        on target: any FileSystem
    ) async throws -> FileEdit.Entry {
        switch edit {
        case let .writeFile(path, content):
            let original = try await readUTF8IfPresent(path, on: target)
            let info = try await statIfPresent(path, on: target)
            let effect = effect(forOriginalContent: original, updatedContent: content)
            return FileEdit.Entry(
                edit: edit,
                changeState: changeState(for: effect),
                touchedPaths: [path],
                fileChanges: [
                    textFileChange(
                        path: path,
                        kind: info.map(\.kind) ?? .file,
                        originalContent: original,
                        updatedContent: content,
                        effect: effect
                    )
                ]
            )
        case let .appendFile(path, content):
            let original = try await readUTF8IfPresent(path, on: target)
            let updated = (original ?? "") + content
            let info = try await statIfPresent(path, on: target)
            let effect = effect(forOriginalContent: original, updatedContent: updated)
            return FileEdit.Entry(
                edit: edit,
                changeState: changeState(for: effect),
                touchedPaths: [path],
                fileChanges: [
                    textFileChange(
                        path: path,
                        kind: info.map(\.kind) ?? .file,
                        originalContent: original,
                        updatedContent: updated,
                        effect: effect
                    )
                ]
            )
        case let .delete(path, _):
            let existing = try await statIfPresent(path, on: target)
            return FileEdit.Entry(
                edit: edit,
                changeState: existing == nil ? .unchanged : .changed,
                touchedPaths: [path],
                fileChanges: try await deletionFileChanges(at: path, on: target)
            )
        case let .createDirectory(path, _):
            let existing = try await statIfPresent(path, on: target)
            return FileEdit.Entry(
                edit: edit,
                changeState: existing == nil ? .changed : .unchanged,
                touchedPaths: [path]
            )
        case let .move(from, to):
            return FileEdit.Entry(
                edit: edit,
                changeState: from == to ? .unchanged : .changed,
                touchedPaths: [from, to],
                fileChanges: from == to ? [] : try await transferFileChanges(from: from, to: to, effect: .moved, on: target)
            )
        case let .copy(from, to, _):
            return FileEdit.Entry(
                edit: edit,
                changeState: .changed,
                touchedPaths: [from, to],
                fileChanges: try await transferFileChanges(from: from, to: to, effect: .copied, on: target)
            )
        }
    }

    private func changeState(for effect: FileEdit.Effect) -> FileEdit.ChangeState {
        effect == .unchanged ? .unchanged : .changed
    }

    private func effect(forOriginalContent originalContent: String?, updatedContent: String) -> FileEdit.Effect {
        guard let originalContent else {
            return .created
        }
        return originalContent == updatedContent ? .unchanged : .modified
    }

    private func textFileChange(
        path: WorkspacePath,
        kind: FileTree.Kind,
        originalContent: String?,
        updatedContent: String,
        effect: FileEdit.Effect
    ) -> FileEdit.FileChange {
        FileEdit.FileChange(
            path: path,
            kind: kind,
            effect: effect,
            diff: textDiff(from: originalContent ?? "", to: updatedContent)
        )
    }

    private func deletionFileChanges(
        at path: WorkspacePath,
        on target: any FileSystem
    ) async throws -> [FileEdit.FileChange] {
        guard let info = try await statIfPresent(path, on: target) else {
            return []
        }

        if info.kind == .directory {
            let entries = try await target.listDirectory(path: path)
            var fileChanges: [FileEdit.FileChange] = []
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                fileChanges += try await deletionFileChanges(at: path.appending(entry.name), on: target)
            }
            return fileChanges
        }

        let diff: TextDiff?
        if info.kind == .symlink {
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
            FileEdit.FileChange(
                path: path,
                kind: info.kind,
                effect: .deleted,
                diff: diff
            )
        ]
    }

    private func transferFileChanges(
        from sourcePath: WorkspacePath,
        to destinationPath: WorkspacePath,
        effect: FileEdit.Effect,
        on target: any FileSystem
    ) async throws -> [FileEdit.FileChange] {
        guard let info = try await statIfPresent(sourcePath, on: target) else {
            return []
        }

        if info.kind == .directory {
            let entries = try await target.listDirectory(path: sourcePath)
            var fileChanges: [FileEdit.FileChange] = []
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
            FileEdit.FileChange(
                path: destinationPath,
                sourcePath: sourcePath,
                kind: info.kind,
                effect: effect
            )
        ]
    }

    private func plannedChangeEvents(
        for edit: FileEdit,
        on target: any FileSystem
    ) async throws -> [ChangeEvent] {
        switch edit {
        case let .writeFile(path, content):
            return try await plannedWriteEvents(
                path: path,
                data: Data(content.utf8),
                append: false,
                on: target
            )
        case let .appendFile(path, content):
            return try await plannedWriteEvents(
                path: path,
                data: Data(content.utf8),
                append: true,
                on: target
            )
        case let .delete(path, _):
            return try await plannedDeletionEvents(at: path, on: target)
        case let .createDirectory(path, recursive):
            return try await plannedDirectoryCreationEvents(path: path, recursive: recursive, on: target)
        case let .move(from, to):
            return try await plannedTransferEvents(from: from, to: to, kind: .moved, on: target)
        case let .copy(from, to, _):
            return try await plannedTransferEvents(from: from, to: to, kind: .copied, on: target)
        }
    }

    private func plannedWriteEvents(
        path: WorkspacePath,
        data: Data,
        append: Bool,
        on target: any FileSystem
    ) async throws -> [ChangeEvent] {
        guard let info = try await statIfPresent(path, on: target) else {
            return [
                ChangeEvent(
                    kind: .created,
                    path: path,
                    nodeKind: .file
                ),
            ]
        }

        guard info.kind != .directory else {
            return []
        }

        let existingData = try await target.readFile(path: path)
        let updatedData = append ? existingData + data : data
        guard existingData != updatedData else {
            return []
        }

        return [
            ChangeEvent(
                kind: .modified,
                path: path,
                nodeKind: info.kind
            ),
        ]
    }

    private func plannedDirectoryCreationEvents(
        path: WorkspacePath,
        recursive: Bool,
        on target: any FileSystem
    ) async throws -> [ChangeEvent] {
        guard !path.isRoot else {
            return []
        }

        if recursive {
            var events: [ChangeEvent] = []
            var current = WorkspacePath.root
            for component in path.components {
                current = current.appending(component)
                if try await statIfPresent(current, on: target) == nil {
                    events.append(
                        ChangeEvent(
                            kind: .created,
                            path: current,
                            nodeKind: .directory
                        )
                    )
                }
            }
            return events
        }

        guard try await statIfPresent(path, on: target) == nil else {
            return []
        }

        return [
            ChangeEvent(
                kind: .created,
                path: path,
                nodeKind: .directory
            ),
        ]
    }

    private func plannedDeletionEvents(
        at path: WorkspacePath,
        on target: any FileSystem
    ) async throws -> [ChangeEvent] {
        let capture = try await rollbackCapture(path: path, on: target)
        return flattenDeletionEvents(from: capture)
    }

    private func plannedTransferEvents(
        from sourcePath: WorkspacePath,
        to destinationPath: WorkspacePath,
        kind: ChangeEvent.Kind,
        on target: any FileSystem
    ) async throws -> [ChangeEvent] {
        let capture = try await rollbackCapture(path: sourcePath, on: target)
        return flattenTransferEvents(
            from: capture,
            sourceRoot: sourcePath,
            destinationRoot: destinationPath,
            kind: kind
        )
    }

    private func changeEvents(for replacement: PlannedReplacement) -> [ChangeEvent] {
        guard !replacement.change.diff.hunks.isEmpty else {
            return []
        }

        return [
            ChangeEvent(
                kind: .modified,
                path: replacement.change.path,
                nodeKind: replacement.nodeKind
            ),
        ]
    }

    private func flattenDeletionEvents(from capture: RollbackCapture) -> [ChangeEvent] {
        switch capture {
        case .missing:
            return []
        case let .file(path, _, _):
            return [ChangeEvent(kind: .deleted, path: path, nodeKind: .file)]
        case let .symlink(path, _, _):
            return [ChangeEvent(kind: .deleted, path: path, nodeKind: .symlink)]
        case let .directory(path, _, children):
            var events: [ChangeEvent] = []
            for child in children {
                events += flattenDeletionEvents(from: child)
            }
            events.append(
                ChangeEvent(
                    kind: .deleted,
                    path: path,
                    nodeKind: .directory
                )
            )
            return events
        }
    }

    private func flattenTransferEvents(
        from capture: RollbackCapture,
        sourceRoot: WorkspacePath,
        destinationRoot: WorkspacePath,
        kind: ChangeEvent.Kind
    ) -> [ChangeEvent] {
        switch capture {
        case .missing:
            return []
        case let .file(path, _, _):
            return [
                ChangeEvent(
                    kind: kind,
                    path: remappedPath(path, from: sourceRoot, to: destinationRoot),
                    sourcePath: path,
                    nodeKind: .file
                ),
            ]
        case let .symlink(path, _, _):
            return [
                ChangeEvent(
                    kind: kind,
                    path: remappedPath(path, from: sourceRoot, to: destinationRoot),
                    sourcePath: path,
                    nodeKind: .symlink
                ),
            ]
        case let .directory(path, _, children):
            var events: [ChangeEvent] = [
                ChangeEvent(
                    kind: kind,
                    path: remappedPath(path, from: sourceRoot, to: destinationRoot),
                    sourcePath: path,
                    nodeKind: .directory
                ),
            ]
            for child in children {
                events += flattenTransferEvents(
                    from: child,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    kind: kind
                )
            }
            return events
        }
    }

    private func remappedPath(
        _ path: WorkspacePath,
        from sourceRoot: WorkspacePath,
        to destinationRoot: WorkspacePath
    ) -> WorkspacePath {
        guard path != sourceRoot else {
            return destinationRoot
        }

        let suffix = path.components.dropFirst(sourceRoot.components.count)
        return suffix.reduce(destinationRoot) { partialResult, component in
            partialResult.appending(component)
        }
    }

    private func write(change: PlannedReplacement, to target: any FileSystem) async throws {
        try await target.writeFile(
            path: change.change.path,
            data: Data(change.updatedContent.utf8),
            append: false
        )
    }

    private func apply(_ edit: FileEdit, on target: any FileSystem) async throws {
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

    private func setStatus(_ status: MutationStatus, for entry: inout FileEdit.Entry) {
        entry.status = status
        for index in entry.fileChanges.indices {
            entry.fileChanges[index].status = status
        }
    }

    private func textDiff(from originalContent: String, to updatedContent: String) -> TextDiff {
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

        var lines: [TextDiff.Line] = []
        var originalIndex = 0
        var updatedIndex = 0
        var originalLineNumber = 1
        var updatedLineNumber = 1

        while originalIndex < originalLines.count || updatedIndex < updatedLines.count {
            if let removed = removals[originalIndex] {
                for (_, token) in removed {
                    lines.append(
                        TextDiff.Line(
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
                        TextDiff.Line(
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
                TextDiff.Line(
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
            return TextDiff(hunks: [])
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
            return TextDiff.Hunk(
                oldStartLine: originalLineNumbers.first ?? 1,
                oldLineCount: originalLineNumbers.count,
                newStartLine: updatedLineNumbers.first ?? 1,
                newLineCount: updatedLineNumbers.count,
                lines: hunkLines
            )
        }

        return TextDiff(hunks: hunks)
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

    /// A short-lived capture used only to restore failed batched mutations.
    private enum RollbackCapture: Sendable {
        case missing(path: WorkspacePath)
        case file(path: WorkspacePath, data: Data, permissions: POSIXPermissions)
        case directory(path: WorkspacePath, permissions: POSIXPermissions, children: [RollbackCapture])
        case symlink(path: WorkspacePath, target: String, permissions: POSIXPermissions)
    }

    private func rollbackCaptures(for paths: [WorkspacePath]) async throws -> [RollbackCapture] {
        try await rollbackCaptures(paths, on: filesystem)
    }

    private func rollbackCaptures(
        _ paths: [WorkspacePath],
        on target: any FileSystem
    ) async throws -> [RollbackCapture] {
        try await paths.asyncMap { path in
            try await self.rollbackCapture(path: path, on: target)
        }
    }

    private func shallowRollbackCapture(path: WorkspacePath, on target: any FileSystem) async throws -> RollbackCapture {
        guard await target.exists(path: path) else {
            return .missing(path: path)
        }

        let info = try await target.stat(path: path)
        switch info.kind {
        case .directory:
            return .directory(path: path, permissions: info.permissions, children: [])
        case .symlink:
            let symlinkTarget = try await target.readSymlink(path: path)
            return .symlink(path: path, target: symlinkTarget, permissions: info.permissions)
        case .file:
            return .file(path: path, data: Data(), permissions: info.permissions)
        }
    }

    private func rollbackCapture(path: WorkspacePath, on target: any FileSystem) async throws -> RollbackCapture {
        guard await target.exists(path: path) else {
            return .missing(path: path)
        }

        let info = try await target.stat(path: path)
        if info.kind == .directory {
            let entries = try await target.listDirectory(path: path)
            let children = try await entries
                .sorted { $0.name < $1.name }
                .asyncMap { [self] entry in
                    try await self.rollbackCapture(path: path.appending(entry.name), on: target)
                }
            return .directory(path: path, permissions: info.permissions, children: children)
        }

        if info.kind == .symlink {
            let symlinkTarget = try await target.readSymlink(path: path)
            return .symlink(path: path, target: symlinkTarget, permissions: info.permissions)
        }

        return .file(
            path: path,
            data: try await target.readFile(path: path),
            permissions: info.permissions
        )
    }

    private func rollback(_ captures: [RollbackCapture]) async throws {
        for capture in captures.sorted(by: { path(of: $0).string.count < path(of: $1).string.count }) {
            try await restore(capture, on: filesystem)
        }
    }

    private func restore(_ capture: RollbackCapture, on target: any FileSystem) async throws {
        switch capture {
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

    private func path(of capture: RollbackCapture) -> WorkspacePath {
        switch capture {
        case let .missing(path),
             let .file(path, _, _),
             let .directory(path, _, _),
             let .symlink(path, _, _):
            return path
        }
    }
}

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
