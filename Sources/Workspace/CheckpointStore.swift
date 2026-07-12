import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persistence for workspace checkpoints, snapshots, and mutation logs.
///
/// The store is the **source of truth** for `Mutation.sequence` values. Callers may pass
/// any placeholder sequence; ``appendMutation(_:)`` returns the record with the next persisted
/// monotonic number for that workspace, serialized under the mutations lock.
protocol CheckpointStore: AnyObject, Sendable {
    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint
    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint
    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint?
    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint]
    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot?
    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex?
    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data?
    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation
    func listMutations(workspaceId: UUID) async throws -> [Mutation]
    /// Removes mutation records with `sequence <= throughSequence`. The record carrying the
    /// highest sequence is always retained so later appends stay monotonic.
    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws
    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics
    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult
}

/// An in-memory checkpoint store for tests and ephemeral workspaces.
actor InMemoryCheckpointStore: CheckpointStore {
    private var checkpointsByWorkspace: [UUID: [Checkpoint]] = [:]
    private var snapshotsByWorkspace: [UUID: [UUID: Snapshot]] = [:]
    private var mutationsByWorkspace: [UUID: [Mutation]] = [:]

    init() {}

    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint {
        try await saveRevision(Snapshot.capture(from: filesystem), draft: draft)
    }

    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint {
        var list = checkpointsByWorkspace[draft.workspaceID] ?? []
        let parent = resolvedParent(for: draft, checkpoints: list)
        let parentSnapshot = parent.flatMap { snapshotsByWorkspace[draft.workspaceID]?[$0.snapshotId] }
        if let parent, parentSnapshot == nil {
            throw WorkspaceError.storageCorrupted("checkpoint \(parent.id) has no snapshot")
        }
        let checkpoint = Checkpoint.make(
            snapshot: snapshot,
            draft: draft,
            parent: parent,
            parentSnapshot: parentSnapshot
        )
        snapshotsByWorkspace[draft.workspaceID, default: [:]][snapshot.id] = snapshot
        list.append(checkpoint)
        checkpointsByWorkspace[draft.workspaceID] = list.sorted(by: Checkpoint.orderedBefore)
        return checkpoint
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        checkpointsByWorkspace[workspaceId]?.first { $0.id == id }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        (checkpointsByWorkspace[workspaceId] ?? []).sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        snapshotsByWorkspace[workspaceId]?[id]
    }

    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex? {
        snapshotsByWorkspace[workspaceId]?[id].map(RevisionIndex.init)
    }

    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data? {
        guard let snapshot = snapshotsByWorkspace[workspaceId]?[id],
              let entry = Workspace.snapshotEntry(at: path, in: snapshot.entry),
              case let .file(file) = entry
        else { return nil }
        guard offset < UInt64(file.data.count) else { return Data() }
        let start = file.data.index(file.data.startIndex, offsetBy: Int(offset))
        let end = length.map { file.data.index(start, offsetBy: $0, limitedBy: file.data.endIndex) ?? file.data.endIndex }
            ?? file.data.endIndex
        return Data(file.data[start..<end])
    }

    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation {
        var list = mutationsByWorkspace[mutation.workspaceID, default: []]
        let next = (list.map(\.sequence).max() ?? 0) + 1
        var record = mutation
        record.sequence = next
        list.append(record)
        mutationsByWorkspace[mutation.workspaceID] = list
        return record
    }

    func listMutations(workspaceId: UUID) async throws -> [Mutation] {
        (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
    }

    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws {
        let records = (mutationsByWorkspace[workspaceId] ?? []).sorted { $0.sequence < $1.sequence }
        guard let last = records.last else {
            return
        }
        var kept = records.filter { $0.sequence > throughSequence }
        if kept.isEmpty {
            kept = [last]
        }
        mutationsByWorkspace[workspaceId] = kept
    }

    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics {
        statistics(
            checkpoints: checkpointsByWorkspace[workspaceId] ?? [],
            snapshots: snapshotsByWorkspace[workspaceId] ?? [:]
        )
    }

    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult {
        let currentCheckpoints = checkpointsByWorkspace[workspaceId] ?? []
        let currentSnapshots = snapshotsByWorkspace[workspaceId] ?? [:]
        let before = statistics(checkpoints: currentCheckpoints, snapshots: currentSnapshots)
        let plan = try CheckpointRetentionPlanner.plan(checkpoints: currentCheckpoints, retaining: retention)
        let retained = try CheckpointRetentionPlanner.materialize(plan) { snapshotID in
            currentSnapshots[snapshotID]
        }

        let retainedSnapshotIDs = Set(retained.map(\.snapshotId))
        let retainedSnapshots = currentSnapshots.filter { retainedSnapshotIDs.contains($0.key) }
        let after = statistics(checkpoints: retained, snapshots: retainedSnapshots)
        let report = Workspace.CompactionReport(
            dryRun: dryRun,
            before: before,
            after: after,
            removedCheckpointIDs: plan.removedCheckpointIDs,
            rebasedCheckpointIDs: plan.rebasedCheckpointIDs
        )

        if !dryRun {
            checkpointsByWorkspace[workspaceId] = retained
            snapshotsByWorkspace[workspaceId] = retainedSnapshots
        }
        return StoreCompactionResult(report: report, checkpoints: retained)
    }

    private func resolvedParent(for draft: CheckpointDraft, checkpoints: [Checkpoint]) -> Checkpoint? {
        if let preferred = draft.preferredParentID,
           let parent = checkpoints.first(where: { $0.id == preferred }) {
            return parent
        }
        guard draft.preferredParentID != nil,
              let headID = Checkpoint.lineageHeadID(in: checkpoints)
        else { return nil }
        return checkpoints.first(where: { $0.id == headID })
    }

    private func statistics(
        checkpoints: [Checkpoint],
        snapshots: [UUID: Snapshot]
    ) -> Workspace.StorageStatistics {
        var blobs: [String: UInt64] = [:]
        for snapshot in snapshots.values {
            collectBlobStatistics(snapshot.entry, into: &blobs)
        }
        return Workspace.StorageStatistics(
            checkpointCount: checkpoints.count,
            snapshotCount: snapshots.count,
            blobCount: blobs.count,
            blobBytes: blobs.values.reduce(0, +)
        )
    }

    private func collectBlobStatistics(_ entry: Snapshot.Entry, into blobs: inout [String: UInt64]) {
        switch entry {
        case let .file(file):
            blobs[SHA256.hexDigest(of: file.data)] = UInt64(file.data.count)
        case let .directory(directory):
            for child in directory.children { collectBlobStatistics(child, into: &blobs) }
        case .missing, .symlink:
            break
        }
    }
}

/// A JSON file-backed checkpoint store.
///
/// Mutations are stored as one JSON line per record in `mutations.jsonl` (append-friendly under
/// the lock). Appends derive the next sequence from the log's final record instead of re-reading
/// the whole log, so appends stay cheap as histories grow. A partial trailing line left by a
/// crashed append is skipped when reading and truncated before the next append. Writes are
/// synchronized through a persistent sidecar lockfile (`mutations.lock`) with an advisory
/// exclusive lock when the platform supports it (`flock`), so concurrent ``FileCheckpointStore``
/// instances in the same process and across cooperating processes do not lose appends. A separate
/// lifecycle lock serializes checkpoint commits, revision reads, and compaction; rebased metadata
/// is written before unreachable artifacts are removed, keeping interrupted compaction recoverable.
/// Coordinating writers on network filesystems that do not honor `flock` may still require
/// application-level serialization.
actor FileCheckpointStore: CheckpointStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let compactEncoder: JSONEncoder

    private var listCheckpointsCache: [UUID: (cacheKey: String, checkpoints: [Checkpoint])] = [:]

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.compactEncoder = JSONEncoder()
    }

    func saveRevision(_ snapshot: Snapshot, draft: CheckpointDraft) async throws -> Checkpoint {
        try ensureWorkspaceDirectories(for: draft.workspaceID)
        return try Self.withExclusiveLock(at: lifecycleLockURL(workspaceId: draft.workspaceID)) {
            let checkpoints = try loadAllCheckpointsUnlocked(workspaceId: draft.workspaceID)
            let parent = resolvedParent(for: draft, checkpoints: checkpoints)
            let parentSnapshot = try parent.map {
                guard let snapshot = try loadSnapshotUnlocked(id: $0.snapshotId, workspaceId: draft.workspaceID) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \($0.id) has no snapshot")
                }
                return snapshot
            }
            let checkpoint = Checkpoint.make(
                snapshot: snapshot,
                draft: draft,
                parent: parent,
                parentSnapshot: parentSnapshot
            )
            try writeSnapshotUnlocked(snapshot, workspaceId: draft.workspaceID)
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID))
            listCheckpointsCache[draft.workspaceID] = nil
            return checkpoint
        }
    }

    func loadCheckpoint(id: UUID, workspaceId: UUID) async throws -> Checkpoint? {
        try validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            let url = checkpointURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let checkpoint = try read(Checkpoint.self, from: url)
            guard checkpoint.id == id, checkpoint.workspaceID == workspaceId else {
                throw WorkspaceError.storageCorrupted("checkpoint metadata does not match its storage path")
            }
            return checkpoint
        }
    }

    func listCheckpoints(workspaceId: UUID) async throws -> [Checkpoint] {
        try validateWorkspaceFormatIfPresent(workspaceId)
        let directoryURL = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            listCheckpointsCache[workspaceId] = nil
            return []
        }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            if let key = try checkpointsDirectoryCacheKey(at: directoryURL),
               let entry = listCheckpointsCache[workspaceId], entry.cacheKey == key {
                return entry.checkpoints
            }

            let result = try loadAllCheckpointsUnlocked(workspaceId: workspaceId)
            if let key = try checkpointsDirectoryCacheKey(at: directoryURL) {
                listCheckpointsCache[workspaceId] = (key, result)
            }
            return result
        }
    }

    /// A persisted snapshot: the tree structure with file contents replaced by content hashes.
    /// The bytes themselves live in per-workspace `blobs/<sha256>` files, so identical content is
    /// stored once no matter how many snapshots reference it, and never base64-inflated.
    private struct SnapshotManifest: Codable, Sendable {
        struct Node: Codable, Sendable {
            enum Kind: String, Codable {
                case file, directory, symlink, missing
            }

            var kind: Kind
            var path: WorkspacePath
            var permissions: POSIXPermissions?
            var contentHash: String?
            var contentSize: UInt64? = nil
            var modificationDate: Date? = nil
            var symlinkTarget: String?
            var children: [Node]?
        }

        var version: Int
        var id: UUID
        var rootPath: WorkspacePath
        var root: Node
    }

    func captureRevision(from filesystem: any FileSystem, draft: CheckpointDraft) async throws -> Checkpoint {
        try ensureWorkspaceDirectories(for: draft.workspaceID)
        return try await withExclusiveLifecycleLock(at: lifecycleLockURL(workspaceId: draft.workspaceID)) {
            let checkpoints = try self.loadAllCheckpointsUnlocked(workspaceId: draft.workspaceID)
            let parent = self.resolvedParent(for: draft, checkpoints: checkpoints)
            let parentManifest: SnapshotManifest?
            if let parent {
                guard let manifest = try self.loadManifestUnlocked(
                    id: parent.snapshotId,
                    workspaceId: draft.workspaceID
                ) else {
                    throw WorkspaceError.storageCorrupted("checkpoint \(parent.id) has no snapshot")
                }
                parentManifest = manifest
            } else {
                parentManifest = nil
            }
            let snapshotID = UUID()
            let root = try await self.captureManifestNode(
                from: filesystem,
                at: .root,
                reusing: parentManifest?.root,
                workspaceId: draft.workspaceID
            )
            let manifest = SnapshotManifest(version: 2, id: snapshotID, rootPath: .root, root: root)
            let beforeIndex = try parentManifest.map {
                RevisionIndex(
                    id: $0.id,
                    root: $0.rootPath,
                    entry: try self.revisionEntry(from: $0.root, workspaceId: draft.workspaceID)
                )
            } ?? RevisionIndex(
                id: UUID(),
                root: .root,
                entry: .missing(path: .root)
            )
            let afterIndex = RevisionIndex(
                id: snapshotID,
                root: .root,
                entry: try self.revisionEntry(from: root, workspaceId: draft.workspaceID)
            )
            let blobsRoot = self.blobsDirectoryURL(workspaceId: draft.workspaceID)
            let beforeRoot = parentManifest?.root
            let changes = try await ChangeSet.compare(
                before: beforeIndex,
                after: afterIndex,
                maxTextBytes: 1_000_000,
                loadBefore: { path in try Self.loadManifestFile(path, root: beforeRoot, blobsRoot: blobsRoot) },
                loadAfter: { path in try Self.loadManifestFile(path, root: root, blobsRoot: blobsRoot) }
            )
            let checkpoint = Checkpoint.make(
                snapshotID: snapshotID,
                draft: draft,
                parent: parent,
                summary: changes.summary
            )
            try self.write(manifest, to: self.snapshotURL(id: snapshotID, workspaceId: draft.workspaceID))
            try self.write(
                checkpoint,
                to: self.checkpointURL(id: checkpoint.id, workspaceId: draft.workspaceID)
            )
            self.listCheckpointsCache[draft.workspaceID] = nil
            return checkpoint
        }
    }

    private func writeSnapshotUnlocked(_ snapshot: Snapshot, workspaceId: UUID) throws {
        let root = try writeManifestNode(snapshot.entry, workspaceId: workspaceId)
        let manifest = SnapshotManifest(
            version: 2,
            id: snapshot.id,
            rootPath: snapshot.rootPath,
            root: root
        )
        try write(manifest, to: snapshotURL(id: snapshot.id, workspaceId: workspaceId))
    }

    private func loadManifestUnlocked(id: UUID, workspaceId: UUID) throws -> SnapshotManifest? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        guard manifest.id == id else {
            throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
        }
        return manifest
    }

    private func captureManifestNode(
        from filesystem: any FileSystem,
        at path: WorkspacePath,
        reusing previous: SnapshotManifest.Node?,
        workspaceId: UUID
    ) async throws -> SnapshotManifest.Node {
        guard await filesystem.exists(path: path) else {
            return SnapshotManifest.Node(kind: .missing, path: path)
        }
        let info = try await filesystem.stat(path: path)
        switch info.kind {
        case .file:
            if previous?.kind == .file,
               previous?.contentSize == info.size,
               previous?.modificationDate != nil,
               previous?.modificationDate == info.modificationDate,
               let hash = previous?.contentHash,
               Self.isValidContentHash(hash),
               fileManager.fileExists(atPath: blobURL(hash: hash, workspaceId: workspaceId).path) {
                return SnapshotManifest.Node(
                    kind: .file,
                    path: path,
                    permissions: info.permissions,
                    contentHash: hash,
                    contentSize: info.size,
                    modificationDate: info.modificationDate
                )
            }
            let data = try await filesystem.readFile(path: path)
            let hash = SHA256.hexDigest(of: data)
            let blob = blobURL(hash: hash, workspaceId: workspaceId)
            if !fileManager.fileExists(atPath: blob.path) { try data.write(to: blob, options: .atomic) }
            return SnapshotManifest.Node(
                kind: .file,
                path: path,
                permissions: info.permissions,
                contentHash: hash,
                contentSize: UInt64(data.count),
                modificationDate: info.modificationDate
            )
        case .directory:
            var previousChildren: [String: SnapshotManifest.Node] = [:]
            for child in previous?.kind == .directory ? previous?.children ?? [] : [] {
                guard previousChildren.updateValue(child, forKey: child.path.name) == nil else {
                    throw WorkspaceError.storageCorrupted(
                        "snapshot directory \(path) contains duplicate child \(child.path.name)"
                    )
                }
            }
            var children: [SnapshotManifest.Node] = []
            for entry in try await filesystem.listDirectory(path: path).sorted(by: { $0.name < $1.name }) {
                children.append(
                    try await captureManifestNode(
                        from: filesystem,
                        at: path.appending(entry.name),
                        reusing: previousChildren[entry.name],
                        workspaceId: workspaceId
                    )
                )
            }
            return SnapshotManifest.Node(
                kind: .directory,
                path: path,
                permissions: info.permissions,
                modificationDate: info.modificationDate,
                children: children
            )
        case .symlink:
            return SnapshotManifest.Node(
                kind: .symlink,
                path: path,
                permissions: info.permissions,
                modificationDate: info.modificationDate,
                symlinkTarget: try await filesystem.readSymlink(path: path)
            )
        }
    }

    private static func loadManifestFile(
        _ path: WorkspacePath,
        root: SnapshotManifest.Node?,
        blobsRoot: URL
    ) throws -> Data {
        guard let root, let node = manifestNodeStatic(at: path, in: root), node.kind == .file,
              let hash = node.contentHash, isValidContentHash(hash)
        else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        let url = blobsRoot.appendingPathComponent(hash, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(path)")
        }
        return try Data(contentsOf: url)
    }

    private static func manifestNodeStatic(
        at path: WorkspacePath,
        in node: SnapshotManifest.Node
    ) -> SnapshotManifest.Node? {
        if node.path == path { return node }
        for child in node.children ?? [] where child.path == path || path.string.hasPrefix(child.path.string + "/") {
            return manifestNodeStatic(at: path, in: child)
        }
        return nil
    }

    func loadSnapshot(id: UUID, workspaceId: UUID) async throws -> Snapshot? {
        try validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try loadSnapshotUnlocked(id: id, workspaceId: workspaceId)
        }
    }

    func loadRevisionIndex(id: UUID, workspaceId: UUID) async throws -> RevisionIndex? {
        try validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            let url = snapshotURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
            guard manifest.id == id else {
                throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
            }
            return RevisionIndex(
                id: manifest.id,
                root: manifest.rootPath,
                entry: try revisionEntry(from: manifest.root, workspaceId: workspaceId)
            )
        }
    }

    func readSnapshotFile(
        id: UUID,
        workspaceId: UUID,
        path: WorkspacePath,
        offset: UInt64,
        length: Int?
    ) async throws -> Data? {
        try validateWorkspaceFormatIfPresent(workspaceId)
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else { return nil }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            let url = snapshotURL(id: id, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
            guard manifest.id == id else {
                throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
            }
            guard let node = manifestNode(at: path, in: manifest.root), node.kind == .file else { return nil }
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            let blob = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: blob.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(path)")
            }
            let handle = try FileHandle(forReadingFrom: blob)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard offset < size else { return Data() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length ?? Int(size - offset)) ?? Data()
        }
    }

    private func revisionEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID
    ) throws -> RevisionIndex.Entry {
        switch node.kind {
        case .missing:
            return .missing(path: node.path)
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            return .file(
                path: node.path,
                size: node.contentSize ?? 0,
                permissions: node.permissions ?? .defaultFile,
                contentID: hash
            )
        case .directory:
            return .directory(
                path: node.path,
                permissions: node.permissions ?? .defaultDirectory,
                children: try (node.children ?? []).map { try revisionEntry(from: $0, workspaceId: workspaceId) }
            )
        case .symlink:
            return .symbolicLink(
                path: node.path,
                target: node.symlinkTarget ?? "",
                permissions: node.permissions ?? POSIXPermissions(0o777)
            )
        }
    }

    private func manifestNode(at path: WorkspacePath, in node: SnapshotManifest.Node) -> SnapshotManifest.Node? {
        if node.path == path { return node }
        for child in node.children ?? [] where child.path == path || path.string.hasPrefix(child.path.string + "/") {
            return manifestNode(at: path, in: child)
        }
        return nil
    }

    private func writeManifestNode(
        _ entry: Snapshot.Entry,
        workspaceId: UUID
    ) throws -> SnapshotManifest.Node {
        switch entry {
        case let .missing(missing):
            return SnapshotManifest.Node(kind: .missing, path: missing.path)
        case let .file(file):
            let hash = SHA256.hexDigest(of: file.data)
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            if !fileManager.fileExists(atPath: url.path) {
                try file.data.write(to: url, options: .atomic)
            }
            return SnapshotManifest.Node(
                kind: .file,
                path: file.path,
                permissions: file.permissions,
                contentHash: hash,
                contentSize: UInt64(file.data.count)
            )
        case let .symlink(symlink):
            return SnapshotManifest.Node(
                kind: .symlink,
                path: symlink.path,
                permissions: symlink.permissions,
                symlinkTarget: symlink.target
            )
        case let .directory(directory):
            return SnapshotManifest.Node(
                kind: .directory,
                path: directory.path,
                permissions: directory.permissions,
                children: try directory.children.map {
                    try writeManifestNode($0, workspaceId: workspaceId)
                }
            )
        }
    }

    private func snapshotEntry(
        from node: SnapshotManifest.Node,
        workspaceId: UUID
    ) throws -> Snapshot.Entry {
        switch node.kind {
        case .missing:
            return .missing(Snapshot.Missing(path: node.path))
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash) for \(node.path)")
            }
            return .file(
                Snapshot.File(
                    path: node.path,
                    data: try Data(contentsOf: url),
                    permissions: node.permissions ?? POSIXPermissions(0o644)
                )
            )
        case .symlink:
            return .symlink(
                Snapshot.Symlink(
                    path: node.path,
                    target: node.symlinkTarget ?? "",
                    permissions: node.permissions ?? POSIXPermissions(0o777)
                )
            )
        case .directory:
            return .directory(
                Snapshot.Directory(
                    path: node.path,
                    permissions: node.permissions ?? POSIXPermissions(0o755),
                    children: try (node.children ?? []).map {
                        try snapshotEntry(from: $0, workspaceId: workspaceId)
                    }
                )
            )
        }
    }

    @discardableResult
    func appendMutation(_ mutation: Mutation) async throws -> Mutation {
        try ensureWorkspaceDirectories(for: mutation.workspaceID)
        let jsonl = mutationsJsonlURL(workspaceId: mutation.workspaceID)
        let lockURL = mutationsLockURL(workspaceId: mutation.workspaceID)
        return try Self.withExclusiveLock(at: lockURL) {
            let lastSequence: Int
            if fileManager.fileExists(atPath: jsonl.path) {
                try repairTornTail(at: jsonl)
                lastSequence = try lastPersistedSequence(at: jsonl)
            } else {
                lastSequence = 0
            }
            var record = mutation
            record.sequence = lastSequence + 1

            if fileManager.fileExists(atPath: jsonl.path) {
                try appendJSONLLine(encode: record, to: jsonl)
            } else {
                try writeAllMutationsAsJSONL([record], to: jsonl)
            }
            return record
        }
    }

    func listMutations(workspaceId: UUID) async throws -> [Mutation] {
        try validateWorkspaceFormatIfPresent(workspaceId)
        let jsonl = mutationsJsonlURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: jsonl.path) else {
            return []
        }
        let lockURL = mutationsLockURL(workspaceId: workspaceId)
        return try Self.withExclusiveLock(at: lockURL) {
            try loadMutationsFromJSONL(at: jsonl)
                .sorted { $0.sequence < $1.sequence }
        }
    }

    func pruneMutations(workspaceId: UUID, throughSequence: Int) async throws {
        try validateWorkspaceFormatIfPresent(workspaceId)
        let jsonl = mutationsJsonlURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: jsonl.path) else {
            return
        }
        let lockURL = mutationsLockURL(workspaceId: workspaceId)
        try Self.withExclusiveLock(at: lockURL) {
            let records = try loadMutationsFromJSONL(at: jsonl)
                .sorted { $0.sequence < $1.sequence }
            guard let last = records.last else {
                return
            }
            var kept = records.filter { $0.sequence > throughSequence }
            if kept.isEmpty {
                kept = [last]
            }
            guard kept.count != records.count else {
                return
            }
            try writeAllMutationsAsJSONL(kept, to: jsonl)
        }
    }

    func storageStatistics(workspaceId: UUID) async throws -> Workspace.StorageStatistics {
        try validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            return .empty
        }
        return try Self.withSharedLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try physicalStatisticsUnlocked(workspaceId: workspaceId)
        }
    }

    func compact(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) async throws -> StoreCompactionResult {
        try validateWorkspaceFormatIfPresent(workspaceId)
        guard fileManager.fileExists(atPath: workspaceDirectoryURL(workspaceId: workspaceId).path) else {
            let plan = try CheckpointRetentionPlanner.plan(checkpoints: [], retaining: retention)
            return StoreCompactionResult(
                report: Workspace.CompactionReport(
                    dryRun: dryRun,
                    before: .empty,
                    after: .empty,
                    removedCheckpointIDs: plan.removedCheckpointIDs,
                    rebasedCheckpointIDs: plan.rebasedCheckpointIDs
                ),
                checkpoints: []
            )
        }
        return try Self.withExclusiveLock(at: lifecycleLockURL(workspaceId: workspaceId)) {
            try compactUnlocked(workspaceId: workspaceId, retaining: retention, dryRun: dryRun)
        }
    }

    private func compactUnlocked(
        workspaceId: UUID,
        retaining retention: Workspace.Retention,
        dryRun: Bool
    ) throws -> StoreCompactionResult {
        let current = try loadAllCheckpointsUnlocked(workspaceId: workspaceId)
        let before = try physicalStatisticsUnlocked(workspaceId: workspaceId)
        let plan = try CheckpointRetentionPlanner.plan(checkpoints: current, retaining: retention)
        let rebasedIDs = Set(plan.rebasedCheckpointIDs)
        let retained = try CheckpointRetentionPlanner.materialize(plan) { snapshotID in
            try loadSnapshotUnlocked(id: snapshotID, workspaceId: workspaceId)
        }

        let retainedSnapshotIDs = Set(retained.map(\.snapshotId))
        var retainedBlobHashes: Set<String> = []
        for checkpoint in retained {
            let manifestURL = snapshotURL(id: checkpoint.snapshotId, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) has no snapshot")
            }
            let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.id == checkpoint.snapshotId else {
                throw WorkspaceError.storageCorrupted("checkpoint \(checkpoint.id) references a mismatched snapshot")
            }
            try collectContentHashes(from: manifest.root, into: &retainedBlobHashes)
        }

        var retainedBlobBytes: UInt64 = 0
        for hash in retainedBlobHashes {
            let url = blobURL(hash: hash, workspaceId: workspaceId)
            guard fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceError.storageCorrupted("missing content blob \(hash)")
            }
            retainedBlobBytes += try fileSize(at: url)
        }
        let after = Workspace.StorageStatistics(
            checkpointCount: retained.count,
            snapshotCount: retainedSnapshotIDs.count,
            blobCount: retainedBlobHashes.count,
            blobBytes: retainedBlobBytes
        )
        let report = Workspace.CompactionReport(
            dryRun: dryRun,
            before: before,
            after: after,
            removedCheckpointIDs: plan.removedCheckpointIDs,
            rebasedCheckpointIDs: plan.rebasedCheckpointIDs
        )

        guard !dryRun else { return StoreCompactionResult(report: report, checkpoints: retained) }

        for checkpoint in retained where rebasedIDs.contains(checkpoint.id) {
            try write(checkpoint, to: checkpointURL(id: checkpoint.id, workspaceId: workspaceId))
        }
        for id in plan.removedCheckpointIDs {
            try removeIfPresent(checkpointURL(id: id, workspaceId: workspaceId))
        }
        for url in try artifactURLs(in: snapshotsDirectoryURL(workspaceId: workspaceId), pathExtension: "json") {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  retainedSnapshotIDs.contains(id)
            else {
                try fileManager.removeItem(at: url)
                continue
            }
        }
        for url in try blobURLs(workspaceId: workspaceId)
        where !retainedBlobHashes.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
        listCheckpointsCache[workspaceId] = nil
        return StoreCompactionResult(report: report, checkpoints: retained)
    }

    private func loadAllCheckpointsUnlocked(workspaceId: UUID) throws -> [Checkpoint] {
        let directory = checkpointsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try artifactURLs(in: directory, pathExtension: "json").map { url in
            let checkpoint = try read(Checkpoint.self, from: url)
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == checkpoint.id,
                  checkpoint.workspaceID == workspaceId
            else {
                throw WorkspaceError.storageCorrupted("checkpoint metadata does not match its storage path")
            }
            return checkpoint
        }.sorted(by: Checkpoint.orderedBefore)
    }

    private func loadSnapshotUnlocked(id: UUID, workspaceId: UUID) throws -> Snapshot? {
        let url = snapshotURL(id: id, workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: url))
        guard manifest.id == id else {
            throw WorkspaceError.storageCorrupted("snapshot manifest id does not match \(id)")
        }
        return Snapshot(
            id: manifest.id,
            rootPath: manifest.rootPath,
            entry: try snapshotEntry(from: manifest.root, workspaceId: workspaceId)
        )
    }

    private func resolvedParent(for draft: CheckpointDraft, checkpoints: [Checkpoint]) -> Checkpoint? {
        if let preferred = draft.preferredParentID,
           let parent = checkpoints.first(where: { $0.id == preferred }) {
            return parent
        }
        guard draft.preferredParentID != nil,
              let headID = Checkpoint.lineageHeadID(in: checkpoints)
        else { return nil }
        return checkpoints.first(where: { $0.id == headID })
    }

    private func physicalStatisticsUnlocked(workspaceId: UUID) throws -> Workspace.StorageStatistics {
        let checkpoints = try artifactURLs(
            in: checkpointsDirectoryURL(workspaceId: workspaceId),
            pathExtension: "json"
        )
        let snapshots = try artifactURLs(
            in: snapshotsDirectoryURL(workspaceId: workspaceId),
            pathExtension: "json"
        )
        let blobs = try blobURLs(workspaceId: workspaceId)
        var blobBytes: UInt64 = 0
        for blob in blobs { blobBytes += try fileSize(at: blob) }
        return Workspace.StorageStatistics(
            checkpointCount: checkpoints.count,
            snapshotCount: snapshots.count,
            blobCount: blobs.count,
            blobBytes: blobBytes
        )
    }

    private func artifactURLs(in directory: URL, pathExtension: String) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == pathExtension }.map { url in
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw WorkspaceError.storageCorrupted("unexpected artifact: \(url.lastPathComponent)")
            }
            return url
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func blobURLs(workspaceId: UUID) throws -> [URL] {
        let directory = blobsDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map { url in
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw WorkspaceError.storageCorrupted("unexpected entry in blob store: \(url.lastPathComponent)")
            }
            return url
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let value = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return value?.uint64Value ?? 0
    }

    private func collectContentHashes(from node: SnapshotManifest.Node, into hashes: inout Set<String>) throws {
        switch node.kind {
        case .file:
            guard let hash = node.contentHash, Self.isValidContentHash(hash) else {
                throw WorkspaceError.storageCorrupted("snapshot file node \(node.path) has an invalid content hash")
            }
            hashes.insert(hash)
        case .directory:
            for child in node.children ?? [] { try collectContentHashes(from: child, into: &hashes) }
        case .missing, .symlink:
            break
        }
    }

    private static func isValidContentHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func loadMutationsFromJSONL(at url: URL) throws -> [Mutation] {
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        let endsWithNewline = data.last == UInt8(ascii: "\n")
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
        var out: [Mutation] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            do {
                out.append(try decoder.decode(Mutation.self, from: Data(String(line).utf8)))
            } catch {
                // A crashed append leaves a strict prefix of `<json>\n`: an undecodable final
                // line with no trailing newline. Tolerate exactly that torn tail; anything else
                // is real corruption and must surface.
                if index == lines.count - 1, !endsWithNewline {
                    continue
                }
                throw error
            }
        }
        return out
    }

    /// Truncates a partial trailing line left behind by a crashed append so subsequent appends
    /// do not glue new records onto the torn fragment. A torn append never contains a newline
    /// (it is a strict prefix of `<json>\n`), so everything after the final newline — or the
    /// whole file when none exists — is the torn region. Must be called under the mutations lock.
    private func repairTornTail(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        let lastByte = try handle.read(upToCount: 1)
        guard lastByte != Data("\n".utf8) else { return }
        let newlineOffset = try Self.lastNewlineOffset(in: handle, before: size - 1)
        try handle.truncate(atOffset: newlineOffset.map { $0 + 1 } ?? 0)
    }

    /// Returns the sequence of the final record without loading the whole log. Appends are
    /// strictly monotonic and full rewrites are sorted by sequence, so the last line always
    /// carries the maximum. Falls back to a full scan for unusual tails such as blank trailing
    /// lines. Must be called under the mutations lock, after ``repairTornTail(at:)``.
    private func lastPersistedSequence(at url: URL) throws -> Int {
        if let line = try lastLine(at: url),
           let record = try? decoder.decode(Mutation.self, from: line) {
            return record.sequence
        }
        return try loadMutationsFromJSONL(at: url).map(\.sequence).max() ?? 0
    }

    private func lastLine(at url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 1 else { return nil }
        // The file ends with `\n` after tail repair; the last line spans the byte after the
        // previous newline through the byte before the trailing newline.
        let lineEnd = size - 1
        let newlineOffset = try Self.lastNewlineOffset(in: handle, before: lineEnd)
        let lineStart = newlineOffset.map { $0 + 1 } ?? 0
        guard lineEnd > lineStart else { return nil }
        try handle.seek(toOffset: lineStart)
        let line = try handle.read(upToCount: Int(lineEnd - lineStart)) ?? Data()
        return line.isEmpty ? nil : line
    }

    /// Scans backwards in chunks for the offset of the last `\n` strictly before `end`.
    private static func lastNewlineOffset(in handle: FileHandle, before end: UInt64) throws -> UInt64? {
        let chunkSize: UInt64 = 65536
        var cursor = end
        while cursor > 0 {
            let chunkStart = cursor > chunkSize ? cursor - chunkSize : 0
            try handle.seek(toOffset: chunkStart)
            let chunk = try handle.read(upToCount: Int(cursor - chunkStart)) ?? Data()
            if let index = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                return chunkStart + UInt64(chunk.distance(from: chunk.startIndex, to: index))
            }
            cursor = chunkStart
        }
        return nil
    }

    private func writeAllMutationsAsJSONL(_ records: [Mutation], to url: URL) throws {
        if records.isEmpty {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        var data = Data()
        for record in records.sorted(by: { $0.sequence < $1.sequence }) {
            var line = try compactEncoder.encode(record)
            line.append(Data("\n".utf8))
            data.append(line)
        }
        try data.write(to: url, options: .atomic)
    }

    private func appendJSONLLine(encode record: Mutation, to url: URL) throws {
        var line = try compactEncoder.encode(record)
        line.append(Data("\n".utf8))
        if fileManager.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    private func checkpointsDirectoryCacheKey(at url: URL) throws -> String? {
        let files = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let count = files.filter { $0.pathExtension == "json" }.count
        let mtime = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return "\(mtime?.timeIntervalSince1970 ?? 0)-\(count)"
    }

    private func ensureWorkspaceDirectories(for workspaceId: UUID) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Self.withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            try ensureWorkspaceDirectoriesLocked(for: workspaceId)
        }
    }

    private func ensureWorkspaceDirectoriesLocked(for workspaceId: UUID) throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let existed = fileManager.fileExists(atPath: workspaceURL.path)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        if fileManager.fileExists(atPath: formatURL.path) {
            try validateWorkspaceFormatLocked(workspaceId)
        } else {
            if existed,
               !(try fileManager.contentsOfDirectory(at: workspaceURL, includingPropertiesForKeys: nil)).isEmpty
            {
                throw WorkspaceError.storageCorrupted("workspace store has no format version")
            }
            try encoder.encode(StoreFormat(version: StoreFormat.currentVersion)).write(to: formatURL, options: .atomic)
        }
        try fileManager.createDirectory(at: checkpointsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsDirectoryURL(workspaceId: workspaceId), withIntermediateDirectories: true)
    }

    private func validateWorkspaceFormatIfPresent(_ workspaceId: UUID) throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        guard fileManager.fileExists(atPath: workspaceURL.path) else { return }
        try Self.withExclusiveLock(at: formatLockURL(workspaceId: workspaceId)) {
            try validateWorkspaceFormatLocked(workspaceId)
        }
    }

    private func validateWorkspaceFormatLocked(_ workspaceId: UUID) throws {
        let workspaceURL = workspaceDirectoryURL(workspaceId: workspaceId)
        let formatURL = workspaceURL.appendingPathComponent("format.json")
        guard fileManager.fileExists(atPath: formatURL.path) else {
            throw WorkspaceError.storageCorrupted("workspace store has no format version")
        }
        let format = try decoder.decode(StoreFormat.self, from: Data(contentsOf: formatURL))
        guard format.version == StoreFormat.currentVersion else {
            throw WorkspaceError.storageCorrupted("unsupported store format version \(format.version)")
        }
    }

    private func workspaceDirectoryURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    private func checkpointsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("checkpoints", isDirectory: true)
    }

    private func snapshotsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("snapshots", isDirectory: true)
    }

    private func checkpointURL(id: UUID, workspaceId: UUID) -> URL {
        checkpointsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func snapshotURL(id: UUID, workspaceId: UUID) -> URL {
        snapshotsDirectoryURL(workspaceId: workspaceId).appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private func blobsDirectoryURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("blobs", isDirectory: true)
    }

    private func blobURL(hash: String, workspaceId: UUID) -> URL {
        blobsDirectoryURL(workspaceId: workspaceId).appendingPathComponent(hash, isDirectory: false)
    }

    private func mutationsJsonlURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.jsonl", isDirectory: false)
    }

    /// A persistent sidecar lockfile used to serialize mutation-log access.
    ///
    /// The mutations log is append-only; we still take the lock on a **stable** sidecar so the lock
    /// is not taken on a file that is unlinked/renamed by atomic write helpers in other
    /// subsystems. Mutations are written to `mutations.jsonl`.
    private func mutationsLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("mutations.lock", isDirectory: false)
    }

    /// Serializes checkpoint, manifest, and blob lifecycle operations across store instances.
    private func lifecycleLockURL(workspaceId: UUID) -> URL {
        workspaceDirectoryURL(workspaceId: workspaceId).appendingPathComponent("lifecycle.lock", isDirectory: false)
    }

    private func formatLockURL(workspaceId: UUID) -> URL {
        rootDirectory.appendingPathComponent(".\(workspaceId.uuidString).format.lock", isDirectory: false)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private struct LockFileError: Error {
        var message: String
    }

    private struct StoreFormat: Codable {
        static let currentVersion = 1
        var version: Int
    }

#if canImport(Darwin) || canImport(Glibc)
    private func withExclusiveLifecycleLock<R>(
        at url: URL,
        _ body: () async throws -> R
    ) async throws -> R {
        let path = url.path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw LockFileError(message: "could not open lock file at \(path)") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw LockFileError(message: "could not acquire exclusive lock at \(path)") }
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    private static func withExclusiveLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        try withLock(at: url, operation: LOCK_EX, body)
    }

    private static func withSharedLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        try withLock(at: url, operation: LOCK_SH, body)
    }

    private static func withLock<R>(at url: URL, operation: Int32, _ body: () throws -> R) throws -> R {
        let path = url.path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw LockFileError(message: "could not open lock file at \(path)")
        }
        defer { close(fd) }
        while flock(fd, operation) != 0 {
            if errno != EINTR {
                throw LockFileError(message: "could not acquire exclusive lock at \(path)")
            }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
#else
    private func withExclusiveLifecycleLock<R>(
        at url: URL,
        _ body: () async throws -> R
    ) async throws -> R {
        _ = url
        return try await body()
    }

    private static func withExclusiveLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        try body()
    }

    private static func withSharedLock<R>(at url: URL, _ body: () throws -> R) throws -> R {
        try body()
    }
#endif
}
