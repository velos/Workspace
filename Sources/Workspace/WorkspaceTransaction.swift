import Foundation

extension Workspace {
    /// An isolated, long-lived editing session with preview, commit, and discard.
    public actor Transaction {
        public enum CommitStrategy: String, Sendable, Codable {
            /// Reject any parent change since the transaction began, including root metadata.
            case strict
            /// Merge whole nodes: identical changes converge; divergent changes conflict.
            /// Ancestor replacements also conflict with incompatible descendant changes.
            case threeWay
        }

        public struct Conflict: Sendable, Codable, Equatable {
            public enum Kind: String, Sendable, Codable {
                case bothModified
                case modifiedAndDeleted
                case bothCreated
                case parentChanged
                /// The conflict's path is the directory removed or replaced on one
                /// side while the other side changed something beneath it.
                case structural
            }

            public var path: WorkspacePath
            public var kind: Kind
            public var parentDiff: TextDiff?
            public var transactionDiff: TextDiff?

            public init(
                path: WorkspacePath,
                kind: Kind,
                parentDiff: TextDiff? = nil,
                transactionDiff: TextDiff? = nil
            ) {
                self.path = path
                self.kind = kind
                self.parentDiff = parentDiff
                self.transactionDiff = transactionDiff
            }
        }

        public struct Commit: Sendable {
            public var preview: ChangeSet
            public var appliedChanges: ChangeSet
            public var checkpoint: Checkpoint?
            public var conflicts: [Conflict]

            public var applied: Bool { conflicts.isEmpty }

            public init(
                preview: ChangeSet,
                appliedChanges: ChangeSet,
                checkpoint: Checkpoint?,
                conflicts: [Conflict]
            ) {
                self.preview = preview
                self.appliedChanges = appliedChanges
                self.checkpoint = checkpoint
                self.conflicts = conflicts
            }
        }

        public enum TransactionError: Swift.Error, Sendable {
            case inactive
            /// The transaction is committing and cannot accept edits, discard, or another commit.
            case committing
            case conflicts([Conflict])
        }

        enum State { case active, committing, committed, discarded, failed }

        public nonisolated let id: UUID
        private let parent: Workspace
        private struct Contents: Sendable {
            let draft: Workspace
            let base: TransactionTree
            let baseMetadata: MetadataIndex
            let coldBase: ColdTransactionBase?
        }
        private var contents: Contents?
        private let baseCheckpointID: UUID?
        private let label: String?
        private var state: State = .active
        private var pendingEdits = 0
        private var editsDrained: CheckedContinuation<Void, Never>?

        init(parent: Workspace, draft: Workspace, base: TransactionTree, metadata: MetadataIndex, coldBase: ColdTransactionBase? = nil, baseCheckpointID: UUID?, label: String?) {
            id = UUID()
            self.parent = parent
            self.contents = Contents(draft: draft, base: base, baseMetadata: metadata, coldBase: coldBase)
            self.baseCheckpointID = baseCheckpointID
            self.label = label
        }

        public func readData(from path: WorkspacePath) async throws -> Data {
            let contents = try requireReadable()
            return try await contents.draft.readData(from: path)
        }

        public func readText(_ path: WorkspacePath) async throws -> String {
            let contents = try requireReadable()
            return try await contents.draft.readText(path)
        }

        public func readJSON<T: Decodable & Sendable>(
            _ type: T.Type = T.self,
            from path: WorkspacePath
        ) async throws -> T {
            let contents = try requireReadable()
            return try await contents.draft.readJSON(type, from: path)
        }

        public func exists(_ path: WorkspacePath) async throws -> Bool {
            let contents = try requireReadable()
            return await contents.draft.exists(path)
        }

        public func info(_ path: WorkspacePath) async throws -> FileInfo {
            let contents = try requireReadable()
            return try await contents.draft.info(path)
        }

        public func list(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
            let contents = try requireReadable()
            return try await contents.draft.list(path)
        }

        public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
            let contents = try requireReadable()
            return try await contents.draft.glob(pattern, currentDirectory: currentDirectory)
        }

        public func tree(at path: WorkspacePath = .root, maxDepth: Int? = nil) async throws -> FileTree {
            let contents = try requireReadable()
            return try await contents.draft.tree(at: path, maxDepth: maxDepth)
        }

        public func search(_ request: SearchRequest) async throws -> SearchResult {
            let contents = try requireReadable()
            return try await contents.draft.search(request)
        }

        public func preview(_ edits: [Edit]) async throws -> ChangeSet {
            let contents = try requireReadable()
            return try await contents.draft.preview(edits)
        }

        @discardableResult
        public func apply(_ edits: [Edit], policy: EditPolicy = .atomic) async throws -> EditResult {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.apply(edits, policy: policy)
        }

        @discardableResult
        public func writeText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.writeText(path, content)
        }

        @discardableResult
        public func appendText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.appendText(path, content)
        }

        @discardableResult
        public func writeData(_ data: Data, to path: WorkspacePath) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.writeData(data, to: path)
        }

        @discardableResult
        public func appendData(_ path: WorkspacePath, _ data: Data) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.appendData(path, data)
        }

        @discardableResult
        public func writeJSON<T: Encodable & Sendable>(
            _ value: T,
            to path: WorkspacePath,
            prettyPrinted: Bool = true
        ) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.writeJSON(value, to: path, prettyPrinted: prettyPrinted)
        }

        @discardableResult
        public func createDirectory(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.createDirectory(path, recursive: recursive)
        }

        @discardableResult
        public func remove(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.remove(path, recursive: recursive)
        }

        @discardableResult
        public func copy(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true)
            async throws -> ChangeSet
        {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.copy(from: source, to: destination, recursive: recursive)
        }

        @discardableResult
        public func move(from source: WorkspacePath, to destination: WorkspacePath) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.move(from: source, to: destination)
        }

        @discardableResult
        public func createSymbolicLink(_ path: WorkspacePath, target: String) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.createSymbolicLink(path, target: target)
        }

        @discardableResult
        public func createHardLink(_ path: WorkspacePath, target: WorkspacePath) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.createHardLink(path, target: target)
        }

        @discardableResult
        public func setPermissions(_ permissions: POSIXPermissions, at path: WorkspacePath) async throws -> ChangeSet {
            let contents = try beginEdit()
            defer { endEdit() }
            return try await contents.draft.setPermissions(permissions, at: path)
        }

        /// Returns all base-to-draft changes without mutating the parent workspace.
        public func preview() async throws -> ChangeSet {
            let contents = try requireReadable()
            let current = try await contents.draft.transactionTree(over: contents.base)
            return try await contents.base.changes(to: current, paths: current.deltaPaths)
        }

        /// Attempts to commit this transaction. Conflicts and safely rolled-back failures
        /// leave it active for retry. A rollback failure permanently closes it.
        public func commit(strategy: CommitStrategy = .threeWay) async throws -> Commit {
            let contents = try requireActive()
            state = .committing
            do {
                // An edit admitted before commit may still be suspended in the draft.
                // Drain those edits before capture; new edits are rejected by requireActive.
                if pendingEdits > 0 {
                    await withCheckedContinuation { editsDrained = $0 }
                }
                try Task.checkCancellation()
                let draftSnapshot = try await contents.draft.transactionTree(over: contents.base)
                let result = try await parent.commitTransaction(
                    base: contents.base,
                    draft: draftSnapshot,
                    baseMetadata: contents.baseMetadata,
                    baseCheckpointID: baseCheckpointID,
                    label: label,
                    strategy: strategy
                )
                state = result.conflicts.isEmpty ? .committed : .active
                if state == .committed { self.contents = nil }
                return result
            } catch {
                // The parent's gate covers restoration too. An ordinary error means
                // no mutation occurred or compensation succeeded. Failed compensation
                // may have left filesystem or history changes behind: never allow retry.
                state = error is WorkspaceRollbackError ? .failed : .active
                if state == .failed { self.contents = nil }
                throw error
            }
        }

        /// Permanently discards the transaction.
        public func discard() throws {
            _ = try requireActive()
            state = .discarded
            contents = nil
        }

        private func beginEdit() throws -> Contents {
            let contents = try requireActive()
            pendingEdits += 1
            return contents
        }

        private func endEdit() {
            pendingEdits -= 1
            if pendingEdits == 0 {
                editsDrained?.resume()
                editsDrained = nil
            }
        }

        private func requireReadable() throws -> Contents {
            guard state == .active || state == .committing, let contents else { throw TransactionError.inactive }
            return contents
        }

        private func requireActive() throws -> Contents {
            if state == .committing { throw TransactionError.committing }
            guard state == .active, let contents else { throw TransactionError.inactive }
            return contents
        }
    }

    public struct TransactionResult<Value: Sendable>: Sendable {
        public var value: Value
        public var commit: Transaction.Commit
    }

    /// Starts an isolated transaction from the workspace's complete current state.
    public func beginTransaction(label: String? = nil) async throws -> Transaction {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()
        hasBegunTransaction = true
        let metadata: MetadataIndex
        var base: TransactionTree
        let coldBase: ColdTransactionBase?
        if !usesMemoryPersistence && transactionBase == nil {
            let frozen = try await TransactionBacking.freeze(from: filesystem,
                previous: coldTransactionBase, policy: checkpointCapture)
            base = frozen.tree
            metadata = frozen.metadata
            coldBase = frozen
            coldTransactionBase = frozen
        } else {
            metadata = try await MetadataIndex.capture(from: filesystem)
            coldBase = nil
            if let previous = transactionBase, let previousMetadata = transactionMetadata {
                base = try await previous.updating(from: filesystem, metadata: metadata, previous: previousMetadata, policy: checkpointCapture)
            } else {
                var nodes: [WorkspacePath: MergeNode] = [:]
                for (path, entry) in metadata.entries {
                    let bytes = entry.info.kind == .file ? try await filesystem.readFile(path: path) : nil
                    nodes[path] = MergeNode(kind: entry.info.kind, permissions: entry.info.permissions,
                                            fileData: bytes, symlinkTarget: entry.target, size: UInt64(bytes?.count ?? 0))
                }
                base = TransactionTree(nodes: nodes, load: { _ in throw WorkspaceError.readOnly })
            }
            transactionBase = base
            transactionMetadata = metadata
        }
        if let pin = base.revisionPin { base.revisionPin = TransactionRevisionPin(pin.checkpoint) }
        let draftFileSystem = OverlayFileSystem(over: TransactionFileSystem(base), semanticsOf: filesystem)
        let draft = Workspace(
            fileSystem: draftFileSystem,
            persistence: .memory,
            recording: recording
        )
        await draft.enableTransactionJournal()
        return Transaction(
            parent: self,
            draft: draft,
            base: base,
            metadata: metadata,
            coldBase: coldBase,
            baseCheckpointID: headCheckpointId,
            label: label
        )
    }

    /// Runs a scoped transaction, committing on success and discarding on failure or conflict.
    public func transaction<Value: Sendable>(
        label: String? = nil,
        _ body: @Sendable (Transaction) async throws -> Value
    ) async throws -> TransactionResult<Value> {
        let transaction = try await beginTransaction(label: label)
        do {
            let value = try await body(transaction)
            let commit = try await transaction.commit()
            guard commit.conflicts.isEmpty else {
                try await transaction.discard()
                throw Transaction.TransactionError.conflicts(commit.conflicts)
            }
            return TransactionResult(value: value, commit: commit)
        } catch {
            try? await transaction.discard()
            throw error
        }
    }

    func commitTransaction(
        base: TransactionTree,
        draft: TransactionTree,
        baseMetadata: MetadataIndex,
        baseCheckpointID: UUID?,
        label: String?,
        strategy: Transaction.CommitStrategy
    ) async throws -> Transaction.Commit {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        try await reconcileCheckpointsWithStore()
        let metadata = try await MetadataIndex.capture(from: filesystem)
        let current = try await base.updating(from: filesystem, metadata: metadata, previous: baseMetadata, policy: checkpointCapture)
        let preview = try await base.changes(to: draft, paths: draft.deltaPaths)
        let baseNodes = base.nodes
        let currentNodes = current.nodes
        let draftNodes = draft.nodes

        if strategy == .strict, !current.deltaPaths.isEmpty {
            let changed = current.deltaPaths
            return Transaction.Commit(
                preview: preview,
                appliedChanges: ChangeSet(),
                checkpoint: nil,
                conflicts: changed.sorted().map { .init(path: $0, kind: .parentChanged) }
            )
        }

        var merged = currentNodes
        let changedPaths = current.deltaPaths.union(draft.deltaPaths)
        let structuralPaths = Self.structuralMergeConflicts(base: baseNodes, parent: currentNodes, draft: draftNodes, paths: changedPaths)
        var conflicts = structuralPaths.sorted().map { Transaction.Conflict(path: $0, kind: .structural) }
        for path in changedPaths.sorted() {
            // One structural conflict describes the entire affected subtree;
            // suppress redundant node conflicts beneath it.
            var ancestor = path
            while !ancestor.isRoot && !structuralPaths.contains(ancestor) { ancestor = ancestor.parent }
            if structuralPaths.contains(ancestor) { continue }
            let baseNode = baseNodes[path]
            let parentNode = currentNodes[path]
            let transactionNode = draftNodes[path]
            if transactionNode == baseNode || parentNode == transactionNode { continue }
            if parentNode == baseNode {
                if let transactionNode { merged[path] = transactionNode } else { merged.removeValue(forKey: path) }
                continue
            }
            let kind: Transaction.Conflict.Kind
            if baseNode == nil {
                kind = .bothCreated
            } else if parentNode == nil || transactionNode == nil {
                kind = .modifiedAndDeleted
            } else {
                kind = .bothModified
            }
            conflicts.append(
                .init(
                    path: path,
                    kind: kind,
                    parentDiff: try await Self.conflictDiffForTransaction(path: path, from: base, to: current),
                    transactionDiff: try await Self.conflictDiffForTransaction(path: path, from: base, to: draft)
                )
            )
        }
        guard conflicts.isEmpty else {
            return Transaction.Commit(
                preview: preview,
                appliedChanges: ChangeSet(),
                checkpoint: nil,
                conflicts: conflicts.sorted { $0.path < $1.path }
            )
        }

        // Validate ancestry before the first parent write.
        let mergedNodes = merged
        let mergedTree = TransactionTree(nodes: mergedNodes, load: current.load)
        try Self.validateMergeNodes(merged)
        let applied = try await current.changes(to: mergedTree, paths: draft.deltaPaths)
        guard !applied.isEmpty else {
            return Transaction.Commit(preview: preview, appliedChanges: applied, checkpoint: nil, conflicts: [])
        }

        // A child-only change may sit below a directory the parent made read-only.
        // Include restrictive ancestors so restore can grant temporary owner access
        // and reapply their final modes after restoring the children. The operation
        // gate still owns the complete capture/restore/rollback sequence.
        var restoreRoots = Set(applied.touchedPaths)
        for path in applied.touchedPaths {
            var ancestor = path
            while !ancestor.isRoot {
                ancestor = ancestor.parent
                if let node = currentNodes[ancestor], node.kind == .directory,
                   node.permissions.rawValue & 0o700 != 0o700 {
                    restoreRoots.insert(ancestor)
                }
            }
        }
        var before: [Snapshot] = []
        var after: [Snapshot] = []
        for path in restoreRoots.sorted() {
            if before.contains(where: { Snapshot.contains($0.rootPath, path) }) { continue }
            before.append(try await current.snapshot(at: path))
            after.append(try await mergedTree.snapshot(at: path))
        }
        do {
            for snapshot in after {
                try await Snapshot.restore(snapshot, to: filesystem)
                try await restoreTransactionSymlinkPermissions(snapshot.entry)
            }
            let checkpoint = try await persistMutationCheckpoint(
                tree: mergedTree,
                metadata: metadata,
                changedRoots: after.map(\.rootPath),
                label: label,
                origin: .transaction(base: baseCheckpointID),
                operation: .transaction,
                changes: recordingChanges(applied, from: before, to: after)
            )
            for snapshot in after { await noteWorkspaceSnapshot(snapshot) }
            emitWorkspaceEvent(.changes(applied))
            return Transaction.Commit(preview: preview, appliedChanges: applied, checkpoint: checkpoint, conflicts: [])
        } catch {
            try await restoreAfterFailure(before, originalError: error, restoringSymlinkPermissions: true)
        }
    }

    private static func conflictDiffForTransaction(path: WorkspacePath, from base: TransactionTree, to side: TransactionTree) async throws -> TextDiff? {
        let baseData = base.nodes[path]?.kind == .file ? try await base.data(path) : Data()
        let sideData = side.nodes[path]?.kind == .file ? try await side.data(path) : Data()
        guard let baseText = String(data: baseData, encoding: .utf8),
              let sideText = String(data: sideData, encoding: .utf8)
        else { return nil }
        let diff = TextDiff.lineBased(from: baseText, to: sideText)
        return diff.hunks.isEmpty ? nil : diff
    }
}
