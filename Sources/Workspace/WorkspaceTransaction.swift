import Foundation

extension Workspace {
    /// An isolated, long-lived editing session with preview, commit, and discard.
    public actor Transaction {
        public enum CommitStrategy: String, Sendable, Codable {
            case strict
            case threeWay
        }

        public struct Conflict: Sendable, Codable, Equatable {
            public enum Kind: String, Sendable, Codable {
                case bothModified
                case modifiedAndDeleted
                case bothCreated
                case parentChanged
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
            case conflicts([Conflict])
        }

        enum State { case active, committed, discarded }

        public nonisolated let id: UUID
        private let parent: Workspace
        private let draft: Workspace
        private let base: Snapshot
        private let baseCheckpointID: UUID?
        private let label: String?
        private var state: State = .active

        init(parent: Workspace, draft: Workspace, base: Snapshot, baseCheckpointID: UUID?, label: String?) {
            id = UUID()
            self.parent = parent
            self.draft = draft
            self.base = base
            self.baseCheckpointID = baseCheckpointID
            self.label = label
        }

        public func readData(from path: WorkspacePath) async throws -> Data {
            try requireActive()
            return try await draft.readData(from: path)
        }

        public func readText(_ path: WorkspacePath) async throws -> String {
            try requireActive()
            return try await draft.readText(path)
        }

        public func readJSON<T: Decodable & Sendable>(
            _ type: T.Type = T.self,
            from path: WorkspacePath
        ) async throws -> T {
            try requireActive()
            return try await draft.readJSON(type, from: path)
        }

        public func exists(_ path: WorkspacePath) async throws -> Bool {
            try requireActive()
            return await draft.exists(path)
        }

        public func info(_ path: WorkspacePath) async throws -> FileInfo {
            try requireActive()
            return try await draft.info(path)
        }

        public func list(_ path: WorkspacePath) async throws -> [DirectoryEntry] {
            try requireActive()
            return try await draft.list(path)
        }

        public func glob(_ pattern: String, currentDirectory: WorkspacePath = .root) async throws -> [WorkspacePath] {
            try requireActive()
            return try await draft.glob(pattern, currentDirectory: currentDirectory)
        }

        public func tree(at path: WorkspacePath = .root, maxDepth: Int? = nil) async throws -> FileTree {
            try requireActive()
            return try await draft.tree(at: path, maxDepth: maxDepth)
        }

        public func search(_ request: SearchRequest) async throws -> SearchResult {
            try requireActive()
            return try await draft.search(request)
        }

        public func preview(_ edits: [Edit]) async throws -> ChangeSet {
            try requireActive()
            return try await draft.preview(edits)
        }

        @discardableResult
        public func apply(_ edits: [Edit], policy: EditPolicy = .atomic) async throws -> EditResult {
            try requireActive()
            return try await draft.apply(edits, policy: policy)
        }

        @discardableResult
        public func writeText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            try requireActive()
            return try await draft.writeText(path, content)
        }

        @discardableResult
        public func appendText(_ path: WorkspacePath, _ content: String) async throws -> ChangeSet {
            try requireActive()
            return try await draft.appendText(path, content)
        }

        @discardableResult
        public func writeData(_ data: Data, to path: WorkspacePath) async throws -> ChangeSet {
            try requireActive()
            return try await draft.writeData(data, to: path)
        }

        @discardableResult
        public func appendData(_ path: WorkspacePath, _ data: Data) async throws -> ChangeSet {
            try requireActive()
            return try await draft.appendData(path, data)
        }

        @discardableResult
        public func writeJSON<T: Encodable & Sendable>(
            _ value: T,
            to path: WorkspacePath,
            prettyPrinted: Bool = true
        ) async throws -> ChangeSet {
            try requireActive()
            return try await draft.writeJSON(value, to: path, prettyPrinted: prettyPrinted)
        }

        @discardableResult
        public func createDirectory(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            try requireActive()
            return try await draft.createDirectory(path, recursive: recursive)
        }

        @discardableResult
        public func remove(_ path: WorkspacePath, recursive: Bool = true) async throws -> ChangeSet {
            try requireActive()
            return try await draft.remove(path, recursive: recursive)
        }

        @discardableResult
        public func copy(from source: WorkspacePath, to destination: WorkspacePath, recursive: Bool = true)
            async throws -> ChangeSet
        {
            try requireActive()
            return try await draft.copy(from: source, to: destination, recursive: recursive)
        }

        @discardableResult
        public func move(from source: WorkspacePath, to destination: WorkspacePath) async throws -> ChangeSet {
            try requireActive()
            return try await draft.move(from: source, to: destination)
        }

        @discardableResult
        public func createSymbolicLink(_ path: WorkspacePath, target: String) async throws -> ChangeSet {
            try requireActive()
            return try await draft.createSymbolicLink(path, target: target)
        }

        @discardableResult
        public func createHardLink(_ path: WorkspacePath, target: WorkspacePath) async throws -> ChangeSet {
            try requireActive()
            return try await draft.createHardLink(path, target: target)
        }

        @discardableResult
        public func setPermissions(_ permissions: POSIXPermissions, at path: WorkspacePath) async throws -> ChangeSet {
            try requireActive()
            return try await draft.setPermissions(permissions, at: path)
        }

        /// Returns all base-to-draft changes without mutating the parent workspace.
        public func preview() async throws -> ChangeSet {
            try requireActive()
            let current = try await draft.revisionSnapshot(.current)
            return ChangeSet.compare(before: base, after: current, maxTextBytes: 1_000_000)
        }

        /// Attempts to commit this transaction. Conflicted transactions remain active.
        public func commit(strategy: CommitStrategy = .threeWay) async throws -> Commit {
            try requireActive()
            let draftSnapshot = try await draft.revisionSnapshot(.current)
            let result = try await parent.commitTransaction(
                base: base,
                draft: draftSnapshot,
                baseCheckpointID: baseCheckpointID,
                label: label,
                strategy: strategy
            )
            if result.conflicts.isEmpty {
                state = .committed
            }
            return result
        }

        /// Permanently discards the transaction.
        public func discard() throws {
            try requireActive()
            state = .discarded
        }

        private func requireActive() throws {
            guard state == .active else { throw TransactionError.inactive }
        }
    }

    public struct TransactionResult<Value: Sendable>: Sendable {
        public var value: Value
        public var commit: Transaction.Commit
    }

    /// Starts an isolated transaction from the workspace's complete current state.
    public func beginTransaction(label: String? = nil) async throws -> Transaction {
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
        try await ensureLoaded()
        try await reconcileCheckpointsWithStore()
        let current = try await Snapshot.capture(from: filesystem)
        let preview = ChangeSet.compare(before: base, after: draft, maxTextBytes: 1_000_000)

        var baseNodes: [WorkspacePath: MergeNode] = [:]
        var currentNodes: [WorkspacePath: MergeNode] = [:]
        var draftNodes: [WorkspacePath: MergeNode] = [:]
        Self.flattenMergeNodes(base.entry, into: &baseNodes)
        Self.flattenMergeNodes(current.entry, into: &currentNodes)
        Self.flattenMergeNodes(draft.entry, into: &draftNodes)
        baseNodes.removeValue(forKey: .root)
        currentNodes.removeValue(forKey: .root)
        draftNodes.removeValue(forKey: .root)

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
        var conflicts: [Transaction.Conflict] = []
        for path in Set(baseNodes.keys).union(currentNodes.keys).union(draftNodes.keys).sorted() {
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
                conflicts: conflicts
            )
        }

        let rootPermissions: POSIXPermissions = if case let .directory(directory) = current.entry {
            directory.permissions
        } else {
            .defaultDirectory
        }
        let mergedSnapshot = Snapshot(
            rootPath: .root,
            entry: Self.buildEntryTree(from: merged, rootPermissions: rootPermissions)
        )
        let applied = ChangeSet.compare(before: current, after: mergedSnapshot, maxTextBytes: 1_000_000)
        guard !applied.isEmpty else {
            return Transaction.Commit(preview: preview, appliedChanges: applied, checkpoint: nil, conflicts: [])
        }

        do {
            try await Snapshot.restore(mergedSnapshot, to: filesystem)
        } catch {
            try? await Snapshot.restore(current, to: filesystem)
            throw error
        }
        try await appendMutation(operation: .transaction, changes: applied)
        let checkpoint = try await persistCheckpoint(
            snapshot: mergedSnapshot,
            label: label,
            parentCheckpointId: headCheckpointId,
            origin: .transaction(base: baseCheckpointID)
        )
        emitWorkspaceEvent(.changes(applied))
        return Transaction.Commit(preview: preview, appliedChanges: applied, checkpoint: checkpoint, conflicts: [])
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
