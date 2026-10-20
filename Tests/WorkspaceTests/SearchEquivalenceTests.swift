import Foundation
import Testing
@testable import Workspace

struct SearchEquivalenceTests {
    @Test
    func unicodeFileOrderAndFileLimitMatchByteSortedFallback() async throws {
        let root = try TestSupport.temporaryDirectory("SearchByteOrder")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        // UTF-8 puts the decomposed e before f; Swift String ordering puts é
        // after f. Punctuation also exercises the directory name + "/" key.
        let expected: [WorkspacePath] = ["/e\u{301}!", "/e\u{301}.txt", "/e\u{301}/child", "/f"]
        for path in expected.reversed() {
            try await local.createFile(path: path, data: Data("match".utf8))
        }
        let fallback = MountedFileSystem(base: local)
        for fs: any FileSystem in [local, fallback] {
            var paths: [WorkspacePath] = []
            try await fs.walk { info, _, _ in
                if info.kind == .file { paths.append(info.path) }
            }
            #expect(paths == expected)
        }
        for limit in 0...expected.count {
            let request = SearchRequest(pattern: .literal("match"),
                limits: .init(maxFileBytes: 100, maxFiles: limit, maxMatches: 10))
            let scoped = try await Workspace.search(request, on: local)
            let reference = try await Workspace.search(request, on: fallback)
            #expect(scoped == reference)
            #expect(scoped.matches.map(\.path) == Array(expected.prefix(limit)))
            #expect(scoped.truncation == (limit < expected.count ? .fileLimit : nil))
        }
    }

    @Test
    func optimizedSearchMatchesIndependentLineAlgorithm() async throws {
        let root = try TestSupport.temporaryDirectory("SearchEquivalence")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        let samples = [
            "", "\n", "start end", "TODO first\r\nsecond TODO\r\n\r\nTODO",
            "aaaa\naaa\naa\na\n", "ABC abc AbC\nabc\rdef\n",
            "café cafe\u{0301} CAFÉ\nStraße STRASSE\nİ i ı I\nΣ σ ς\n",
            "a\u{0301}a 👩🏽‍💻 é\n終わり\n", "first\nlast", "first\nlast\n",
            "one\rtwo\u{2028}three\u{2029}four\n", String(repeating: "TODO\t\"\\", count: 300),
            "\u{FEFF}abc\nTODO\n", "\u{FEFF}TODO",
            "\u{FEFF}", "\u{FEFF}\u{FEFF}TODO\n", "abc\u{FEFF}TODO",
        ]
        for (index, text) in samples.enumerated() {
            try await local.writeFile(path: WorkspacePath(normalizing: "/f/\(index).txt"), data: Data(text.utf8), append: false)
        }
        try await local.writeFile(path: "/binary", data: Data([97, 0, 98]), append: false)
        try await local.writeFile(path: "/invalid", data: Data([0xff]), append: false)
        try await local.writeFile(path: "/oversized", data: Data(repeating: 65, count: 5_000), append: false)
        let patterns: [TextPattern] = [
            .literal("TODO"), .literal("aa"), .literal("start"), .literal("last"), .literal("\n"),
            .literal("abc", caseSensitive: false), .literal("a"), .literal("é"), .literal("café"),
            .literal("CAFÉ", caseSensitive: false), .literal("strasse", caseSensitive: false),
            .literal("i", caseSensitive: false), .literal("σ", caseSensitive: false), .literal("\u{FEFF}"),
            .regularExpression("TODO|aa"), .regularExpression("a*"), .regularExpression("[a-z]+"), .regularExpression("[[:space:]]+"),
            .regularExpression("^"), .regularExpression("$"), .regularExpression("^.*$"),
            .regularExpression("(?m)^.*$"), .regularExpression("(?s)first.*last"),
            .regularExpression("first\\nlast|last"), .regularExpression("[^x]+"),
            .regularExpression("\\A|\\z"), .regularExpression("(?<=\\n)last|last(?!.)"),
            .regularExpression("\\b\\w+\\b"), .regularExpression(".*"), .regularExpression("[\\t-z]+"),
            .regularExpression("b|"),
        ]
        for pattern in patterns {
            for context in 0...2 {
                for (maxFiles, maxMatches, offset, budget) in [(30, 100, 0, nil as Int?), (8, 2, 1, nil), (30, 4, 1, 1_024), (0, 0, 0, nil)] {
                    let request = SearchRequest(pattern: pattern,
                        files: FileSelection(include: ["**/*", "f/*.txt"], exclude: ["f/3?.txt"]), contextLines: context,
                        limits: .init(maxFileBytes: 4_000, maxFiles: maxFiles, maxMatches: maxMatches, maxOutputBytes: budget),
                        matchOffset: offset)
                    let actual = try await Workspace.search(request, on: local)
                    let expected = try await Self.referenceSearch(request, on: local)
                    #expect(actual == expected, "pattern: \(pattern); context: \(context); limits: \(request.limits)")
                }
            }
        }
    }

    // Frozen pre-optimization algorithm from cad29c4. This intentionally uses
    // independent line Strings and Foundation matching as the compatibility oracle,
    // including pagination, byte budgets, skipped files and context serialization.
    static func referenceSearch(_ request: SearchRequest, on fileSystem: any FileSystem) async throws -> SearchResult {
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
        let allFiles = try await Workspace.selectedFiles(request.files, on: fileSystem)
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
