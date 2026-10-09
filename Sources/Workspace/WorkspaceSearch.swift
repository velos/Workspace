import Foundation

public struct SearchRequest: Sendable, Codable, Equatable {
    public struct Limits: Sendable, Codable, Equatable {
        /// Smallest supported encoded-result budget.
        public static let minimumOutputBytes = 1_024
        /// Space reserved for the result envelope, including all integer digits.
        static let envelopeReserve = 512

        public var maxFileBytes: UInt64
        public var maxFiles: Int
        public var maxMatches: Int
        /// Aggregate compact JSON result budget, including match text, context, and skipped-file metadata.
        /// Nil leaves output unbounded; tool calls supply their own bounded budget.
        public var maxOutputBytes: Int?

        public static let `default` = Limits(maxFileBytes: 1_000_000, maxFiles: 10_000, maxMatches: 1_000)

        public init(maxFileBytes: UInt64, maxFiles: Int, maxMatches: Int, maxOutputBytes: Int? = nil) {
            self.maxFileBytes = maxFileBytes
            self.maxFiles = maxFiles
            self.maxMatches = maxMatches
            self.maxOutputBytes = maxOutputBytes
        }

        private enum CodingKeys: String, CodingKey { case maxFileBytes, maxFiles, maxMatches, maxOutputBytes }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            maxFileBytes = try values.decode(UInt64.self, forKey: .maxFileBytes)
            maxFiles = try values.decode(Int.self, forKey: .maxFiles)
            maxMatches = try values.decode(Int.self, forKey: .maxMatches)
            maxOutputBytes = try values.decodeIfPresent(Int.self, forKey: .maxOutputBytes)
        }
    }

    /// Maximum context on each side is 100 lines; negative requests are rejected.
    public static let maximumContextLines = 100

    public var files: FileSelection
    public var pattern: TextPattern
    public var contextLines: Int
    /// Number of matching lines to skip, for deterministic paging within the selected files.
    public var matchOffset: Int
    public var limits: Limits

    public init(
        pattern: TextPattern,
        files: FileSelection = FileSelection(),
        contextLines: Int = 0,
        limits: Limits = .default,
        matchOffset: Int = 0
    ) {
        self.files = files
        self.pattern = pattern
        self.contextLines = contextLines
        self.limits = limits
        self.matchOffset = matchOffset
    }

    private enum CodingKeys: String, CodingKey { case files, pattern, contextLines, limits, matchOffset }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decode(FileSelection.self, forKey: .files)
        pattern = try values.decode(TextPattern.self, forKey: .pattern)
        contextLines = try values.decode(Int.self, forKey: .contextLines)
        limits = try values.decode(Limits.self, forKey: .limits)
        matchOffset = try values.decodeIfPresent(Int.self, forKey: .matchOffset) ?? 0
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
        /// True when this match's context or line was shortened to fit the output budget.
        /// Use a paged file read for the complete source text.
        public var truncated: Bool
        /// UTF-8 bytes in the full matching line and requested context, before shortening.
        public var totalBytes: UInt64

        public init(
            path: WorkspacePath,
            lineNumber: Int,
            line: String,
            before: [ContextLine] = [],
            after: [ContextLine] = [],
            truncated: Bool = false,
            totalBytes: UInt64? = nil
        ) {
            self.path = path
            self.lineNumber = lineNumber
            self.line = line
            self.before = before
            self.after = after
            self.truncated = truncated
            self.totalBytes = totalBytes ?? (before + after).reduce(UInt64(line.utf8.count)) {
                saturatedByteSum($0, UInt64($1.text.utf8.count))
            }
        }

        private enum CodingKeys: String, CodingKey { case path, lineNumber, line, before, after, truncated, totalBytes }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                path: try values.decode(WorkspacePath.self, forKey: .path),
                lineNumber: try values.decode(Int.self, forKey: .lineNumber),
                line: try values.decode(String.self, forKey: .line),
                before: try values.decode([ContextLine].self, forKey: .before),
                after: try values.decode([ContextLine].self, forKey: .after),
                truncated: try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                totalBytes: try values.decodeIfPresent(UInt64.self, forKey: .totalBytes)
            )
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
        case outputLimit
    }

    public var matches: [Match]
    public var skippedFiles: [SkippedFile]
    public var searchedFileCount: Int
    public var truncation: Truncation?
    public var truncated: Bool { truncation != nil }
    /// Total matching lines across the searched files, excluding binary/oversized files
    /// and files beyond `maxFiles`. Computing this scans every file on every page.
    public var totalMatches: Int
    /// Resume with this match offset. Nil means there are no remaining matching lines
    /// in the searched files; individual shortened matches can still be `truncated`.
    public var nextMatchOffset: Int?

    public init(
        matches: [Match],
        skippedFiles: [SkippedFile],
        searchedFileCount: Int,
        truncation: Truncation?,
        totalMatches: Int? = nil,
        nextMatchOffset: Int? = nil
    ) {
        self.matches = matches
        self.skippedFiles = skippedFiles
        self.searchedFileCount = searchedFileCount
        self.truncation = truncation
        self.totalMatches = totalMatches ?? matches.count
        self.nextMatchOffset = nextMatchOffset
    }

    private enum CodingKeys: String, CodingKey {
        case matches, skippedFiles, searchedFileCount, truncation, truncated, totalMatches, nextMatchOffset
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let matches = try values.decode([Match].self, forKey: .matches)
        self.init(
            matches: matches,
            skippedFiles: try values.decode([SkippedFile].self, forKey: .skippedFiles),
            searchedFileCount: try values.decode(Int.self, forKey: .searchedFileCount),
            truncation: try values.decodeIfPresent(Truncation.self, forKey: .truncation),
            totalMatches: try values.decodeIfPresent(Int.self, forKey: .totalMatches) ?? matches.count,
            nextMatchOffset: try values.decodeIfPresent(Int.self, forKey: .nextMatchOffset)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(matches, forKey: .matches)
        try values.encode(skippedFiles, forKey: .skippedFiles)
        try values.encode(searchedFileCount, forKey: .searchedFileCount)
        try values.encodeIfPresent(truncation, forKey: .truncation)
        try values.encode(truncated, forKey: .truncated)
        try values.encode(totalMatches, forKey: .totalMatches)
        try values.encodeIfPresent(nextMatchOffset, forKey: .nextMatchOffset)
    }
}

extension Workspace {
    /// Searches UTF-8 regular files in deterministic path and line order.
    public func search(_ request: SearchRequest) async throws -> SearchResult {
        try await Self.search(request, on: filesystem)
    }

    static func search(_ request: SearchRequest, on fileSystem: any FileSystem) async throws -> SearchResult {
        guard request.contextLines >= 0, request.limits.maxFiles >= 0,
              request.limits.maxMatches >= 0, request.matchOffset >= 0 else {
            throw WorkspaceError.unsupported("search limits, offset and context must not be negative")
        }
        if let budget = request.limits.maxOutputBytes, budget < SearchRequest.Limits.minimumOutputBytes {
            throw WorkspaceError.unsupported("search output budget must be at least \(SearchRequest.Limits.minimumOutputBytes) bytes")
        }
        switch request.pattern {
        case let .literal(value, _), let .regularExpression(value):
            guard !value.isEmpty else { throw WorkspaceError.unsupported("search pattern must not be empty") }
        }

        let context = min(request.contextLines, SearchRequest.maximumContextLines)
        let allFiles = try await selectedFiles(request.files, on: fileSystem)
        let files = Array(allFiles.prefix(request.limits.maxFiles))
        var truncation: SearchResult.Truncation? = allFiles.count > files.count ? .fileLimit : nil
        var matches: [SearchResult.Match] = []
        var skipped: [SearchResult.SkippedFile] = []
        var searchedFileCount = 0
        var totalMatches = 0
        var pageClosed = false
        // Reserve more than the maximum encoded envelope (including all integer digits).
        // Charge each array element's actual JSON size plus its comma. This bounds escaping,
        // paths, context and skipped-file metadata, rather than just raw text bytes.
        var remaining = request.limits.maxOutputBytes.map { $0 - SearchRequest.Limits.envelopeReserve }
        // Skipped files cannot consume the whole page before its first matching line.
        var skippedRemaining = remaining.map { $0 / 2 }
        let encoder: JSONEncoder? = request.limits.maxOutputBytes.map { _ in
            let encoder = JSONEncoder()
            // Measurement settings must match WorkspaceToolAdapter.call's result encoder.
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }
        let regex: NSRegularExpression? = if case let .regularExpression(pattern) = request.pattern {
            try NSRegularExpression(pattern: pattern)
        } else { nil }

        func recordSkipped(_ path: WorkspacePath, reason: SearchResult.SkippedFile.Reason) throws {
            let value = SearchResult.SkippedFile(path: path, reason: reason)
            guard let encoder, let budget = remaining, let skippedBudget = skippedRemaining else {
                skipped.append(value)
                return
            }
            let cost = try encoder.encode(value).count
            if cost < min(budget, skippedBudget) {
                skipped.append(value)
                remaining = budget - cost - 1
                skippedRemaining = skippedBudget - cost - 1
            } else {
                truncation = .outputLimit
            }
        }

        for path in files {
            let info = try await fileSystem.stat(path: path)
            if info.size > request.limits.maxFileBytes {
                try recordSkipped(path, reason: .sizeLimitExceeded)
                continue
            }
            let readLimit = Int(min(request.limits.maxFileBytes, UInt64(Int.max - 1))) + 1
            let data = try await fileSystem.readFile(path: path, offset: 0, length: readLimit)
            // Recheck actual bytes in case the file grew between stat and read.
            if UInt64(data.count) > request.limits.maxFileBytes {
                try recordSkipped(path, reason: .sizeLimitExceeded)
                continue
            }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                try recordSkipped(path, reason: .binary)
                continue
            }
            searchedFileCount += 1
            let lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            var byteOffsets: [UInt64] = [0]
            for line in lines { byteOffsets.append(byteOffsets.last! + UInt64(line.utf8.count)) }
            for (index, line) in lines.enumerated() where Self.matches(line, request.pattern, regex: regex) {
                // Clamp each distance before arithmetic; no untrusted addition/subtraction.
                let lower = index - min(index, context)
                let upper = index + 1 + min(lines.count - index - 1, context)
                let matchBytes = byteOffsets[upper] - byteOffsets[lower]
                let ordinal = totalMatches
                totalMatches += 1
                guard ordinal >= request.matchOffset, !pageClosed else { continue }
                guard matches.count < request.limits.maxMatches else {
                    truncation = .matchLimit
                    pageClosed = true
                    continue
                }
                var match = SearchResult.Match(
                    path: path, lineNumber: index + 1, line: line,
                    before: (lower..<index).map { .init(number: $0 + 1, text: lines[$0]) },
                    after: ((index + 1)..<upper).map { .init(number: $0 + 1, text: lines[$0]) },
                    truncated: false, totalBytes: matchBytes
                )
                if let encoder, let budget = remaining {
                    var cost = try encoder.encode(match).count
                    if cost >= budget, matches.isEmpty {
                        // Guarantee progress for a single oversized match. Drop context first,
                        // then shorten the line at a UTF-8 boundary; file reads expose the rest.
                        match.truncated = true
                        match.before = []
                        match.after = []
                        cost = try encoder.encode(match).count
                        if cost >= budget {
                            match.line = ""
                            let overhead = try encoder.encode(match).count
                            if overhead < budget - 1 {
                                let bytes = Array(line.utf8.prefix((budget - overhead - 1) / 6))
                                var end = bytes.count
                                while end > 0, String(bytes: bytes[..<end], encoding: .utf8) == nil { end -= 1 }
                                match.line = String(decoding: bytes[..<end], as: UTF8.self)
                                cost = try encoder.encode(match).count
                            } else {
                                throw WorkspaceError.unsupported("search output budget is too small for match metadata at \(path)")
                            }
                        }
                    }
                    guard cost < budget else {
                        truncation = .outputLimit
                        pageClosed = true
                        continue
                    }
                    remaining = budget - cost - 1
                }
                matches.append(match)
                if match.truncated { truncation = .outputLimit }
            }
        }
        // Addition is safe: returned matches are a contiguous subset of totalMatches.
        let consumed = min(request.matchOffset, totalMatches) + matches.count
        return SearchResult(
            matches: matches,
            skippedFiles: skipped.sorted { $0.path < $1.path },
            searchedFileCount: searchedFileCount,
            truncation: truncation,
            totalMatches: totalMatches,
            nextMatchOffset: consumed < totalMatches ? consumed : nil
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

private func saturatedByteSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let sum = lhs.addingReportingOverflow(rhs)
    return sum.overflow ? .max : sum.partialValue
}
