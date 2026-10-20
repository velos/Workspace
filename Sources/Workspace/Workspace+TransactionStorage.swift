import Foundation

extension Workspace {
    // Snapshot restoration deliberately avoids chmod through symlinks. Backends with
    // lchmod semantics can restore the link's own mode safely, including during rollback.
    func restoreTransactionSymlinkPermissions(_ entry: Snapshot.Entry) async throws {
        switch entry {
        case let .symlink(link):
            if !(await filesystem.previewBehavior(at: link.path)).followsPermissionSymlinks,
               try await filesystem.stat(path: link.path).permissions != link.permissions {
                try await filesystem.setPermissions(path: link.path, permissions: link.permissions)
            }
        case let .directory(directory):
            for child in directory.children { try await restoreTransactionSymlinkPermissions(child) }
        default: break
        }
    }

    func enableTransactionJournal() { transactionRoots = [] }

    func transactionTree(over base: TransactionTree) async throws -> TransactionTree {
        await acquireOperation()
        defer { releaseOperation() }
        if let roots = transactionRoots {
            var snapshots: [Snapshot] = []
            for path in roots.sorted() where !snapshots.contains(where: { Snapshot.contains($0.rootPath, path) }) {
                snapshots.append(try await Snapshot.capture(from: filesystem, at: path))
            }
            return base.replacing(with: snapshots)
        }
        return base.replacing(with: [try await Snapshot.capture(from: filesystem)])
    }

    func storedTransactionTree(_ checkpoint: Checkpoint, in store: any CheckpointStore) async throws -> TransactionTree {
        if usesMemoryPersistence,
           let snapshot = try await store.loadSnapshot(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceId) {
            var nodes: [WorkspacePath: MergeNode] = [:]
            Self.flattenMergeNodes(snapshot.entry, into: &nodes)
            var tree = TransactionTree(nodes: nodes, load: { _ in throw WorkspaceError.readOnly })
            tree.checkpointID = checkpoint.id
            return tree
        }
        return try await TransactionRevisionGate.shared.withLock {
            let content = TransactionRevisionContent(checkpoint: checkpoint, store: store)
            guard let index = try await store.loadRevisionIndex(id: checkpoint.snapshotId, workspaceId: checkpoint.workspaceId) else {
                throw WorkspaceError.revisionDataNotFound(checkpoint.snapshotId)
            }
            var tree = TransactionTree(index: index, load: { try await content.read($0) })
            tree.checkpointID = checkpoint.id
            tree.revisionPin = TransactionRevisionPin(checkpoint)
            return tree
        }
    }

    func seedTransactionBase(_ checkpoint: Checkpoint, metadata: MetadataIndex) async throws {
        transactionBase = try await storedTransactionTree(checkpoint, in: store)
        transactionMetadata = metadata
        coldTransactionBase = nil
    }

    func persistMutationCheckpoint(tree: TransactionTree, metadata previousMetadata: MetadataIndex, changedRoots: [WorkspacePath], label: String?, origin: Checkpoint.Origin,
                                   operation: Mutation.Operation, changes: ChangeSet) async throws -> Checkpoint {
        try await withMutationCheckpoint(operation: operation, changes: changes) {
            var metadata = previousMetadata
            for root in changedRoots {
                let replacement = try await MetadataIndex.capture(from: filesystem, at: root)
                for path in metadata.entries.keys where Snapshot.contains(root, path) { metadata.entries.removeValue(forKey: path) }
                metadata.entries.merge(replacement.entries) { _, new in new }
            }
            let checkpoint: Checkpoint
            let draft = CheckpointDraft(workspaceID: workspaceId, label: label, preferredParentID: headCheckpointId, origin: origin)
            if usesMemoryPersistence {
                // The memory store shares unchanged Data with its prior revision.
                checkpoint = try await store.saveRevision(tree.snapshot(), draft: draft)
            } else {
                checkpoint = try await store.captureRevision(from: filesystem, draft: draft)
            }
            checkpoints.append(checkpoint)
            checkpoints.sort(by: checkpointSort)
            headCheckpointId = Checkpoint.lineageHeadID(in: checkpoints)
            // A directory base owns only the newest revision index, never accumulated
            // changed-file bytes or a read cache from earlier transactions. Index-loading
            // failure must not retract an already durable checkpoint; the next begin freezes anew.
            transactionBase = usesMemoryPersistence ? tree : try? await storedTransactionTree(checkpoint, in: store)
            transactionBase?.checkpointID = checkpoint.id
            transactionMetadata = transactionBase == nil ? nil : metadata
            coldTransactionBase = nil
            emitWorkspaceEvent(.checkpoint(checkpoint))
            return checkpoint
        }
    }
}
