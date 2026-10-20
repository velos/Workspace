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
        var readRange: @Sendable (WorkspacePath, UInt64, Int?) async throws -> Data

        var load: ChangeSet.RevisionLoader {
            let readRange = readRange
            return { path in try await readRange(path, 0, nil) }
        }
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
                readRange: { path, offset, length in
                    guard let entry = Self.snapshotEntry(at: path, in: snapshot.entry),
                          case let .file(file) = entry
                    else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
                    guard offset < UInt64(file.data.count) else { return Data() }
                    let start = Int(offset)
                    let count = min(length ?? file.data.count, file.data.count - start)
                    return Data(file.data.dropFirst(start).prefix(count))
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
                readRange: { path, offset, length in
                    guard let data = try await store.readSnapshotFile(
                        id: snapshotID,
                        workspaceId: workspaceID,
                        path: path,
                        offset: offset,
                        length: length
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
        let file = try await resolvedReadableFile(at: path, revision: revision)
        return try await file.readRange(offset, length)
    }

    struct ResolvedReadableFile: Sendable {
        var size: UInt64
        var readRange: @Sendable (UInt64, Int?) async throws -> Data
    }

    /// Resolve once for metadata and all reads needed to decode one UTF-8 page.
    func resolvedReadableFile(at path: WorkspacePath, revision: Revision) async throws -> ResolvedReadableFile {
        switch revision {
        case .current:
            let resolvedPath = try await filesystem.resolveRealPath(path: path)
            let metadata = try await filesystem.stat(path: resolvedPath)
            guard metadata.kind == .file else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
            }
            let filesystem = filesystem
            return ResolvedReadableFile(size: metadata.size, readRange: { offset, length in
                try await filesystem.readFile(path: resolvedPath, offset: offset, length: length)
            })
        case .checkpoint:
            let resolved = try await resolvedRevision(revision)
            let file = try resolved.index.readableFile(at: path)
            return ResolvedReadableFile(size: file.size, readRange: { offset, length in
                try await resolved.readRange(file.path, offset, length)
            })
        }
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
            if path.isWithin(child.path) {
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
