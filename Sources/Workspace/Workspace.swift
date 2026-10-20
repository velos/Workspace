import Foundation

/// A high-level API for reading, editing, versioning, and observing a workspace.
public actor Workspace {
    /// Checkpoint and history persistence.
    public enum Persistence: Sendable {
        case memory
        case directory(URL)
    }

    /// Controls content verification for transactions and directory checkpoint capture.
    public enum CheckpointCapturePolicy: Sendable, Equatable {
        /// Reuse matching size and mtime when mtime is over two seconds older than the prior
        /// capture, comparing identity when both entries provide it. Exact-timestamp backends
        /// skip the transaction racy window. Missing mtimes always require reading contents.
        case trustMetadata
        /// Read and verify every file, including changes that preserve older timestamps.
        case verifyContents
    }

    /// Controls only the detail stored in mutation history. Returned edit results,
    /// events, explicit previews, and diffs are independent of this policy and use
    /// `DiffOptions.default` unless the API accepts explicit diff options.
    public enum RecordingPolicy: Sendable, Equatable {
        case full(maxTextBytes: Int?)
        case changesOnly
        case off

        public static let `default` = RecordingPolicy.full(maxTextBytes: 1_000_000)
    }

    /// Bounds the old-content cache used for external-change text diffs.
    public struct ObservationPolicy: Sendable, Equatable {
        public let contentCacheBytes: Int
        /// Zero disables content caching. Negative budgets are treated as zero.
        public init(contentCacheBytes: Int = 32 * 1024 * 1024) {
            self.contentCacheBytes = max(0, contentCacheBytes)
        }
        public static let `default` = ObservationPolicy()
    }

    struct EventWatcher {
        var filter: WorkspaceEvent.Filter
        var continuation: AsyncStream<WorkspaceEvent>.Continuation
    }

    nonisolated let workspaceId: UUID
    public nonisolated var workspaceID: UUID { workspaceId }
    nonisolated let filesystem: any FileSystem
    /// The filesystem that owns this workspace's current state.
    ///
    /// Direct reads are safe. Direct mutations bypass Workspace history, checkpoints, and events;
    /// integrations should use the Workspace edit pipeline when those records are required.
    public nonisolated var fileSystem: any FileSystem { filesystem }
    public nonisolated let recording: RecordingPolicy
    let store: any CheckpointStore
    let checkpointCapture: CheckpointCapturePolicy

    // Actor isolation alone does not span suspension points. Ownership is handed
    // directly to the next waiter, preventing newcomers from overtaking the queue.
    var operationInProgress = false
    var operationWaiters: [CheckedContinuation<Void, Never>] = []

    var loadTask: Task<Void, Error>?
    var didLoadStoreState = false
    var didPrepareStore = false
    var checkpoints: [Checkpoint] = []
    var mutations: [Mutation] = []
    var historyRefreshSequence = 0
    var historyRetractionEpoch = 0
    var deliveredCheckpointEventIDs: Set<UUID> = []
    var headCheckpointId: UUID?
    var eventWatchers: [UUID: EventWatcher] = [:]
    var checkpointObservationTask: Task<Void, Never>?
    var filesystemObservationTask: Task<Void, Never>?
    var observedFilesystem: FilesystemObservation?
    var pendingFilesystemSignal: FileSystemChangeSignal?
    var filesystemRefreshTask: Task<Void, Never>?
    var filesystemRetryMilliseconds = 40
    var filesystemRefreshFailures = 0
    public nonisolated let observation: ObservationPolicy
    var hasBegunTransaction = false
    var transactionBase: TransactionTree?
    var transactionMetadata: MetadataIndex?
    weak var coldTransactionBase: ColdTransactionBase?
    var transactionRoots: Set<WorkspacePath>?
    let usesMemoryPersistence: Bool

    /// Creates a workspace over a filesystem with independent history and capture policies.
    public init(
        workspaceID: UUID = UUID(),
        fileSystem: any FileSystem = InMemoryFileSystem(),
        persistence: Persistence = .memory,
        recording: RecordingPolicy = .default,
        checkpointCapture: CheckpointCapturePolicy = .trustMetadata,
        observation: ObservationPolicy = .default
    ) {
        if case .memory = persistence { usesMemoryPersistence = true } else { usesMemoryPersistence = false }
        self.workspaceId = workspaceID
        self.filesystem = fileSystem
        self.recording = recording
        self.checkpointCapture = checkpointCapture
        self.observation = observation
        self.store = switch persistence {
        case .memory:
            InMemoryCheckpointStore()
        case let .directory(url):
            FileCheckpointStore(rootDirectory: url, checkpointCapture: checkpointCapture)
        }
    }

    /// Reads raw file contents from a workspace revision.
    public func readData(from path: WorkspacePath, at revision: Revision = .current) async throws -> Data {
        switch revision {
        case .current:
            try await filesystem.readFile(path: path)
        case .checkpoint:
            try await revisionData(at: path, revision: revision)
        }
    }

    /// Reads a byte range without loading the whole file when the backing implementation supports it.
    public func readData(
        from path: WorkspacePath,
        at revision: Revision = .current,
        offset: UInt64,
        length: Int? = nil
    ) async throws -> Data {
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        switch revision {
        case .current:
            return try await filesystem.readFile(path: path, offset: offset, length: length)
        case .checkpoint:
            return try await revisionData(at: path, revision: revision, offset: offset, length: length)
        }
    }

    /// Writes raw data, replacing any existing contents.
    @discardableResult
    public func writeData(_ data: Data, to path: WorkspacePath) async throws -> ChangeSet {
        try await apply([.writeData(path, data)]).changes
    }

    /// Reads and decodes JSON from a file.
    public func readJSON<T: Decodable>(
        _ type: T.Type = T.self,
        from path: WorkspacePath,
        at revision: Revision = .current
    ) async throws -> T {
        let data = try await readData(from: path, at: revision)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WorkspaceError.decodingFailed(path, underlying: String(describing: error))
        }
    }

    /// Encodes JSON with a single trailing newline and writes it through the edit pipeline.
    @discardableResult
    public func writeJSON<T: Encodable>(
        _ value: T,
        to path: WorkspacePath,
        prettyPrinted: Bool = true
    ) async throws -> ChangeSet {
        let content = try encodedJSONString(for: value, prettyPrinted: prettyPrinted)
        return try await apply([.writeText(path, content)]).changes
    }

    /// Returns whether an entry exists at a revision.
    public func exists(_ path: WorkspacePath, at revision: Revision = .current) async -> Bool {
        switch revision {
        case .current:
            return await filesystem.exists(path: path)
        case .checkpoint:
            guard let resolved = try? await resolvedRevision(revision) else { return false }
            return resolved.index.entry(at: path) != nil
        }
    }

    /// Expands a glob relative to `currentDirectory` at a revision.
    public func glob(
        _ pattern: String,
        currentDirectory: WorkspacePath = .root,
        at revision: Revision = .current
    ) async throws -> [WorkspacePath] {
        switch revision {
        case .current:
            return try await filesystem.glob(pattern: pattern, currentDirectory: currentDirectory)
        case .checkpoint:
            let resolved = try await resolvedRevision(revision)
            let normalized = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
            if !WorkspacePath.containsGlob(normalized.string) {
                return resolved.index.entry(at: normalized) == nil ? [] : [normalized]
            }
            let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalized.string))
            return Self.indexPaths(resolved.index.entry).filter { path in
                regex.firstMatch(
                    in: path.string,
                    range: NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
                ) != nil
            }.sorted()
        }
    }
}
