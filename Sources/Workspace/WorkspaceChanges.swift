import Foundation

/// A single filesystem entry change.
public struct FileChange: Sendable, Codable, Equatable {
    public enum Effect: String, Sendable, Codable {
        case created
        case modified
        case deleted
        case moved
        case copied
    }

    public var path: WorkspacePath
    public var sourcePath: WorkspacePath?
    public var kind: FileTree.Kind
    public var effect: Effect
    public var diff: TextDiff?

    public init(
        path: WorkspacePath,
        sourcePath: WorkspacePath? = nil,
        kind: FileTree.Kind,
        effect: Effect,
        diff: TextDiff? = nil
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.kind = kind
        self.effect = effect
        self.diff = diff
    }
}

/// Why a changed regular file has no textual diff.
public struct TextDiffOmission: Sendable, Codable, Equatable {
    public enum Reason: String, Sendable, Codable {
        case binary
        case sizeLimitExceeded
    }

    public var path: WorkspacePath
    public var reason: Reason

    public init(path: WorkspacePath, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

/// A canonical set of workspace changes shared by previews, mutations, events, revisions, and transactions.
public struct ChangeSet: Sendable, Codable, Equatable {
    public struct Summary: Sendable, Codable, Equatable {
        public var changedPathCount: Int
        public var touchedPaths: [WorkspacePath]
        public var hasTextChanges: Bool
        public var statistics: Statistics

        public init(
            changedPathCount: Int,
            touchedPaths: [WorkspacePath],
            hasTextChanges: Bool,
            statistics: Statistics
        ) {
            self.changedPathCount = changedPathCount
            self.touchedPaths = touchedPaths.sorted()
            self.hasTextChanges = hasTextChanges
            self.statistics = statistics
        }

    }

    public struct Statistics: Sendable, Codable, Equatable {
        public var changedPathCount: Int
        public var changedFileCount: Int
        public var additions: Int
        public var deletions: Int

        public init(changedPathCount: Int, changedFileCount: Int, additions: Int, deletions: Int) {
            self.changedPathCount = changedPathCount
            self.changedFileCount = changedFileCount
            self.additions = additions
            self.deletions = deletions
        }
    }

    public var changes: [FileChange]
    public var textDiffOmissions: [TextDiffOmission]

    public var touchedPaths: [WorkspacePath] {
        Array(Set(changes.flatMap { change in
            if let sourcePath = change.sourcePath {
                [change.path, sourcePath]
            } else {
                [change.path]
            }
        })).sorted()
    }

    public var statistics: Statistics {
        Statistics(
            changedPathCount: touchedPaths.count,
            changedFileCount: changes.count { $0.kind == .file },
            additions: changes.compactMap(\.diff).reduce(0) { $0 + $1.statistics.additions },
            deletions: changes.compactMap(\.diff).reduce(0) { $0 + $1.statistics.deletions }
        )
    }

    public var summary: Summary {
        Summary(
            changedPathCount: statistics.changedPathCount,
            touchedPaths: touchedPaths,
            hasTextChanges: changes.contains { $0.diff != nil },
            statistics: statistics
        )
    }

    public var isEmpty: Bool { changes.isEmpty }

    public init(changes: [FileChange] = [], textDiffOmissions: [TextDiffOmission] = []) {
        self.changes = changes.sorted(by: Self.changeOrder)
        self.textDiffOmissions = textDiffOmissions.sorted { $0.path < $1.path }
    }

    private static func changeOrder(_ lhs: FileChange, _ rhs: FileChange) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.effect != rhs.effect { return lhs.effect.rawValue < rhs.effect.rawValue }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}
