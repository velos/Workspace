import Foundation

extension Workspace {
    /// A portable, fully materialized subtree. Archives are not used for checkpoint storage.
    public struct Archive: Sendable, Codable, Equatable {
        public indirect enum Entry: Sendable, Codable, Equatable {
            case missing(WorkspacePath)
            case file(path: WorkspacePath, data: Data, permissions: POSIXPermissions)
            case directory(path: WorkspacePath, permissions: POSIXPermissions, children: [Entry])
            case symbolicLink(path: WorkspacePath, target: String, permissions: POSIXPermissions)

            public var path: WorkspacePath {
                switch self {
                case let .missing(path), let .file(path, _, _), let .directory(path, _, _),
                     let .symbolicLink(path, _, _):
                    path
                }
            }
        }

        public var root: WorkspacePath
        public var entry: Entry

        public init(root: WorkspacePath, entry: Entry) {
            self.root = root
            self.entry = entry
        }
    }

    /// Materializes a subtree from the current workspace or a checkpoint.
    public func archive(at path: WorkspacePath = .root, from revision: Revision = .current) async throws -> Archive {
        let snapshot: Snapshot
        switch revision {
        case .current:
            snapshot = try await Snapshot.capture(from: filesystem, at: path)
        case .checkpoint:
            let full = try await revisionSnapshot(revision)
            snapshot = Snapshot(rootPath: path, entry: Self.entry(at: path, in: full.entry))
        }
        return Archive(root: path, entry: Self.archiveEntry(snapshot.entry))
    }

    /// Restores a portable archive and records the resulting changes.
    @discardableResult
    public func restore(_ archive: Archive, at destination: WorkspacePath? = nil) async throws -> ChangeSet {
        try await ensureLoaded()
        let before = try await Snapshot.capture(from: filesystem)
        let destination = destination ?? archive.root
        let entry = Self.snapshotEntry(archive.entry, replacing: archive.root, with: destination)
        try await Snapshot.restore(Snapshot(rootPath: destination, entry: entry), to: filesystem)
        let after = try await Snapshot.capture(from: filesystem)
        let changes = changeSet(from: before, to: after)
        if !changes.isEmpty {
            try await appendMutation(operation: .archiveRestore, changes: changes)
            emitWorkspaceEvent(.changes(changes))
        }
        return changes
    }

    private static func archiveEntry(_ entry: Snapshot.Entry) -> Archive.Entry {
        switch entry {
        case let .missing(value): .missing(value.path)
        case let .file(value): .file(path: value.path, data: value.data, permissions: value.permissions)
        case let .directory(value):
            .directory(
                path: value.path,
                permissions: value.permissions,
                children: value.children.map(archiveEntry)
            )
        case let .symlink(value):
            .symbolicLink(path: value.path, target: value.target, permissions: value.permissions)
        }
    }

    private static func snapshotEntry(
        _ entry: Archive.Entry,
        replacing sourceRoot: WorkspacePath,
        with destinationRoot: WorkspacePath
    ) -> Snapshot.Entry {
        let path = rebased(entry.path, from: sourceRoot, to: destinationRoot)
        switch entry {
        case .missing:
            return .missing(.init(path: path))
        case let .file(_, data, permissions):
            return .file(.init(path: path, data: data, permissions: permissions))
        case let .directory(_, permissions, children):
            return .directory(
                .init(
                    path: path,
                    permissions: permissions,
                    children: children.map {
                        snapshotEntry($0, replacing: sourceRoot, with: destinationRoot)
                    }
                )
            )
        case let .symbolicLink(_, target, permissions):
            return .symlink(.init(path: path, target: target, permissions: permissions))
        }
    }

    private static func rebased(
        _ path: WorkspacePath,
        from sourceRoot: WorkspacePath,
        to destinationRoot: WorkspacePath
    ) -> WorkspacePath {
        guard path != sourceRoot else { return destinationRoot }
        let prefix = sourceRoot.isRoot ? "/" : sourceRoot.string + "/"
        guard path.string.hasPrefix(prefix) else { return path }
        return destinationRoot.appending(String(path.string.dropFirst(prefix.count)))
    }

    private static func entry(at path: WorkspacePath, in entry: Snapshot.Entry) -> Snapshot.Entry {
        if entry.path == path { return entry }
        guard case let .directory(directory) = entry else { return .missing(.init(path: path)) }
        for child in directory.children {
            if child.path == path || path.string.hasPrefix(child.path.string + "/") {
                return self.entry(at: path, in: child)
            }
        }
        return .missing(.init(path: path))
    }

}
