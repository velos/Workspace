import Foundation

/// Immutable nodes and lazy content from a revision, plus changed file bytes.
struct TransactionTree: Sendable {
    var nodes: [WorkspacePath: Workspace.MergeNode]
    let children: [WorkspacePath: [WorkspacePath]]
    var checkpointID: UUID?
    var revisionPin: TransactionRevisionPin?
    var deltaPaths: Set<WorkspacePath> = []
    var load: @Sendable (WorkspacePath) async throws -> Data

    init(index: RevisionIndex, load: @escaping @Sendable (WorkspacePath) async throws -> Data) {
        var nodes: [WorkspacePath: Workspace.MergeNode] = [:]
        func visit(_ entry: RevisionIndex.Entry) {
            switch entry {
            case .missing: break
            case let .file(path, size, permissions, id):
                nodes[path] = .init(kind: .file, permissions: permissions, contentID: id, size: size)
            case let .directory(path, permissions, children):
                nodes[path] = .init(kind: .directory, permissions: permissions)
                children.forEach(visit)
            case let .symbolicLink(path, target, permissions):
                nodes[path] = .init(kind: .symlink, permissions: permissions, symlinkTarget: target)
            }
        }
        visit(index.entry)
        self.nodes = nodes
        var children: [WorkspacePath: [WorkspacePath]] = [:]
        for path in nodes.keys where !path.isRoot { children[path.parent, default: []].append(path) }
        self.children = children
        self.load = load
    }

    init(nodes: [WorkspacePath: Workspace.MergeNode], load: @escaping @Sendable (WorkspacePath) async throws -> Data) {
        self.nodes = nodes
        var children: [WorkspacePath: [WorkspacePath]] = [:]
        for path in nodes.keys where !path.isRoot { children[path.parent, default: []].append(path) }
        self.children = children
        self.load = load
    }

    func data(_ path: WorkspacePath) async throws -> Data {
        if let data = nodes[path]?.fileData { return data }
        return try await load(path)
    }

    /// Only affected subtrees need content; directory capture builds its child map once.
    func snapshot(at root: WorkspacePath = .root) async throws -> Snapshot {
        func materialize(_ path: WorkspacePath) async throws -> Snapshot.Entry {
            guard let node = nodes[path] else { return .missing(.init(path: path)) }
            switch node.kind {
            case .file: return .file(.init(path: path, data: try await data(path), permissions: node.permissions))
            case .symlink: return .symlink(.init(path: path, target: node.symlinkTarget!, permissions: node.permissions))
            case .directory:
                var result: [Snapshot.Entry] = []
                for child in (children[path] ?? []).sorted() { result.append(try await materialize(child)) }
                return .directory(.init(path: path, permissions: node.permissions, children: result))
            }
        }
        return Snapshot(rootPath: root, entry: try await materialize(root))
    }

    func changes(to other: Self, paths: Set<WorkspacePath>? = nil, maxTextBytes: Int? = DiffOptions.default.maxTextBytes) async throws -> ChangeSet {
        var changes: [FileChange] = []
        var omissions: [TextDiffOmission] = []
        func leaf(_ path: WorkspacePath, in tree: Self) async throws -> Snapshot {
            if let node = tree.nodes[path], node.kind == .directory {
                return Snapshot(rootPath: path, entry: .directory(.init(path: path, permissions: node.permissions, children: [])))
            }
            return try await tree.snapshot(at: path)
        }
        for path in paths ?? Set(nodes.keys).union(other.nodes.keys) where nodes[path] != other.nodes[path] {
            let part = try await ChangeSet.compare(before: leaf(path, in: self), after: leaf(path, in: other), maxTextBytes: maxTextBytes)
            changes += part.changes
            omissions += part.textDiffOmissions
        }
        return ChangeSet(changes: changes, textDiffOmissions: omissions)
    }

    func updating(from fs: any FileSystem, metadata: MetadataIndex, previous: MetadataIndex, policy: Workspace.CheckpointCapturePolicy) async throws -> Self {
        var updated = nodes
        var changed: Set<WorkspacePath> = []
        for path in nodes.keys where metadata.entries[path] == nil {
            updated.removeValue(forKey: path)
            changed.insert(path)
        }
        for (path, entry) in metadata.entries {
            let info = entry.info
            var node = Workspace.MergeNode(kind: info.kind, permissions: info.permissions, symlinkTarget: entry.target)
            if info.kind == .file {
                if policy == .trustMetadata, let old = previous.entries[path], entry.canReuseContents(old, capturedAt: previous.capturedAt, exactTimestamps: metadata.exactTimestamps && previous.exactTimestamps), let existing = nodes[path], existing.kind == .file {
                    node = existing
                    node.permissions = info.permissions
                } else {
                    let bytes = try await fs.readFile(path: path)
                    node = .init(kind: .file, permissions: info.permissions, fileData: bytes, size: UInt64(bytes.count))
                }
            }
            if nodes[path] != node {
                updated[path] = node
                changed.insert(path)
            }
        }
        var result = Self(nodes: updated, load: load)
        result.checkpointID = checkpointID
        result.revisionPin = revisionPin
        result.deltaPaths = changed
        return result
    }

    func replacing(with snapshots: [Snapshot]) -> Self {
        var updated = nodes
        var candidates: Set<WorkspacePath> = []
        for snapshot in snapshots {
            let removed = updated[snapshot.rootPath]?.kind == .directory
                ? updated.keys.filter { Snapshot.contains(snapshot.rootPath, $0) } : [snapshot.rootPath]
            for path in removed { updated.removeValue(forKey: path); candidates.insert(path) }
            var replacement: [WorkspacePath: Workspace.MergeNode] = [:]
            Workspace.flattenMergeNodes(snapshot.entry, into: &replacement)
            candidates.formUnion(replacement.keys)
            updated.merge(replacement) { _, new in new }
        }
        var result = Self(nodes: updated, load: load)
        result.checkpointID = checkpointID
        result.revisionPin = revisionPin
        result.deltaPaths = Set(candidates.filter { nodes[$0] != updated[$0] })
        return result
    }

}

/// Read-only revision adapter. Directory lookup is indexed once, with no content materialization.
final class TransactionFileSystem: FileSystem, Sendable {
    let tree: TransactionTree
    let children: [WorkspacePath: [WorkspacePath]]
    init(_ tree: TransactionTree) {
        self.tree = tree
        self.children = tree.children
    }
    func stat(path: WorkspacePath) async throws -> FileInfo {
        guard let node = tree.nodes[path] else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        return FileInfo(path: path, kind: node.kind, size: node.size, permissions: node.permissions, modificationDate: nil)
    }
    func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        guard try await stat(path: path).kind == .directory else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
        var result: [DirectoryEntry] = []
        for child in (children[path] ?? []).sorted() { result.append(DirectoryEntry(name: child.name, info: try await stat(path: child))) }
        return result
    }
    func readFile(path: WorkspacePath) async throws -> Data { try await tree.data(path) }
    func readSymlink(path: WorkspacePath) async throws -> String {
        guard let target = tree.nodes[path]?.symlinkTarget else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
        return target
    }
    func exists(path: WorkspacePath) async -> Bool { tree.nodes[path] != nil }
    func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let pattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(pattern.string))
        return tree.nodes.keys.filter { regex.firstMatch(in: $0.string, range: NSRange($0.string.startIndex..., in: $0.string)) != nil }.sorted()
    }
    func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws { throw WorkspaceError.readOnly }
    func createDirectory(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func remove(path: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
    func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws { throw WorkspaceError.readOnly }
    func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws { throw WorkspaceError.readOnly }
}

/// A live handle owns the cold base. The parent keeps only a weak reference so
/// abandoning the last handle releases its bytes without an asynchronous cleanup.
final class ColdTransactionBase: Sendable {
    let tree: TransactionTree
    let metadata: MetadataIndex
    init(tree: TransactionTree, metadata: MetadataIndex) {
        self.tree = tree
        self.metadata = metadata
    }
}

/// Bounded memory plus private immutable overflow blobs for a cold directory base.
/// No public checkpoint, manifest, or eager hash is needed for retained bytes.
final class TransactionBacking: Sendable {
    static let memoryBudgetBytes = 256 * 1024 * 1024
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Workspace-transaction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func freeze(from fs: any FileSystem, previous: ColdTransactionBase? = nil,
                       policy: Workspace.CheckpointCapturePolicy = .trustMetadata) async throws -> ColdTransactionBase {
        var metadata = MetadataIndex()
        metadata.exactTimestamps = await fs.supportsExactContentTimestamps
        var nodes: [WorkspacePath: Workspace.MergeNode] = [:]
        var blobs: Set<String> = []
        var spooled: [WorkspacePath: String] = [:]
        var backing: TransactionBacking?
        var remaining = memoryBudgetBytes
        try await fs.walk { info, read, readLink in
            let path = info.path
            let target = info.kind == .symlink ? try await readLink() : nil
            let entry = MetadataIndex.Entry(info: info, target: target)
            metadata.entries[path] = entry
            var node = Workspace.MergeNode(kind: entry.info.kind, permissions: entry.info.permissions,
                                           symlinkTarget: entry.target)
            if entry.info.kind == .file {
                if policy == .trustMetadata, let previous, let old = previous.metadata.entries[path],
                   entry.canReuseContents(old, capturedAt: previous.metadata.capturedAt,
                                          exactTimestamps: metadata.exactTimestamps && previous.metadata.exactTimestamps),
                   let existing = previous.tree.nodes[path], existing.kind == .file {
                    node = existing
                    node.permissions = entry.info.permissions
                } else {
                    let data = try await read(nil)
                    node = .init(kind: .file, permissions: entry.info.permissions,
                                 fileData: data, size: UInt64(data.count))
                }
                if let data = node.fileData, data.count <= remaining {
                    remaining -= data.count
                } else if let data = node.fileData {
                    if backing == nil { backing = try TransactionBacking() }
                    let hash = node.contentID!
                    if blobs.insert(hash).inserted { try data.write(to: backing!.directory.appendingPathComponent(hash)) }
                    node = .init(kind: .file, permissions: entry.info.permissions,
                                 contentID: hash, size: UInt64(data.count))
                    spooled[path] = hash
                }
            }
            nodes[path] = node
        }
        let overflow = spooled, storage = backing, inheritedLoad = previous?.tree.load
        let tree = TransactionTree(nodes: nodes, load: { path in
            if let storage, let hash = overflow[path] {
                return try Data(contentsOf: storage.directory.appendingPathComponent(hash))
            }
            if let inheritedLoad { return try await inheritedLoad(path) }
            throw WorkspaceError.readOnly
        })
        return ColdTransactionBase(tree: tree, metadata: metadata)
    }
}

/// Revision reads remain lazy and uncached; parent lifetime must not retain read contents.
/// The registry keeps cooperative in-process compaction from deleting lazy bases.
actor TransactionRevisionContent {
    let checkpoint: Checkpoint
    let store: any CheckpointStore

    init(checkpoint: Checkpoint, store: any CheckpointStore) {
        self.checkpoint = checkpoint
        self.store = store
    }

    func read(_ path: WorkspacePath) async throws -> Data {
        guard let data = try await store.readSnapshotFile(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceId,
                                                        path: path, offset: 0, length: nil) else {
            throw WorkspaceError.revisionDataNotFound(checkpoint.snapshotId)
        }
        return data
    }
}

/// Each reusable base and transaction handle owns an independent pin. Compaction may
/// exclude its own reusable base while retaining handles and other workspace instances.
final class TransactionRevisionPin: Sendable {
    let checkpoint: Checkpoint
    let token: UUID
    init(_ checkpoint: Checkpoint) {
        self.checkpoint = checkpoint
        token = TransactionRevisionPins.shared.insert(checkpoint)
    }
    deinit { TransactionRevisionPins.shared.remove(token) }
}

final class TransactionRevisionPins: @unchecked Sendable {
    static let shared = TransactionRevisionPins()
    private let lock = NSLock()
    private var pins: [UUID: (workspace: UUID, checkpoint: UUID)] = [:]
    func insert(_ checkpoint: Checkpoint) -> UUID {
        let token = UUID()
        lock.withLock { pins[token] = (checkpoint.workspaceId, checkpoint.id) }
        return token
    }
    func remove(_ token: UUID) { _ = lock.withLock { pins.removeValue(forKey: token) } }
    func checkpoints(in workspace: UUID, excluding token: UUID? = nil) -> Set<UUID> {
        lock.withLock { Set(pins.filter { $0.key != token && $0.value.workspace == workspace }.map { $0.value.checkpoint }) }
    }
}

/// Serializes revision-pin acquisition with cooperative compaction across workspace instances.
actor TransactionRevisionGate {
    static let shared = TransactionRevisionGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if held { await withCheckedContinuation { waiters.append($0) } } else { held = true }
        defer {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
