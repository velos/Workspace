import Foundation

public enum WorkspaceTreeNodeKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
}

public struct WorkspaceTreeNode: Sendable {
    public var path: WorkspacePath
    public var kind: WorkspaceTreeNodeKind
    public var size: UInt64
    public var permissions: Int
    public var modificationDate: Date?
    public var children: [WorkspaceTreeNode]?

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

public struct WorkspaceTreeSummaryEntry: Sendable {
    public var path: WorkspacePath
    public var kind: WorkspaceTreeNodeKind
    public var size: UInt64
    public var permissions: Int

    public init(path: WorkspacePath, kind: WorkspaceTreeNodeKind, size: UInt64, permissions: Int) {
        self.path = path
        self.kind = kind
        self.size = size
        self.permissions = permissions
    }

    public init(path: String, kind: WorkspaceTreeNodeKind, size: UInt64, permissions: Int) {
        self.init(path: WorkspacePath(normalizing: path), kind: kind, size: size, permissions: permissions)
    }
}

public struct WorkspaceTreeSummary: Sendable {
    public var path: WorkspacePath
    public var fileCount: Int
    public var directoryCount: Int
    public var symlinkCount: Int
    public var totalBytes: UInt64
    public var children: [WorkspaceTreeSummaryEntry]

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

public struct WorkspaceTextChange: Sendable {
    public var path: WorkspacePath
    public var replacements: Int
    public var originalContent: String
    public var updatedContent: String

    public init(path: WorkspacePath, replacements: Int, originalContent: String, updatedContent: String) {
        self.path = path
        self.replacements = replacements
        self.originalContent = originalContent
        self.updatedContent = updatedContent
    }

    public init(path: String, replacements: Int, originalContent: String, updatedContent: String) {
        self.init(
            path: WorkspacePath(normalizing: path),
            replacements: replacements,
            originalContent: originalContent,
            updatedContent: updatedContent
        )
    }
}

public struct WorkspaceReplaceResult: Sendable {
    public var dryRun: Bool
    public var touchedPaths: [WorkspacePath]
    public var changes: [WorkspaceTextChange]
    public var rolledBack: Bool

    public init(
        dryRun: Bool,
        touchedPaths: [WorkspacePath],
        changes: [WorkspaceTextChange],
        rolledBack: Bool
    ) {
        self.dryRun = dryRun
        self.touchedPaths = touchedPaths
        self.changes = changes
        self.rolledBack = rolledBack
    }
}

public enum WorkspaceEdit: Sendable {
    case writeFile(path: WorkspacePath, content: String)
    case appendFile(path: WorkspacePath, content: String)
    case delete(path: WorkspacePath, recursive: Bool = true)
    case createDirectory(path: WorkspacePath, recursive: Bool = true)
    case move(from: WorkspacePath, to: WorkspacePath)
    case copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool = true)
}

public struct WorkspaceBatchEditEntry: Sendable {
    public var operation: String
    public var touchedPaths: [WorkspacePath]
    public var originalContent: String?
    public var updatedContent: String?

    public init(
        operation: String,
        touchedPaths: [WorkspacePath],
        originalContent: String? = nil,
        updatedContent: String? = nil
    ) {
        self.operation = operation
        self.touchedPaths = touchedPaths
        self.originalContent = originalContent
        self.updatedContent = updatedContent
    }
}

public struct WorkspaceBatchEditResult: Sendable {
    public var dryRun: Bool
    public var touchedPaths: [WorkspacePath]
    public var edits: [WorkspaceBatchEditEntry]
    public var rolledBack: Bool

    public init(
        dryRun: Bool,
        touchedPaths: [WorkspacePath],
        edits: [WorkspaceBatchEditEntry],
        rolledBack: Bool
    ) {
        self.dryRun = dryRun
        self.touchedPaths = touchedPaths
        self.edits = edits
        self.rolledBack = rolledBack
    }
}

public actor Workspace {
    private let filesystem: any WorkspaceFilesystem

    public init(filesystem: any WorkspaceFilesystem) {
        self.filesystem = filesystem
    }

    public func readFile(_ path: WorkspacePath) async throws -> String {
        let data = try await filesystem.readFile(path: normalize(path))
        guard let string = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.unsupported("file is not valid UTF-8: \(normalize(path))")
        }
        return string
    }

    public func readFile(_ path: String) async throws -> String {
        try await readFile(WorkspacePath(validating: path))
    }

    public func writeFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: normalize(path), data: Data(content.utf8), append: false)
    }

    public func writeFile(_ path: String, content: String) async throws {
        try await writeFile(WorkspacePath(validating: path), content: content)
    }

    public func appendFile(_ path: WorkspacePath, content: String) async throws {
        try await filesystem.writeFile(path: normalize(path), data: Data(content.utf8), append: true)
    }

    public func appendFile(_ path: String, content: String) async throws {
        try await appendFile(WorkspacePath(validating: path), content: content)
    }

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

    public func readJson<T: Decodable>(
        _ path: String,
        as type: T.Type = T.self
    ) async throws -> T {
        try await readJson(WorkspacePath(validating: path), as: type)
    }

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

    public func writeJson<T: Encodable>(
        _ path: String,
        value: T,
        prettyPrinted: Bool = true
    ) async throws {
        try await writeJson(WorkspacePath(validating: path), value: value, prettyPrinted: prettyPrinted)
    }

    public func exists(_ path: WorkspacePath) async -> Bool {
        await filesystem.exists(path: normalize(path))
    }

    public func exists(_ path: String) async -> Bool {
        guard let path = WorkspacePath(path) else {
            return false
        }
        return await exists(path)
    }

    public func stat(_ path: WorkspacePath) async throws -> FileInfo {
        try await filesystem.stat(path: normalize(path))
    }

    public func stat(_ path: String) async throws -> FileInfo {
        try await stat(WorkspacePath(validating: path))
    }

    public func readdir(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await filesystem.listDirectory(path: normalize(path))
    }

    public func readdir(_ path: String) async throws -> [DirectoryEntry] {
        try await readdir(WorkspacePath(validating: path))
    }

    public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
        try await filesystem.glob(
            pattern: pattern,
            currentDirectory: normalize(currentDirectory)
        )
    }

    public func glob(_ pattern: String, currentDirectory: String) async throws -> [WorkspacePath] {
        try await glob(pattern, currentDirectory: WorkspacePath(validating: currentDirectory))
    }

    public func mkdir(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.createDirectory(path: normalize(path), recursive: recursive)
    }

    public func mkdir(_ path: String, recursive: Bool = true) async throws {
        try await mkdir(WorkspacePath(validating: path), recursive: recursive)
    }

    public func rm(_ path: WorkspacePath, recursive: Bool = true) async throws {
        try await filesystem.remove(path: normalize(path), recursive: recursive)
    }

    public func rm(_ path: String, recursive: Bool = true) async throws {
        try await rm(WorkspacePath(validating: path), recursive: recursive)
    }

    public func cp(_ sourcePath: WorkspacePath, _ destinationPath: WorkspacePath, recursive: Bool = true)
        async throws
    {
        try await filesystem.copy(
            from: normalize(sourcePath),
            to: normalize(destinationPath),
            recursive: recursive
        )
    }

    public func cp(_ sourcePath: String, _ destinationPath: String, recursive: Bool = true) async throws {
        try await cp(
            WorkspacePath(validating: sourcePath),
            WorkspacePath(validating: destinationPath),
            recursive: recursive
        )
    }

    public func mv(_ sourcePath: WorkspacePath, _ destinationPath: WorkspacePath) async throws {
        try await filesystem.move(
            from: normalize(sourcePath),
            to: normalize(destinationPath)
        )
    }

    public func mv(_ sourcePath: String, _ destinationPath: String) async throws {
        try await mv(WorkspacePath(validating: sourcePath), WorkspacePath(validating: destinationPath))
    }

    public func walkTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await buildTree(path: normalize(path), depth: 0, maxDepth: maxDepth)
    }

    public func walkTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeNode {
        try await walkTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    public func summarizeTree(_ path: WorkspacePath, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await buildSummary(path: normalize(path), depth: 0, maxDepth: maxDepth)
    }

    public func summarizeTree(_ path: String, maxDepth: Int? = nil) async throws -> WorkspaceTreeSummary {
        try await summarizeTree(WorkspacePath(validating: path), maxDepth: maxDepth)
    }

    public func replaceInFiles(
        _ pattern: String,
        search: String,
        replacement: String,
        dryRun: Bool = false,
        rollbackOnError: Bool = true
    ) async throws -> WorkspaceReplaceResult {
        let paths = try await filesystem.glob(pattern: pattern, currentDirectory: "/").sorted()
        var changes: [WorkspaceTextChange] = []

        for path in paths {
            guard let originalContent = try await readUTF8IfPresent(path) else {
                continue
            }
            let replacedCount = originalContent.components(separatedBy: search).count - 1
            guard replacedCount > 0 else {
                continue
            }

            let updatedContent = originalContent.replacingOccurrences(of: search, with: replacement)
            changes.append(
                WorkspaceTextChange(
                    path: path,
                    replacements: replacedCount,
                    originalContent: originalContent,
                    updatedContent: updatedContent
                )
            )
        }

        guard !dryRun, !changes.isEmpty else {
            return WorkspaceReplaceResult(
                dryRun: dryRun,
                touchedPaths: changes.map(\.path),
                changes: changes,
                rolledBack: false
            )
        }

        let snapshots = try await snapshotPaths(changes.map(\.path))
        do {
            for change in changes {
                try await filesystem.writeFile(
                    path: change.path,
                    data: Data(change.updatedContent.utf8),
                    append: false
                )
            }
            return WorkspaceReplaceResult(
                dryRun: false,
                touchedPaths: changes.map(\.path),
                changes: changes,
                rolledBack: false
            )
        } catch {
            guard rollbackOnError else {
                throw error
            }

            try await rollback(snapshots)
            return WorkspaceReplaceResult(
                dryRun: false,
                touchedPaths: changes.map(\.path),
                changes: changes,
                rolledBack: true
            )
        }
    }

    public func applyEdits(
        _ edits: [WorkspaceEdit],
        dryRun: Bool = false,
        rollbackOnError: Bool = true
    ) async throws -> WorkspaceBatchEditResult {
        let normalizedEdits = edits.map(normalize(edit:))
        let touchedPaths = canonicalizedTouchedPaths(for: normalizedEdits)
        let previewEntries = try await previewEntries(for: normalizedEdits)

        guard !dryRun, !normalizedEdits.isEmpty else {
            return WorkspaceBatchEditResult(
                dryRun: dryRun,
                touchedPaths: touchedPaths,
                edits: previewEntries,
                rolledBack: false
            )
        }

        let snapshots = try await snapshotPaths(touchedPaths)
        do {
            for edit in normalizedEdits {
                try await apply(edit)
            }
            return WorkspaceBatchEditResult(
                dryRun: false,
                touchedPaths: touchedPaths,
                edits: previewEntries,
                rolledBack: false
            )
        } catch {
            guard rollbackOnError else {
                throw error
            }

            try await rollback(snapshots)
            return WorkspaceBatchEditResult(
                dryRun: false,
                touchedPaths: touchedPaths,
                edits: previewEntries,
                rolledBack: true
            )
        }
    }

    private func normalize(_ path: WorkspacePath) -> WorkspacePath {
        WorkspacePath(normalizing: path.string)
    }

    private func readUTF8IfPresent(_ path: WorkspacePath) async throws -> String? {
        guard await filesystem.exists(path: path) else {
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

    private func canonicalizedTouchedPaths(for edits: [WorkspaceEdit]) -> [WorkspacePath] {
        let paths = Set(edits.flatMap(touchedPaths(for:)))
        return paths.sorted().filter { candidate in
            !paths.contains { other in
                other != candidate && candidate.string.hasPrefix(other.string + "/")
            }
        }
    }

    private func previewEntries(for edits: [WorkspaceEdit]) async throws -> [WorkspaceBatchEditEntry] {
        var entries: [WorkspaceBatchEditEntry] = []
        for edit in edits {
            switch edit {
            case let .writeFile(path, content):
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: "writeFile",
                        touchedPaths: [path],
                        originalContent: try await readUTF8IfPresent(path),
                        updatedContent: content
                    )
                )
            case let .appendFile(path, content):
                let original = try await readUTF8IfPresent(path)
                entries.append(
                    WorkspaceBatchEditEntry(
                        operation: "appendFile",
                        touchedPaths: [path],
                        originalContent: original,
                        updatedContent: (original ?? "") + content
                    )
                )
            case let .delete(path, _):
                entries.append(WorkspaceBatchEditEntry(operation: "delete", touchedPaths: [path]))
            case let .createDirectory(path, _):
                entries.append(WorkspaceBatchEditEntry(operation: "createDirectory", touchedPaths: [path]))
            case let .move(from, to):
                entries.append(WorkspaceBatchEditEntry(operation: "move", touchedPaths: [from, to]))
            case let .copy(from, to, _):
                entries.append(WorkspaceBatchEditEntry(operation: "copy", touchedPaths: [from, to]))
            }
        }
        return entries
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
