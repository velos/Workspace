import Foundation

/// Separate from the capture walker: readers obtain a frozen index and its capture
/// hints together; writers publish a sparse patch over an existing immutable revision.
protocol CheckpointRevisionStore: Sendable {
    func loadCapturedRevision(id: UUID, workspaceId: UUID) async throws -> CapturedRevision?
    func publishRevision(
        reusing id: UUID, patch: Snapshot, preservingDirectories: Set<WorkspacePath>,
        metadata: MetadataIndex, draft: CheckpointDraft
    ) async throws -> Checkpoint
}

struct CapturedRevision: Sendable {
    var index: RevisionIndex
    var metadata: MetadataIndex
}

/// Hints are optional: evicted revisions use content verification. Bound retention
/// across workspaces so checkpoint history does not retain a second full tree each time.
struct CaptureMetadataCache: Sendable {
    private var entries: [UUID: MetadataIndex] = [:]
    private var recent: [UUID] = []

    subscript(id: UUID) -> MetadataIndex? { entries[id] }

    mutating func insert(_ metadata: MetadataIndex, for id: UUID) {
        recent.removeAll { $0 == id }
        recent.append(id)
        entries[id] = metadata
        if recent.count > 4 { entries.removeValue(forKey: recent.removeFirst()) }
    }

    mutating func retain(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
        recent.removeAll { !ids.contains($0) }
    }
}

extension CheckpointStore {
    // Conservative compatibility for decorators and stores without capture hints.
    func loadCapturedRevision(id: UUID, workspaceId: UUID) async throws -> CapturedRevision? {
        guard let index = try await loadRevisionIndex(id: id, workspaceId: workspaceId) else { return nil }
        return CapturedRevision(index: index, metadata: MetadataIndex())
    }

    func publishRevision(
        reusing id: UUID, patch: Snapshot, preservingDirectories: Set<WorkspacePath>,
        metadata: MetadataIndex, draft: CheckpointDraft
    ) async throws -> Checkpoint {
        guard var snapshot = try await loadSnapshot(id: id, workspaceId: draft.workspaceID) else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        snapshot.id = UUID()
        snapshot.entry = Snapshot.patching(snapshot.entry, with: patch.entry, preserving: preservingDirectories)
        return try await saveRevision(snapshot, draft: draft)
    }
}

extension InMemoryCheckpointStore {
    func captureRevisionWithMetadata(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint {
        let cursor = persistedMutationCursor(workspaceId: draft.workspaceID)
        var metadata: MetadataIndex? = MetadataIndex()
        let snapshot = try await Snapshot.capture(from: filesystem, metadata: &metadata)
        let checkpoint = try persistRevision(snapshot, draft: draft, mutationCursor: cursor)
        captureMetadataBySnapshot.insert(metadata!, for: snapshot.id)
        return checkpoint
    }

    func loadCapturedRevision(id: UUID, workspaceId: UUID) async throws -> CapturedRevision? {
        guard let index = try await loadRevisionIndex(id: id, workspaceId: workspaceId) else { return nil }
        return CapturedRevision(index: index, metadata: captureMetadataBySnapshot[id] ?? MetadataIndex())
    }

    func publishRevision(
        reusing id: UUID, patch: Snapshot, preservingDirectories: Set<WorkspacePath>,
        metadata: MetadataIndex, draft: CheckpointDraft
    ) async throws -> Checkpoint {
        guard var snapshot = snapshotsByWorkspace[draft.workspaceID]?[id] else {
            throw WorkspaceError.revisionDataNotFound(id)
        }
        snapshot.id = UUID()
        snapshot.entry = Snapshot.patching(snapshot.entry, with: patch.entry, preserving: preservingDirectories)
        let checkpoint = try persistRevision(snapshot, draft: draft,
                                             mutationCursor: persistedMutationCursor(workspaceId: draft.workspaceID))
        captureMetadataBySnapshot.insert(metadata, for: snapshot.id)
        return checkpoint
    }
}

extension FileCheckpointStore {
    func loadCapturedRevision(id: UUID, workspaceId: UUID) async throws -> CapturedRevision? {
        try await validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try await withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            guard let manifest = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else { return nil }
            var metadata = MetadataIndex()
            // Legacy materialized snapshots have no trustworthy capture timestamp.
            metadata.capturedAt = manifest.captureStartedAt ?? .distantPast
            metadata.exactTimestamps = manifest.exactContentTimestamps ?? false
            func visit(_ node: SnapshotManifest.Node) throws -> RevisionIndex.Entry {
                let entry = try revisionEntry(from: node, workspaceId: workspaceId, depth: 0)
                if let kind = entry.kind {
                    metadata.entries[node.path] = .init(info: FileInfo(
                        path: node.path, kind: kind, size: entry.size,
                        permissions: entry.permissions!, modificationDate: node.modificationDate, identity: node.identity
                    ), target: node.symlinkTarget)
                }
                if case let .directory(path, permissions, _) = entry {
                    return .directory(path: path, permissions: permissions,
                        children: try children(of: node, workspaceId: workspaceId).map(visit))
                }
                return entry
            }
            let entry = try visit(manifest.root)
            return CapturedRevision(index: RevisionIndex(id: id, root: manifest.rootPath, entry: entry), metadata: metadata)
        }
    }

    func publishRevision(
        reusing id: UUID, patch: Snapshot, preservingDirectories: Set<WorkspacePath>,
        metadata: MetadataIndex, draft: CheckpointDraft
    ) async throws -> Checkpoint {
        try await ensureWorkspaceDirectories(for: draft.workspaceID)
        return try await withExclusiveLock(at: lifecycleLockURL(workspaceId: draft.workspaceID)) {
            let workspaceId = draft.workspaceID
            let cursor = try await persistedMutationCursor(workspaceId: workspaceId)
            guard let source = try loadManifestUnlocked(id: id, workspaceId: workspaceId) else {
                throw WorkspaceError.revisionDataNotFound(id)
            }
            let parent = resolvedParent(for: draft, checkpoints: try loadAllCheckpointsUnlocked(workspaceId: workspaceId))
            let parentManifest = try parent.map {
                guard let manifest = try loadManifestUnlocked(id: $0.snapshotId, workspaceId: workspaceId) else {
                    throw WorkspaceError.revisionDataNotFound($0.snapshotId)
                }
                return manifest
            }
            try requireCurrentFormatUnlocked(workspaceId: workspaceId)
            let batch = try makeBlobBatch(workspaceId: workspaceId)
            defer { batch.close() }
            func apply(_ patch: Snapshot.Entry, to old: SnapshotManifest.Node?) throws -> SnapshotManifest.Node {
                if case let .directory(directory) = patch {
                    let previous: [SnapshotManifest.Node]
                    if let old { previous = try children(of: old, workspaceId: workspaceId) }
                    else { previous = [] }
                    let byPath = Dictionary(uniqueKeysWithValues: previous.map { ($0.path, $0) })
                    var entries = preservingDirectories.contains(directory.path) ? byPath : [:]
                    for child in directory.children {
                        if case .missing = child { entries.removeValue(forKey: child.path) }
                        else { entries[child.path] = try apply(child, to: byPath[child.path]) }
                    }
                    let updated = entries.values.sorted { $0.path < $1.path }
                    var node = SnapshotManifest.Node(kind: .directory, path: directory.path,
                        permissions: directory.permissions,
                        modificationDate: metadata.entries[directory.path]?.info.modificationDate,
                        identity: metadata.entries[directory.path]?.info.identity)
                    if let old, old.kind == .directory, old.treeHash != nil, updated == previous {
                        node.treeHash = old.treeHash
                        return node
                    }
                    node.children = updated
                    return try persistDirectory(node, workspaceId: workspaceId)
                }
                var node = try writeManifestNode(patch, workspaceId: workspaceId, batch: batch, reusing: old)
                node.modificationDate = metadata.entries[patch.path]?.info.modificationDate
                node.identity = metadata.entries[patch.path]?.info.identity
                return node
            }
            let root = try apply(patch.entry, to: source.root)
            try finish(batch, workspaceId: workspaceId)
            let manifest = SnapshotManifest(version: 3, id: UUID(), rootPath: source.rootPath,
                root: root, captureStartedAt: metadata.capturedAt,
                exactContentTimestamps: metadata.exactTimestamps)
            let summary: ChangeSet.Summary
            if let parentManifest {
                summary = try await compareNodes(parentManifest.root, root, workspaceId: workspaceId).summary
            } else {
                summary = try await compareNodes(.init(kind: .missing, path: source.rootPath), root, workspaceId: workspaceId).summary
            }
            let checkpoint = Checkpoint.make(snapshotID: manifest.id, draft: draft, mutationCursor: cursor,
                                             parent: parent, summary: summary)
            try Task.checkCancellation()
            // All immutable objects are durable before the manifest, then the checkpoint
            // is published through the same full-sync/fallback path as captureRevision.
            try write(manifest, to: snapshotURL(id: manifest.id, workspaceId: workspaceId), durability: .publication)
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: workspaceId), durability: .publication)
            listCheckpointsCache[workspaceId] = nil
            return checkpoint
        }
    }
}

extension Snapshot {
    static func patching(_ old: Entry, with patch: Entry, preserving directories: Set<WorkspacePath>) -> Entry {
        guard case let .directory(new) = patch, directories.contains(new.path),
              case let .directory(previous) = old else { return patch }
        var children = Dictionary(uniqueKeysWithValues: previous.children.map { ($0.path, $0) })
        for child in new.children {
            if case .missing = child { children.removeValue(forKey: child.path) }
            else { children[child.path] = patching(children[child.path] ?? .missing(.init(path: child.path)),
                                                 with: child, preserving: directories) }
        }
        return .directory(.init(path: new.path, permissions: new.permissions,
                                children: children.values.sorted { $0.path < $1.path }))
    }
}
