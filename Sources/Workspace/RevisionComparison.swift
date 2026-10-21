import Foundation

/// A checkpoint plus one live metadata walk. Only suspect files acquire bytes;
/// unchanged nodes continue to refer to the immutable checkpoint.
struct RevisionComparison: Sendable {
    var checkpoint: TransactionTree
    var current: TransactionTree
    var metadata: MetadataIndex
    var changed: Set<WorkspacePath>

    static func capture(
        _ revision: CapturedRevision, from fs: any FileSystem,
        policy: Workspace.CheckpointCapturePolicy, load: @escaping ChangeSet.RevisionLoader
    ) async throws -> Self {
        let checkpoint = TransactionTree(index: revision.index, load: load)
        var metadata = MetadataIndex()
        metadata.exactTimestamps = await fs.supportsExactContentTimestamps
        var nodes: [WorkspacePath: Workspace.MergeNode] = [:]
        var changed: Set<WorkspacePath> = []
        try await fs.walk { info, read, readLink in
            let target = info.kind == .symlink ? try await readLink() : nil
            let entry = MetadataIndex.Entry(info: info, target: target)
            metadata.entries[info.path] = entry
            var node = Workspace.MergeNode(kind: info.kind, permissions: info.permissions, symlinkTarget: target)
            if info.kind == .file {
                if policy == .trustMetadata, let old = revision.metadata.entries[info.path],
                   entry.canReuseContents(old, capturedAt: revision.metadata.capturedAt,
                        exactTimestamps: metadata.exactTimestamps && revision.metadata.exactTimestamps),
                   let existing = checkpoint.nodes[info.path], existing.kind == .file,
                   existing.permissions == info.permissions {
                    node = existing
                    node.permissions = info.permissions
                } else {
                    let bytes = try await read(nil)
                    node = .init(kind: .file, permissions: info.permissions, fileData: bytes,
                                 contentID: SHA256.hexDigest(of: bytes), size: UInt64(bytes.count))
                }
            }
            if node != checkpoint.nodes[info.path] { changed.insert(info.path) }
            nodes[info.path] = node
        }
        changed.formUnion(checkpoint.nodes.keys.filter { nodes[$0] == nil })
        return Self(checkpoint: checkpoint, current: TransactionTree(nodes: nodes, load: load),
                    metadata: metadata, changed: changed)
    }

    /// Matching directories are sparse containers, including permission-only
    /// changes. Structural replacements own their complete old/new subtrees.
    func restoreScope() -> Set<WorkspacePath> {
        var directories: Set<WorkspacePath> = []
        for path in changed {
            var ancestor = path
            while true {
                if current.nodes[ancestor]?.kind == .directory,
                   checkpoint.nodes[ancestor]?.kind == .directory { directories.insert(ancestor) }
                if ancestor.isRoot { break }
                ancestor = ancestor.parent
            }
        }
        // A no-op still publishes a checkpoint, with an empty root patch.
        if current.nodes[.root]?.kind == .directory, checkpoint.nodes[.root]?.kind == .directory {
            directories.insert(.root)
        }
        return directories
    }

    func sparseSnapshot(in tree: TransactionTree, preserving directories: Set<WorkspacePath>) async throws -> Snapshot {
        var children: [WorkspacePath: Set<WorkspacePath>] = [:]
        for path in changed.union(directories) where !path.isRoot {
            children[path.parent, default: []].insert(path)
        }
        func entry(_ path: WorkspacePath) async throws -> Snapshot.Entry {
            if directories.contains(path), let node = tree.nodes[path] {
                var entries: [Snapshot.Entry] = []
                for child in (children[path] ?? []).sorted() { entries.append(try await entry(child)) }
                return .directory(.init(path: path, permissions: node.permissions, children: entries))
            }
            return try await tree.snapshot(at: path).entry
        }
        return Snapshot(rootPath: .root, entry: try await entry(.root))
    }
}

extension TransactionTree {
    func revisionIndex(paths: Set<WorkspacePath>? = nil) -> RevisionIndex {
        var selectedChildren = children
        if let paths {
            var selected = paths
            for path in paths {
                var ancestor = path
                while !ancestor.isRoot {
                    ancestor = ancestor.parent
                    selected.insert(ancestor)
                }
            }
            selectedChildren = [:]
            for path in selected where !path.isRoot { selectedChildren[path.parent, default: []].append(path) }
        }
        func entry(_ path: WorkspacePath) -> RevisionIndex.Entry {
            guard let node = nodes[path] else { return .missing(path: path) }
            switch node.kind {
            case .file:
                return .file(path: path, size: node.size, permissions: node.permissions, contentID: node.contentID!)
            case .symlink:
                return .symbolicLink(path: path, target: node.symlinkTarget!, permissions: node.permissions)
            case .directory:
                return .directory(path: path, permissions: node.permissions,
                                  children: (selectedChildren[path] ?? []).sorted().map(entry))
            }
        }
        return RevisionIndex(id: UUID(), root: .root, entry: entry(.root))
    }
}

extension Snapshot {
    /// Recapture only the scope actually restored. Ancestor modes are observed
    /// without traversing their unaffected children.
    static func captureSparse(
        from fs: any FileSystem, template: Snapshot, preserving directories: Set<WorkspacePath>,
        metadata: inout MetadataIndex, previousChildren: [WorkspacePath: [WorkspacePath]]
    ) async throws -> Snapshot {
        func forget(_ path: WorkspacePath) {
            metadata.entries.removeValue(forKey: path)
            for child in previousChildren[path] ?? [] { forget(child) }
        }
        func capture(_ template: Entry) async throws -> Entry {
            let path = template.path
            if directories.contains(path), case let .directory(directory) = template {
                let info = try await fs.stat(path: path)
                metadata.entries[path] = .init(info: info, target: nil)
                var children: [Entry] = []
                for child in directory.children { children.append(try await capture(child)) }
                return .directory(.init(path: path, permissions: info.permissions, children: children))
            }
            forget(path)
            var children: [WorkspacePath: [Entry]] = [:]
            var root: Entry = .missing(.init(path: path))
            try await fs.walk(at: path) { info, read, readLink in
                let target = info.kind == .symlink ? try await readLink() : nil
                metadata.entries[info.path] = .init(info: info, target: target)
                let entry: Entry
                switch info.kind {
                case .file:
                    let bytes = try await read(nil)
                    entry = .file(.init(path: info.path, data: bytes, permissions: info.permissions,
                                        contentID: SHA256.hexDigest(of: bytes)))
                case .symlink:
                    entry = .symlink(.init(path: info.path, target: target!, permissions: info.permissions))
                case .directory:
                    entry = .directory(.init(path: info.path, permissions: info.permissions,
                        children: (children.removeValue(forKey: info.path) ?? []).sorted { $0.path < $1.path }))
                }
                if info.path == path { root = entry }
                else { children[info.path.parent, default: []].append(entry) }
            }
            return root
        }
        return Snapshot(rootPath: template.rootPath, entry: try await capture(template.entry))
    }
}

extension FilesystemObservation {
    /// Retain cached bytes outside the restored scope. Replacing the observation
    /// root with a sparse snapshot would discard those bytes and turn later
    /// unrelated external edits into cache misses.
    mutating func reconcileRestoration(
        _ entry: Snapshot.Entry, preserving directories: Set<WorkspacePath>, metadata replacement: MetadataIndex
    ) {
        if directories.contains(entry.path), case let .directory(directory) = entry,
           metadata.entries[entry.path]?.info.kind == .directory {
            metadata.entries[entry.path] = replacement.entries[entry.path]
            for child in directory.children {
                reconcileRestoration(child, preserving: directories, metadata: replacement)
            }
            return
        }
        var scoped = MetadataIndex()
        if directories.contains(entry.path) {
            // Observation may predate an out-of-band structural change. Rebuild
            // that subtree's metadata from the walk already completed by restore.
            scoped.entries = replacement.entries.filter { $0.key.isWithin(entry.path) }
        } else {
            func collect(_ entry: Snapshot.Entry) {
                scoped.entries[entry.path] = replacement.entries[entry.path]
                if case let .directory(directory) = entry { directory.children.forEach(collect) }
            }
            collect(entry)
        }
        replace(root: entry.path, metadata: scoped)
        remember(entry)
    }
}
