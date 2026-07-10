import Foundation

public struct SearchRequest: Sendable, Codable, Equatable {
    public struct Limits: Sendable, Codable, Equatable {
        public var maxFileBytes: UInt64
        public var maxFiles: Int
        public var maxMatches: Int

        public static let `default` = Limits(maxFileBytes: 1_000_000, maxFiles: 10_000, maxMatches: 1_000)

        public init(maxFileBytes: UInt64, maxFiles: Int, maxMatches: Int) {
            self.maxFileBytes = maxFileBytes
            self.maxFiles = maxFiles
            self.maxMatches = maxMatches
        }
    }

    public var files: FileSelection
    public var pattern: TextPattern
    public var contextLines: Int
    public var limits: Limits

    public init(
        pattern: TextPattern,
        files: FileSelection = FileSelection(),
        contextLines: Int = 0,
        limits: Limits = .default
    ) {
        self.files = files
        self.pattern = pattern
        self.contextLines = contextLines
        self.limits = limits
    }
}
public struct SearchResult: Sendable, Codable, Equatable {
    public struct ContextLine: Sendable, Codable, Equatable {
        public var number: Int
        public var text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    public struct Match: Sendable, Codable, Equatable {
        public var path: WorkspacePath
        public var lineNumber: Int
        public var line: String
        public var before: [ContextLine]
        public var after: [ContextLine]

        public init(
            path: WorkspacePath,
            lineNumber: Int,
            line: String,
            before: [ContextLine] = [],
            after: [ContextLine] = []
        ) {
            self.path = path
            self.lineNumber = lineNumber
            self.line = line
            self.before = before
            self.after = after
        }
    }

    public struct SkippedFile: Sendable, Codable, Equatable {
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

    public enum Truncation: String, Sendable, Codable {
        case fileLimit
        case matchLimit
    }

    public var matches: [Match]
    public var skippedFiles: [SkippedFile]
    public var searchedFileCount: Int
    public var truncation: Truncation?

    public init(
        matches: [Match],
        skippedFiles: [SkippedFile],
        searchedFileCount: Int,
        truncation: Truncation?
    ) {
        self.matches = matches
        self.skippedFiles = skippedFiles
        self.searchedFileCount = searchedFileCount
        self.truncation = truncation
    }
}

extension Workspace {
    /// Searches UTF-8 regular files in deterministic path and line order.
    public func search(_ request: SearchRequest) async throws -> SearchResult {
        try await Self.search(request, on: filesystem)
    }

    static func search(_ request: SearchRequest, on fileSystem: any FileSystem) async throws -> SearchResult {
        guard request.contextLines >= 0, request.limits.maxFiles >= 0, request.limits.maxMatches >= 0 else {
            throw WorkspaceError.unsupported("search limits and context must not be negative")
        }
        switch request.pattern {
        case let .literal(value, _), let .regularExpression(value):
            guard !value.isEmpty else { throw WorkspaceError.unsupported("search pattern must not be empty") }
        }

        let allFiles = try await selectedFiles(request.files, on: fileSystem)
        let files = Array(allFiles.prefix(request.limits.maxFiles))
        var truncation: SearchResult.Truncation? = allFiles.count > files.count ? .fileLimit : nil
        var matches: [SearchResult.Match] = []
        var skipped: [SearchResult.SkippedFile] = []
        var searchedFileCount = 0
        let regex: NSRegularExpression? = if case let .regularExpression(pattern) = request.pattern {
            try NSRegularExpression(pattern: pattern)
        } else {
            nil
        }

        fileLoop: for path in files {
            let info = try await fileSystem.stat(path: path)
            if info.size > request.limits.maxFileBytes {
                skipped.append(.init(path: path, reason: .sizeLimitExceeded))
                continue
            }
            let data = try await fileSystem.readFile(path: path)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                skipped.append(.init(path: path, reason: .binary))
                continue
            }
            searchedFileCount += 1
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where Self.matches(line, request.pattern, regex: regex) {
                if matches.count >= request.limits.maxMatches {
                    truncation = .matchLimit
                    break fileLoop
                }
                let lower = max(0, index - request.contextLines)
                let upper = min(lines.count, index + request.contextLines + 1)
                let before = (lower..<index).map { SearchResult.ContextLine(number: $0 + 1, text: lines[$0]) }
                let after = ((index + 1)..<upper).map { SearchResult.ContextLine(number: $0 + 1, text: lines[$0]) }
                matches.append(
                    .init(path: path, lineNumber: index + 1, line: line, before: before, after: after)
                )
            }
        }

        return SearchResult(
            matches: matches,
            skippedFiles: skipped.sorted { $0.path < $1.path },
            searchedFileCount: searchedFileCount,
            truncation: truncation
        )
    }

    private static func matches(_ line: String, _ pattern: TextPattern, regex: NSRegularExpression?) -> Bool {
        switch pattern {
        case let .literal(value, caseSensitive):
            return line.range(of: value, options: caseSensitive ? [] : [.caseInsensitive]) != nil
        case .regularExpression:
            guard let regex else { return false }
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
        }
    }
}
