import Foundation

/// A unified workspace event stream value.
public enum WorkspaceEvent: Sendable, Codable, Equatable {
    case changes(ChangeSet)
    case checkpoint(Checkpoint)

    public struct Filter: Sendable, Equatable {
        public var path: WorkspacePath?
        public var recursive: Bool
        public var includeCheckpoints: Bool

        public static let all = Filter()

        public init(path: WorkspacePath? = nil, recursive: Bool = true, includeCheckpoints: Bool = true) {
            self.path = path
            self.recursive = recursive
            self.includeCheckpoints = includeCheckpoints
        }
    }
}

extension Workspace {
    /// Observes workspace changes and checkpoints through one stream.
    public func events(_ filter: WorkspaceEvent.Filter = .all) -> AsyncStream<WorkspaceEvent> {
        let id = UUID()
        var continuation: AsyncStream<WorkspaceEvent>.Continuation?
        let stream = AsyncStream<WorkspaceEvent> { continuation = $0 }
        guard let continuation else { return stream }
        eventWatchers[id] = EventWatcher(filter: filter, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventWatcher(id) }
        }
        if filter.includeCheckpoints {
            ensureCheckpointPolling()
        }
        return stream
    }

    func removeEventWatcher(_ id: UUID) {
        eventWatchers.removeValue(forKey: id)
        let hasCheckpointEventWatcher = eventWatchers.values.contains { $0.filter.includeCheckpoints }
        if !hasCheckpointEventWatcher {
            checkpointPollingTask?.cancel()
            checkpointPollingTask = nil
        }
    }

    func emitWorkspaceEvent(_ event: WorkspaceEvent) {
        for watcher in eventWatchers.values where Self.matches(event, filter: watcher.filter) {
            watcher.continuation.yield(event)
        }
    }

    private static func matches(_ event: WorkspaceEvent, filter: WorkspaceEvent.Filter) -> Bool {
        switch event {
        case .checkpoint:
            return filter.includeCheckpoints
        case let .changes(changes):
            guard let path = filter.path else { return true }
            return changes.touchedPaths.contains { candidate in
                if filter.recursive {
                    return candidate == path || candidate.string.hasPrefix(path.isRoot ? "/" : path.string + "/")
                }
                return candidate == path
            }
        }
    }
}
