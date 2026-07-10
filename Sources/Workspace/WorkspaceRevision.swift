import Foundation

/// A readable workspace revision.
public enum Revision: Sendable, Codable, Equatable {
    case current
    case checkpoint(UUID)
}

public struct DiffOptions: Sendable, Codable, Equatable {
    public var maxTextBytes: Int?

    public static let `default` = DiffOptions(maxTextBytes: 1_000_000)

    public init(maxTextBytes: Int?) {
        self.maxTextBytes = maxTextBytes
    }
}

extension Workspace {
    /// Compares any two workspace revisions.
    public func diff(
        from source: Revision,
        to destination: Revision,
        options: DiffOptions = .default
    ) async throws -> ChangeSet {
        if let maxTextBytes = options.maxTextBytes, maxTextBytes < 0 {
            throw WorkspaceError.unsupported("text diff byte limit must not be negative")
        }
        let currentSnapshot: Snapshot? = if source == .current || destination == .current {
            try await Snapshot.capture(from: filesystem)
        } else {
            nil
        }
        async let before = resolvedRevision(source, currentSnapshot: currentSnapshot)
        async let after = resolvedRevision(destination, currentSnapshot: currentSnapshot)
        let (beforeRevision, afterRevision) = try await (before, after)
        return try await ChangeSet.compare(
            before: beforeRevision.index,
            after: afterRevision.index,
            maxTextBytes: options.maxTextBytes,
            loadBefore: beforeRevision.load,
            loadAfter: afterRevision.load
        )
    }

    func revisionSnapshot(_ revision: Revision) async throws -> Snapshot {
        switch revision {
        case .current:
            return try await Snapshot.capture(from: filesystem)
        case let .checkpoint(id):
            try await ensureLoaded()
            try await reconcileCheckpointsWithStore()
            let checkpoint = try checkpointOrThrow(id: id)
            return try await loadSnapshotOrThrow(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceId)
        }
    }

    struct ResolvedRevision: Sendable {
        var index: RevisionIndex
        var load: ChangeSet.RevisionLoader
    }

    func resolvedRevision(_ revision: Revision, currentSnapshot: Snapshot? = nil) async throws -> ResolvedRevision {
        switch revision {
        case .current:
            let snapshot: Snapshot
            if let currentSnapshot {
                snapshot = currentSnapshot
            } else {
                snapshot = try await Snapshot.capture(from: filesystem)
            }
            return ResolvedRevision(
                index: RevisionIndex(snapshot: snapshot),
                load: { path in
                    guard let entry = Self.snapshotEntry(at: path, in: snapshot.entry),
                          case let .file(file) = entry
                    else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
                    return file.data
                }
            )
        case let .checkpoint(id):
            try await ensureLoaded()
            try await reconcileCheckpointsWithStore()
            let checkpoint = try checkpointOrThrow(id: id)
            guard let index = try await store.loadRevisionIndex(
                id: checkpoint.snapshotId,
                workspaceId: checkpoint.workspaceId
            ) else {
                throw WorkspaceError.revisionDataNotFound(checkpoint.snapshotId)
            }
            let store = store
            let workspaceID = checkpoint.workspaceId
            let snapshotID = checkpoint.snapshotId
            return ResolvedRevision(
                index: index,
                load: { path in
                    guard let data = try await store.readSnapshotFile(
                        id: snapshotID,
                        workspaceId: workspaceID,
                        path: path,
                        offset: 0,
                        length: nil
                    ) else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
                    }
                    return data
                }
            )
        }
    }

    func revisionData(
        at path: WorkspacePath,
        revision: Revision,
        offset: UInt64 = 0,
        length: Int? = nil
    ) async throws -> Data {
        let resolved = try await resolvedRevision(revision)
        var current = path
        for _ in 0..<64 {
            guard let entry = resolved.index.entry(at: current) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            switch entry {
            case .file:
                let data = try await resolved.load(current)
                guard offset < UInt64(data.count) else { return Data() }
                let start = data.index(data.startIndex, offsetBy: Int(offset))
                let end = length.map { data.index(start, offsetBy: $0, limitedBy: data.endIndex) ?? data.endIndex }
                    ?? data.endIndex
                return Data(data[start..<end])
            case let .symbolicLink(_, target, _):
                current = WorkspacePath(normalizing: target, relativeTo: current.parent)
            case .directory:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
            case .missing:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
    }

    public func info(_ path: WorkspacePath, at revision: Revision = .current) async throws -> FileInfo {
        switch revision {
        case .current:
            return try await filesystem.stat(path: path)
        case .checkpoint:
            let resolved = try await resolvedRevision(revision)
            guard let entry = resolved.index.entry(at: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            return Self.info(for: entry)
        }
    }

    public func list(_ path: WorkspacePath, at revision: Revision = .current) async throws -> [DirectoryEntry] {
        switch revision {
        case .current:
            return try await filesystem.listDirectory(path: path)
        case .checkpoint:
            let resolved = try await resolvedRevision(revision)
            guard let entry = resolved.index.entry(at: path),
                  case let .directory(_, _, children) = entry
            else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
            }
            return children.map { DirectoryEntry(name: $0.path.name, info: Self.info(for: $0)) }
                .sorted { $0.name < $1.name }
        }
    }

    public func tree(
        at path: WorkspacePath = .root,
        revision: Revision = .current,
        maxDepth: Int? = nil
    ) async throws -> FileTree {
        switch revision {
        case .current:
            return try await currentTree(at: path, depth: 0, maxDepth: maxDepth)
        case .checkpoint:
            let resolved = try await resolvedRevision(revision)
            guard let entry = resolved.index.entry(at: path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
            return Self.fileTree(entry, depth: 0, maxDepth: maxDepth)
        }
    }

    private func currentTree(at path: WorkspacePath, depth: Int, maxDepth: Int?) async throws -> FileTree {
        let metadata = try await filesystem.stat(path: path)
        let children: [FileTree]?
        if metadata.kind == .directory, maxDepth.map({ depth < $0 }) ?? true {
            var nested: [FileTree] = []
            for entry in try await filesystem.listDirectory(path: path) {
                nested.append(try await currentTree(at: entry.info.path, depth: depth + 1, maxDepth: maxDepth))
            }
            children = nested
        } else {
            children = nil
        }
        return FileTree(
            path: metadata.path,
            kind: metadata.kind,
            size: metadata.size,
            permissions: metadata.permissions,
            modificationDate: metadata.modificationDate,
            children: children
        )
    }

    static func snapshotEntry(at path: WorkspacePath, in entry: Snapshot.Entry) -> Snapshot.Entry? {
        if entry.path == path { return entry }
        guard case let .directory(directory) = entry else { return nil }
        for child in directory.children {
            if child.path == path || path.string.hasPrefix(child.path.string + "/") {
                return snapshotEntry(at: path, in: child)
            }
        }
        return nil
    }

    private static func info(for entry: RevisionIndex.Entry) -> FileInfo {
        FileInfo(
            path: entry.path,
            kind: entry.kind ?? .file,
            size: entry.size,
            permissions: entry.permissions ?? .defaultFile,
            modificationDate: nil
        )
    }

    private static func fileTree(_ entry: RevisionIndex.Entry, depth: Int, maxDepth: Int?) -> FileTree {
        let metadata = info(for: entry)
        let children: [FileTree]?
        if case let .directory(_, _, entries) = entry, maxDepth.map({ depth < $0 }) ?? true {
            children = entries.map { fileTree($0, depth: depth + 1, maxDepth: maxDepth) }
        } else {
            children = nil
        }
        return FileTree(
            path: metadata.path,
            kind: metadata.kind,
            size: metadata.size,
            permissions: metadata.permissions,
            modificationDate: nil,
            children: children
        )
    }

    static func indexPaths(_ entry: RevisionIndex.Entry) -> [WorkspacePath] {
        if case let .directory(_, _, children) = entry {
            return [entry.path] + children.flatMap(indexPaths)
        }
        return [entry.path]
    }
}
