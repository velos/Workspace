import Foundation

/// A request describing a multi-file text replacement operation.
public struct ReplacementRequest: Sendable, Equatable, Codable {
    /// The text matching strategy to apply to each candidate file.
    public enum Pattern: Sendable, Equatable, Codable {
        /// Match a literal substring.
        case literal(String, caseSensitive: Bool = true)
        /// Match a regular expression pattern using Foundation regular expression syntax.
        case regularExpression(String)
    }

    /// The base directory used to resolve relative include and exclude patterns.
    public var scope: WorkspacePath
    /// Glob patterns selecting candidate files.
    public var include: [String]
    /// Glob patterns removed from the include set after expansion.
    public var exclude: [String]
    /// The text matching strategy to apply to each candidate file.
    public var search: Pattern
    /// The replacement string or regular expression template.
    public var replacement: String

    /// Creates a replacement request.
    public init(
        scope: WorkspacePath = .root,
        include: [String],
        exclude: [String] = [],
        search: Pattern,
        replacement: String
    ) {
        self.scope = scope
        self.include = include
        self.exclude = exclude
        self.search = search
        self.replacement = replacement
    }

    /// Creates a replacement request for a single include pattern and a literal search term.
    public init(
        pattern: String,
        search: String,
        replacement: String,
        scope: WorkspacePath = .root,
        exclude: [String] = []
    ) {
        self.init(
            scope: scope,
            include: [pattern],
            exclude: exclude,
            search: .literal(search),
            replacement: replacement
        )
    }

    /// Creates a replacement request for a single include pattern.
    public init(
        pattern: String,
        search: Pattern,
        replacement: String,
        scope: WorkspacePath = .root,
        exclude: [String] = []
    ) {
        self.init(
            scope: scope,
            include: [pattern],
            exclude: exclude,
            search: search,
            replacement: replacement
        )
    }
}

/// The result of a multi-file text replacement operation.
public struct ReplacementResult: Sendable, Codable {
    /// Whether the operation was previewed or executed.
    public var mode: MutationMode
    /// The distinct paths touched by the operation.
    public var touchedPaths: [WorkspacePath]
    /// Per-file change details.
    public var changes: [Change]
    /// Execution failures encountered while applying the replacement.
    public var failures: [Failure]
    /// Whether the operation rolled back after an error.
    public var rolledBack: Bool

    /// A single-file text replacement outcome from ``Workspace/previewReplacement(_:)`` or
    /// ``Workspace/applyReplacement(_:failurePolicy:)``.
    public struct Change: Sendable, Codable {
        /// The file path that was changed.
        public var path: WorkspacePath
        /// The number of replacements applied to the file.
        public var replacements: Int
        /// The execution status of the file change.
        public var status: MutationStatus
        /// A line-based diff describing the text change.
        public var diff: TextDiff

        /// Creates a replacement change value.
        public init(
            path: WorkspacePath,
            replacements: Int,
            status: MutationStatus = .planned,
            diff: TextDiff
        ) {
            self.path = path
            self.replacements = replacements
            self.status = status
            self.diff = diff
        }

        /// Convenience initializer that accepts a string path.
        public init(
            path: String,
            replacements: Int,
            status: MutationStatus = .planned,
            diff: TextDiff
        ) {
            self.init(
                path: WorkspacePath(normalizing: path),
                replacements: replacements,
                status: status,
                diff: diff
            )
        }
    }

    /// A failure encountered while executing a single replacement write.
    public struct Failure: Sendable, Codable {
        /// The path whose replacement write failed.
        public var path: WorkspacePath
        /// A human-readable failure message.
        public var message: String

        /// Creates a replacement failure.
        public init(path: WorkspacePath, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Creates a replacement result.
    public init(
        mode: MutationMode,
        touchedPaths: [WorkspacePath],
        changes: [Change],
        failures: [Failure] = [],
        rolledBack: Bool
    ) {
        self.mode = mode
        self.touchedPaths = touchedPaths
        self.changes = changes
        self.failures = failures
        self.rolledBack = rolledBack
    }
}
