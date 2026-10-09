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
        private let draft: Workspace
        private let base: Snapshot
        private let baseCheckpointID: UUID?
        private let label: String?
        private var state: State = .active
        private var pendingEdits = 0
        private var editsDrained: CheckedContinuation<Void, Never>?

        init(parent: Workspace, draft: Workspace, base: Snapshot, baseCheckpointID: UUID?, label: String?) {
            id = UUID()
            self.parent = parent
            self.draft = draft
            self.base = base
            self.baseCheckpointID = baseCheckpointID
            self.label = label
        }

        public func readData(from path: WorkspacePath) async throws -> Data {
            try requireReadable()
            return try await draft.readData(from: path)
        }

        public func readText(_ path: WorkspacePath) async throws -> String {
            try requireReadable()
            return try await draft.readText(path)
        }

        public func readJSON<T: Decodable & Sendable>(
            _ type: T.Type = T.self,
            from path: WorkspacePath
        ) async throws -> T {
            try requireReadable()
            return try await draft.readJSON(type, from: path)
        }

        public func exists(_ path: WorkspacePath) async throws -> Bool {
            try requireReadable()
            return await draft.exists(path)
        }

        public func info(_ path: WorkspacePath) async throws -> FileInfo {
            try requireReadable()
            return try await draft.info(path)
        }

        public func list(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
            try requireReadable()
            return try await draft.list(path)
        }

        public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
            try requireReadable()
            return try await draft.glob(pattern, currentDirectory: currentDirectory)
        }

        public func tree(at path: WorkspacePath = .root, maxDepth: Int? = nil) async throws -> FileTree {
            try requireReadable()
            return try await draft.tree(at: path, maxDepth: maxDepth)
        }

        public func search(_ request: SearchRequest) async throws -> SearchResult {
            try requireReadable()
            return try await draft.search(request)
        }

        public func preview(_ edits: [Edit]) async throws -> ChangeSet {
            try requireReadable()
            return try await draft.preview(edits)
        }

        @discardableResult
        public func apply(_ edits: [Edit], policy: EditPolicy = .atomic) async throws -> EditResult {
            try beginEdit()
            defer { endEdit() }
            return try await draft.apply(edits, policy: policy)
        }

        @discardableResult
        public func writeText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.writeText(path, content)
        }

        @discardableResult
        public func appendText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.appendText(path, content)
        }

        @discardableResult
        public func writeData(_ data: Data, to path: WorkspacePath) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.writeData(data, to: path)
        }

        @discardableResult
        public func appendData(_ path: WorkspacePath, _ data: Data) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.appendData(path, data)
        }

        @discardableResult
        public func writeJSON<T: Encodable & Sendable>(
            _ value: T,
            to path: WorkspacePath,
            prettyPrinted: Bool = true
        ) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.writeJSON(value, to: path, prettyPrinted: prettyPrinted)
        }

        @discardableResult
        public func createDirectory(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.createDirectory(path, recursive: recursive)
        }

        @discardableResult
        public func remove(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.remove(path, recursive: recursive)
        }

        @discardableResult
        public func copy(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true)
            async throws -> ChangeSet
        {
            try beginEdit()
            defer { endEdit() }
            return try await draft.copy(from: source, to: destination, recursive: recursive)
        }

        @discardableResult
        public func move(from source: WorkspacePath, to destination: WorkspacePath) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.move(from: source, to: destination)
        }

        @discardableResult
        public func createSymbolicLink(_ path: WorkspacePath, target: String) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.createSymbolicLink(path, target: target)
        }

        @discardableResult
        public func createHardLink(_ path: WorkspacePath, target: WorkspacePath) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.createHardLink(path, target: target)
        }

        @discardableResult
        public func setPermissions(_ permissions: POSIXPermissions, at path: WorkspacePath) async throws -> ChangeSet {
            try beginEdit()
            defer { endEdit() }
            return try await draft.setPermissions(permissions, at: path)
        }

        /// Returns all base-to-draft changes without mutating the parent workspace.
        public func preview() async throws -> ChangeSet {
            try requireReadable()
            let current = try await draft.revisionSnapshot(.current)
            return ChangeSet.compare(before: base, after: current, maxTextBytes: DiffOptions.default.maxTextBytes)
        }

        /// Attempts to commit this transaction. Conflicts and safely rolled-back failures
        /// leave it active for retry. A rollback failure permanently closes it.
        public func commit(strategy: CommitStrategy = .threeWay) async throws -> Commit {
            try requireActive()
            state = .committing
            do {
                // An edit admitted before commit may still be suspended in the draft.
                // Drain those edits before capture; new edits are rejected by requireActive.
                if pendingEdits > 0 {
                    await withCheckedContinuation { editsDrained = $0 }
                }
                try Task.checkCancellation()
                let draftSnapshot = try await draft.revisionSnapshot(.current)
                let result = try await parent.commitTransaction(
                    base: base,
                    draft: draftSnapshot,
                    baseCheckpointID: baseCheckpointID,
                    label: label,
                    strategy: strategy
                )
                state = result.conflicts.isEmpty ? .committed : .active
                return result
            } catch {
                // The parent's gate covers restoration too. An ordinary error means
                // no mutation occurred or compensation succeeded. Failed compensation
                // may have left filesystem or history changes behind: never allow retry.
                state = error is WorkspaceRollbackError ? .failed : .active
                throw error
            }
        }

        /// Permanently discards the transaction.
        public func discard() throws {
            try requireActive()
            state = .discarded
        }

        private func beginEdit() throws {
            try requireActive()
            pendingEdits += 1
        }

        private func endEdit() {
            pendingEdits -= 1
            if pendingEdits == 0 {
                editsDrained?.resume()
                editsDrained = nil
            }
        }

        private func requireReadable() throws {
            guard state == .active || state == .committing else { throw TransactionError.inactive }
        }

        private func requireActive() throws {
            if state == .committing { throw TransactionError.committing }
            guard state == .active else { throw TransactionError.inactive }
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
        let base = try await Snapshot.capture(from: filesystem)
        let draftFileSystem = InMemoryFileSystem()
        try await Snapshot.restore(base, to: draftFileSystem)
        let draft = Workspace(
            fileSystem: draftFileSystem,
            persistence: .memory,
            recording: recording
        )
        return Transaction(
            parent: self,
            draft: draft,
            base: base,
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
        base: Snapshot,
        draft: Snapshot,
        baseCheckpointID: UUID?,
        label: String?,
        strategy: Transaction.CommitStrategy
    ) async throws -> Transaction.Commit {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        try await prepareForMutation()
        try await reconcileCheckpointsWithStore()
        let current = try await Snapshot.capture(from: filesystem)
        let preview = ChangeSet.compare(before: base, after: draft, maxTextBytes: DiffOptions.default.maxTextBytes)

        var baseNodes: [WorkspacePath: MergeNode] = [:]
        var currentNodes: [WorkspacePath: MergeNode] = [:]
        var draftNodes: [WorkspacePath: MergeNode] = [:]
        Self.flattenMergeNodes(base.entry, into: &baseNodes)
        Self.flattenMergeNodes(current.entry, into: &currentNodes)
        Self.flattenMergeNodes(draft.entry, into: &draftNodes)

        if strategy == .strict, currentNodes != baseNodes {
            let changed = Set(baseNodes.keys).union(currentNodes.keys).filter { baseNodes[$0] != currentNodes[$0] }
            return Transaction.Commit(
                preview: preview,
                appliedChanges: ChangeSet(),
                checkpoint: nil,
                conflicts: changed.sorted().map { .init(path: $0, kind: .parentChanged) }
            )
        }

        var merged = currentNodes
        let structuralPaths = Self.structuralMergeConflicts(base: baseNodes, parent: currentNodes, draft: draftNodes)
        var conflicts = structuralPaths.sorted().map { Transaction.Conflict(path: $0, kind: .structural) }
        for path in Set(baseNodes.keys).union(currentNodes.keys).union(draftNodes.keys).sorted() {
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
                    parentDiff: Self.conflictDiffForTransaction(from: baseNode, to: parentNode),
                    transactionDiff: Self.conflictDiffForTransaction(from: baseNode, to: transactionNode)
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

        // Reconstruction validates the whole flat map before the first parent write.
        let mergedSnapshot = Snapshot(rootPath: .root, entry: try Self.buildEntryTree(from: merged))
        let applied = ChangeSet.compare(before: current, after: mergedSnapshot, maxTextBytes: DiffOptions.default.maxTextBytes)
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
            let oldEntry = Self.snapshotEntry(at: path, in: current.entry) ?? .missing(.init(path: path))
            let newEntry = Self.snapshotEntry(at: path, in: mergedSnapshot.entry) ?? .missing(.init(path: path))
            before.append(Snapshot(rootPath: path, entry: oldEntry))
            after.append(Snapshot(rootPath: path, entry: newEntry))
        }
        do {
            for snapshot in after { try await Snapshot.restore(snapshot, to: filesystem) }
            let checkpoint = try await persistMutationCheckpoint(
                snapshot: mergedSnapshot,
                label: label,
                origin: .transaction(base: baseCheckpointID),
                operation: .transaction,
                changes: recordingChanges(applied, from: current, to: mergedSnapshot)
            )
            for snapshot in after { noteWorkspaceSnapshot(snapshot) }
            emitWorkspaceEvent(.changes(applied))
            return Transaction.Commit(preview: preview, appliedChanges: applied, checkpoint: checkpoint, conflicts: [])
        } catch {
            try await restoreAfterFailure(before, originalError: error)
        }
    }

    private static func conflictDiffForTransaction(from base: MergeNode?, to side: MergeNode?) -> TextDiff? {
        let baseData = base?.fileData ?? Data()
        let sideData = side?.fileData ?? Data()
        guard let baseText = String(data: baseData, encoding: .utf8),
              let sideText = String(data: sideData, encoding: .utf8)
        else { return nil }
        let diff = TextDiff.lineBased(from: baseText, to: sideText)
        return diff.hunks.isEmpty ? nil : diff
    }

}
