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
    @discardableResult
    public func apply(_ edits: [Edit], policy: EditPolicy = .atomic) async throws -> EditResult {
        try await ensureLoaded()
        let before = try await Snapshot.capture(from: filesystem)
        var failures: [EditFailure] = []

        for (index, edit) in edits.enumerated() {
            do {
                try await Self.apply(edit, to: filesystem)
            } catch {
                let failure = EditFailure(index: index, edit: edit, message: String(describing: error))
                switch policy {
                case .atomic:
                    try await Snapshot.restore(before, to: filesystem)
                    throw error
                case .stopOnError:
                    failures.append(failure)
                    break
                case .continueAfterError:
                    failures.append(failure)
                    continue
                }
                break
            }
        }

        let after = try await Snapshot.capture(from: filesystem)
        noteWorkspaceSnapshot(after)
        let changes = changeSet(from: before, to: after)
        if !changes.isEmpty {
            try await appendMutation(operation: .edit, changes: changes)
            emitWorkspaceEvent(.changes(changes))
        }
        return EditResult(changes: changes, failures: failures)
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
        let limit: Int?
        switch recording {
        case let .full(maxTextBytes): limit = maxTextBytes
        case .changesOnly, .off: limit = 0
        }
        var result = ChangeSet.compare(before: before, after: after, maxTextBytes: limit)
        if case .full = recording {
            return result
        }
        result.changes = result.changes.map { change in
            var copy = change
            copy.diff = nil
            return copy
        }
        result.textDiffOmissions = []
        return result
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
