import Foundation

extension Workspace {
    /// Reads UTF-8 text from a workspace revision.
    public func readText(_ path: WorkspacePath, at revision: Revision = .current) async throws -> String {
        let data = try await readData(from: path, at: revision)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalidEncoding(path)
        }
        return text
    }

    /// Previews edits against an isolated in-memory copy of the current workspace.
    public func preview(_ edits: [Edit]) async throws -> ChangeSet {
        let before = try await Snapshot.capture(from: filesystem)
        let scratch = InMemoryFileSystem()
        try await Snapshot.restore(before, to: scratch)
        for edit in edits {
            try await Self.apply(edit, to: scratch)
        }
        let after = try await Snapshot.capture(from: scratch)
        return changeSet(from: before, to: after)
    }

    /// Applies edits through one canonical execution and recording path.
    ///
    /// Atomic recovery restores only affected subtrees, including implicitly
    /// created parents. Hard-link aliases outside those subtrees are not tracked,
    /// and permission changes to symlink entries are not rolled back.
    /// Direct filesystem mutations and other processes are not serialized by the
    /// workspace operation gate; concurrent changes within affected roots may be lost.
    @discardableResult
    public func apply(_ edits: [Edit], policy: EditPolicy = .atomic) async throws -> EditResult {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        var journal = SnapshotJournal()
        var failures: [EditFailure] = []

        do {
            for (index, edit) in edits.enumerated() {
                do {
                    let paths = try await affectedRoots(for: edit)
                    try await journal.capture(paths, from: filesystem)
                    try await Self.apply(edit, to: filesystem)
                } catch {
                    if policy == .atomic { throw error }
                    failures.append(EditFailure(index: index, edit: edit, message: String(describing: error)))
                    if policy == .stopOnError { break }
                }
            }

            let after = try await journal.captureAfter(from: filesystem)
            let changes = changeSet(from: journal.snapshots, to: after)
            if !changes.isEmpty {
                let recorded = recordingChanges(changes, from: journal.snapshots, to: after)
                try await appendMutation(operation: .edit, changes: recorded)
            }
            for snapshot in after { noteWorkspaceSnapshot(snapshot) }
            if !changes.isEmpty { emitWorkspaceEvent(.changes(changes)) }
            return EditResult(changes: changes, failures: failures)
        } catch {
            // Capture and persistence failures are also inside the atomic boundary.
            try await restoreAfterFailure(journal.snapshots, originalError: error)
        }
    }

    /// Includes implicitly created parent directories. Hard-link aliases outside
    /// these roots cannot be discovered through FileSystem and are not journaled.
    private func affectedRoots(for edit: Edit) async throws -> [WorkspacePath] {
        let paths: [WorkspacePath]
        switch edit {
        case let .replace(files, _, _):
            paths = try await Self.selectedFiles(files, on: filesystem)
        case let .move(source, destination): paths = [source, destination]
        case let .copy(_, destination, _): paths = [destination]
        case let .writeText(path, _), let .appendText(path, _),
             let .writeData(path, _), let .appendData(path, _),
             let .createDirectory(path, _), let .remove(path, _),
             let .createSymbolicLink(path, _), let .createHardLink(path, _),
             let .setPermissions(path, _): paths = [path]
        }
        var roots: [WorkspacePath] = []
        let resolvesPaths = await filesystem.capabilities().contains(.realPathResolution)
        for path in paths {
            let entryPath = try await canonicalEntryPath(path, resolvesPaths: resolvesPaths)
            roots.append(try await captureRoot(for: entryPath))
            // Some backends replace the leaf link, while others follow it. Capture
            // both the canonical entry and its target, but never lexical aliases.
            switch edit {
            case .writeText, .appendText, .writeData, .appendData, .setPermissions, .replace:
                if resolvesPaths {
                    let target = try await resolvedCapturePath(entryPath)
                    roots.append(try await captureRoot(for: target))
                }
            default:
                break
            }
        }
        return roots
    }

    func canonicalEntryPath(_ path: WorkspacePath, resolvesPaths: Bool) async throws -> WorkspacePath {
        guard resolvesPaths, !path.isRoot else { return path }
        let parent = try await resolvedCapturePath(path.dirname)
        return parent.appending(path.basename)
    }

    // Resolve existing ancestors, preserving missing suffixes for creation edits.
    // A dangling leaf still has a target even when resolveRealPath requires that
    // target to exist. Only absence permits fallback; authorization errors escape.
    private func resolvedCapturePath(_ path: WorkspacePath, linkDepth: Int = 0) async throws -> WorkspacePath {
        guard linkDepth < 64 else {
            throw WorkspaceError.invalidPath("symbolic link cycle at \(path)")
        }
        if path.isRoot { return try await filesystem.resolveRealPath(path: path) }
        let parent = try await resolvedCapturePath(path.dirname, linkDepth: linkDepth)
        let entry = parent.appending(path.basename)
        guard let info = try await Snapshot.infoIfPresent(at: entry, on: filesystem) else { return entry }
        guard info.kind == .symlink else { return entry }
        do {
            let resolved = try await filesystem.resolveRealPath(path: entry)
            if resolved != entry {
                return try await resolvedCapturePath(resolved, linkDepth: linkDepth + 1)
            }
        } catch {
            guard Snapshot.isMissingEntry(error) else { throw error }
        }
        let target = try await filesystem.readSymlink(path: entry)
        // Absolute fallback targets are interpreted as workspace paths.
        let targetPath = WorkspacePath(normalizing: target, relativeTo: entry.dirname)
        return try await resolvedCapturePath(targetPath, linkDepth: linkDepth + 1)
    }

    func captureRoot(for path: WorkspacePath) async throws -> WorkspacePath {
        var root = path
        while !root.dirname.isRoot,
              try await Snapshot.infoIfPresent(at: root.dirname, on: filesystem) == nil {
            root = root.dirname
        }
        return root
    }

    @discardableResult
    public func writeText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
        try await apply([.writeText(path, content)]).changes
    }

    @discardableResult
    public func appendText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
        try await apply([.appendText(path, content)]).changes
    }

    @discardableResult
    public func appendData(_ path: WorkspacePath, _ data: Data) async throws -> ChangeSet {
        try await apply([.appendData(path, data)]).changes
    }

    @discardableResult
    public func createDirectory(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
        try await apply([.createDirectory(path, recursive: recursive)]).changes
    }

    @discardableResult
    public func remove(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
        try await apply([.remove(path, recursive: recursive)]).changes
    }

    @discardableResult
    public func copy(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true)
        async throws -> ChangeSet
    {
        try await apply([.copy(from: source, to: destination, recursive: recursive)]).changes
    }

    @discardableResult
    public func move(from source: WorkspacePath, to destination: WorkspacePath) async throws -> ChangeSet {
        try await apply([.move(from: source, to: destination)]).changes
    }

    @discardableResult
    public func createSymbolicLink(_ path: WorkspacePath, target: String) async throws -> ChangeSet {
        try await apply([.createSymbolicLink(path, target: target)]).changes
    }

    @discardableResult
    public func createHardLink(_ path: WorkspacePath, target: WorkspacePath) async throws -> ChangeSet {
        try await apply([.createHardLink(path, target: target)]).changes
    }

    @discardableResult
    public func setPermissions(_ permissions: POSIXPermissions, at path: WorkspacePath) async throws -> ChangeSet {
        try await apply([.setPermissions(path, permissions)]).changes
    }

    func changeSet(from before: Snapshot, to after: Snapshot) -> ChangeSet {
        changeSet(from: [before], to: [after])
    }

    func changeSet(
        from before: [Snapshot], to after: [Snapshot], maxTextBytes: Int? = DiffOptions.default.maxTextBytes
    ) -> ChangeSet {
        let parts = zip(before, after).map {
            ChangeSet.compare(before: $0, after: $1, maxTextBytes: maxTextBytes)
        }
        return ChangeSet(
            changes: parts.flatMap(\.changes),
            textDiffOmissions: parts.flatMap(\.textDiffOmissions)
        )
    }

    func recordingChanges(_ changes: ChangeSet, from before: Snapshot, to after: Snapshot) -> ChangeSet {
        recordingChanges(changes, from: [before], to: [after])
    }

    func recordingChanges(_ changes: ChangeSet, from before: [Snapshot], to after: [Snapshot]) -> ChangeSet {
        switch recording {
        case let .full(limit):
            if limit == DiffOptions.default.maxTextBytes { return changes }
            return changeSet(from: before, to: after, maxTextBytes: limit)
        case .changesOnly, .off:
            return ChangeSet(changes: changes.changes.map { change in
                var copy = change
                copy.diff = nil
                return copy
            })
        }
    }

    private static func apply(_ edit: Edit, to fileSystem: any FileSystem) async throws {
        switch edit {
        case let .writeText(path, content):
            try await fileSystem.writeFile(path: path, data: Data(content.utf8), append: false)
        case let .appendText(path, content):
            try await fileSystem.writeFile(path: path, data: Data(content.utf8), append: true)
        case let .writeData(path, data):
            try await fileSystem.writeFile(path: path, data: data, append: false)
        case let .appendData(path, data):
            try await fileSystem.writeFile(path: path, data: data, append: true)
        case let .createDirectory(path, recursive):
            try await fileSystem.createDirectory(path: path, recursive: recursive)
        case let .remove(path, recursive):
            try await fileSystem.remove(path: path, recursive: recursive)
        case let .copy(source, destination, recursive):
            try await fileSystem.copy(from: source, to: destination, recursive: recursive)
        case let .move(source, destination):
            try await fileSystem.move(from: source, to: destination)
        case let .createSymbolicLink(path, target):
            try await fileSystem.createSymlink(path: path, target: target)
        case let .createHardLink(path, target):
            try await fileSystem.createHardLink(path: path, target: target)
        case let .setPermissions(path, permissions):
            try await fileSystem.setPermissions(path: path, permissions: permissions)
        case let .replace(files, pattern, replacement):
            try await replace(files: files, pattern: pattern, replacement: replacement, on: fileSystem)
        }
    }

    private static func replace(
        files: FileSelection,
        pattern: TextPattern,
        replacement: String,
        on fileSystem: any FileSystem
    ) async throws {
        let paths = try await selectedFiles(files, on: fileSystem)
        for path in paths {
            let data = try await fileSystem.readFile(path: path)
            guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
                throw WorkspaceError.invalidEncoding(path)
            }
            let updated: String
            switch pattern {
            case let .literal(value, caseSensitive):
                guard !value.isEmpty else { throw WorkspaceError.unsupported("search pattern must not be empty") }
                updated = text.replacingOccurrences(
                    of: value,
                    with: replacement,
                    options: caseSensitive ? [] : [.caseInsensitive]
                )
            case let .regularExpression(value):
                guard !value.isEmpty else { throw WorkspaceError.unsupported("search pattern must not be empty") }
                let regex = try NSRegularExpression(pattern: value)
                updated = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..<text.endIndex, in: text),
                    withTemplate: replacement
                )
            }
            if updated != text {
                try await fileSystem.writeFile(path: path, data: Data(updated.utf8), append: false)
            }
        }
    }

    static func selectedFiles(_ selection: FileSelection, on fileSystem: any FileSystem) async throws
        -> [WorkspacePath]
    {
        var included = Set<WorkspacePath>()
        for pattern in selection.include {
            let resolved = WorkspacePath(normalizing: pattern, relativeTo: selection.root)
            included.formUnion(try await fileSystem.glob(pattern: resolved.string, currentDirectory: selection.root))
        }
        var excluded = Set<WorkspacePath>()
        for pattern in selection.exclude {
            let resolved = WorkspacePath(normalizing: pattern, relativeTo: selection.root)
            excluded.formUnion(try await fileSystem.glob(pattern: resolved.string, currentDirectory: selection.root))
        }
        var files: [WorkspacePath] = []
        for path in included.subtracting(excluded).sorted() {
            if try await fileSystem.stat(path: path).kind == .file {
                files.append(path)
            }
        }
        return files
    }
}
