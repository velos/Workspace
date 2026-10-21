import Foundation

/// A structured line-based diff between two text values.
public struct TextDiff: Sendable, Equatable, Codable {
    /// Aggregate line statistics for the complete values being compared.
    public struct Statistics: Sendable, Equatable, Codable {
        public var originalLineCount: Int
        public var updatedLineCount: Int
        public var additions: Int
        public var deletions: Int

        public init(originalLineCount: Int, updatedLineCount: Int, additions: Int, deletions: Int) {
            self.originalLineCount = originalLineCount
            self.updatedLineCount = updatedLineCount
            self.additions = additions
            self.deletions = deletions
        }
    }

    /// A UTF-16 range suitable for editor and `NSRange` interop.
    public struct IntralineRange: Sendable, Equatable, Codable {
        public var location: Int
        public var length: Int

        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    /// A contiguous diff hunk.
    public struct Hunk: Sendable, Equatable, Codable {
        public var oldStartLine: Int
        public var oldLineCount: Int
        public var newStartLine: Int
        public var newLineCount: Int
        public var lines: [Line]

        public init(
            oldStartLine: Int,
            oldLineCount: Int,
            newStartLine: Int,
            newLineCount: Int,
            lines: [Line]
        ) {
            self.oldStartLine = oldStartLine
            self.oldLineCount = oldLineCount
            self.newStartLine = newStartLine
            self.newLineCount = newLineCount
            self.lines = lines
        }
    }

    /// A single line in a hunk.
    public struct Line: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable {
            case context
            case added
            case removed
        }

        public var kind: Kind
        public var text: String
        public var hasTrailingNewline: Bool
        public var oldLineNumber: Int?
        public var newLineNumber: Int?
        public var intralineRanges: [IntralineRange]

        public init(
            kind: Kind,
            text: String,
            hasTrailingNewline: Bool,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil,
            intralineRanges: [IntralineRange] = []
        ) {
            self.kind = kind
            self.text = text
            self.hasTrailingNewline = hasTrailingNewline
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
            self.intralineRanges = intralineRanges
        }
    }

    public var originalLineCount: Int
    public var updatedLineCount: Int
    public var hunks: [Hunk]

    public var statistics: Statistics {
        Statistics(
            originalLineCount: originalLineCount,
            updatedLineCount: updatedLineCount,
            additions: hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } },
            deletions: hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } }
        )
    }

    public init(originalLineCount: Int, updatedLineCount: Int, hunks: [Hunk]) {
        self.originalLineCount = originalLineCount
        self.updatedLineCount = updatedLineCount
        self.hunks = hunks
    }

    /// Builds a line diff with three context lines and UTF-16 intra-line ranges.
    /// A bounded Myers search retains precise sparse edits even in large files.
    /// When its work or edit-distance limit is reached, the unmatched interior
    /// becomes a coarse replacement. Statistics then describe a nonminimal script.
    public static func lineBased(from originalContent: String, to updatedContent: String) -> TextDiff {
        var work = Work()
        return lineBased(from: originalContent, to: updatedContent, work: &work)
    }

    /// Internal diagnostics keep work limits observable without changing the diff's
    /// public representation, equality, or encoding.
    struct SearchWork {
        var steps = 0
        var editDistance = 0
        var usedTrivialCase = false
        var usedCoarseFallback = false
    }

    struct Work {
        var lines = SearchWork()
        var intralineSearches = 0
        var maximumIntralineSteps = 0
        var intralineFallbacks = 0
    }

    static let maximumSearchSteps = 1_000_000
    static let maximumEditDistance = 1_000

    static func lineBased(from originalContent: String, to updatedContent: String, work: inout Work) -> TextDiff {
        let originalLines = diffLineTokens(in: originalContent)
        if originalContent == updatedContent {
            work.lines.usedTrivialCase = true
            return TextDiff(originalLineCount: originalLines.count, updatedLineCount: originalLines.count, hunks: [])
        }
        let updatedLines = diffLineTokens(in: updatedContent)
        let (removals, insertions) = boundedDifferenceOffsets(from: originalLines, to: updatedLines, work: &work.lines)

        var lines: [Line] = []
        var originalIndex = 0
        var updatedIndex = 0
        var originalLineNumber = 1
        var updatedLineNumber = 1

        while originalIndex < originalLines.count || updatedIndex < updatedLines.count {
            if removals.contains(originalIndex) {
                let token = originalLines[originalIndex]
                lines.append(Line(kind: .removed, text: token.text, hasTrailingNewline: token.hasTrailingNewline,
                                  oldLineNumber: originalLineNumber))
                originalIndex += 1
                originalLineNumber += 1
                continue
            }
            if insertions.contains(updatedIndex) {
                let token = updatedLines[updatedIndex]
                lines.append(Line(kind: .added, text: token.text, hasTrailingNewline: token.hasTrailingNewline,
                                  newLineNumber: updatedLineNumber))
                updatedIndex += 1
                updatedLineNumber += 1
                continue
            }
            guard originalIndex < originalLines.count, updatedIndex < updatedLines.count else { break }
            let updatedLine = updatedLines[updatedIndex]
            lines.append(
                Line(
                    kind: .context,
                    text: updatedLine.text,
                    hasTrailingNewline: updatedLine.hasTrailingNewline,
                    oldLineNumber: originalLineNumber,
                    newLineNumber: updatedLineNumber
                )
            )
            originalIndex += 1
            updatedIndex += 1
            originalLineNumber += 1
            updatedLineNumber += 1
        }

        applyIntralineRanges(to: &lines, work: &work)
        let changedIndices = lines.indices.filter { lines[$0].kind != .context }
        guard !changedIndices.isEmpty else {
            return TextDiff(originalLineCount: originalLines.count, updatedLineCount: updatedLines.count, hunks: [])
        }

        var ranges: [Range<Int>] = []
        for index in changedIndices {
            let lowerBound = max(0, index - 3)
            let upperBound = min(lines.count, index + 4)
            if let last = ranges.last, lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upperBound)
            } else {
                ranges.append(lowerBound..<upperBound)
            }
        }

        let hunks = ranges.map { range in
            let hunkLines = Array(lines[range])
            let originalNumbers = hunkLines.compactMap(\.oldLineNumber)
            let updatedNumbers = hunkLines.compactMap(\.newLineNumber)
            return Hunk(
                oldStartLine: originalNumbers.first ?? 1,
                oldLineCount: originalNumbers.count,
                newStartLine: updatedNumbers.first ?? 1,
                newLineCount: updatedNumbers.count,
                lines: hunkLines
            )
        }
        return TextDiff(
            originalLineCount: originalLines.count,
            updatedLineCount: updatedLines.count,
            hunks: hunks
        )
    }
}

private struct DiffLineToken: Hashable {
    var text: String
    var hasTrailingNewline: Bool
}

private func diffLineTokens(in text: String) -> [DiffLineToken] {
    guard !text.isEmpty else { return [] }
    var tokens: [DiffLineToken] = []
    // CRLF is one Swift Character. Split UTF-8 code units so LF alone is the delimiter,
    // preserving CR in the line's content and distinguishing a terminated final line.
    var contiguous = text
    contiguous.makeContiguousUTF8()
    contiguous.withUTF8 { bytes in
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            tokens.append(DiffLineToken(text: String(decoding: bytes[start..<index], as: UTF8.self), hasTrailingNewline: true))
            start = index + 1
        }
        if start != bytes.count {
            tokens.append(DiffLineToken(text: String(decoding: bytes[start...], as: UTF8.self), hasTrailingNewline: false))
        }
    }
    return tokens
}

private func applyIntralineRanges(to lines: inout [TextDiff.Line], work: inout TextDiff.Work) {
    var index = 0
    while index < lines.count {
        guard lines[index].kind != .context else {
            index += 1
            continue
        }
        let blockStart = index
        while index < lines.count, lines[index].kind != .context { index += 1 }
        let removed = (blockStart..<index).filter { lines[$0].kind == .removed }
        let added = (blockStart..<index).filter { lines[$0].kind == .added }
        for pairIndex in 0..<min(removed.count, added.count) {
            let oldIndex = removed[pairIndex]
            let newIndex = added[pairIndex]
            var pairWork = TextDiff.SearchWork()
            let ranges = characterDifferenceRanges(from: lines[oldIndex].text, to: lines[newIndex].text, work: &pairWork)
            work.intralineSearches += 1
            work.maximumIntralineSteps = max(work.maximumIntralineSteps, pairWork.steps)
            work.intralineFallbacks += pairWork.usedCoarseFallback ? 1 : 0
            lines[oldIndex].intralineRanges = ranges.old
            lines[newIndex].intralineRanges = ranges.new
        }
    }
}

private func characterDifferenceRanges(
    from original: String,
    to updated: String,
    work: inout TextDiff.SearchWork
) -> (old: [TextDiff.IntralineRange], new: [TextDiff.IntralineRange]) {
    let oldCharacters = Array(original)
    let newCharacters = Array(updated)
    let (removed, inserted) = boundedDifferenceOffsets(from: oldCharacters, to: newCharacters, work: &work)

    return (
        collapsedUTF16Ranges(characterOffsets: Array(removed), in: original),
        collapsedUTF16Ranges(characterOffsets: Array(inserted), in: updated)
    )
}

private func collapsedUTF16Ranges(characterOffsets: [Int], in text: String) -> [TextDiff.IntralineRange] {
    guard !characterOffsets.isEmpty else { return [] }
    let characters = Array(text)
    let sorted = Array(Set(characterOffsets)).sorted()
    var characterRanges: [Range<Int>] = []
    for offset in sorted where offset < characters.count {
        if let last = characterRanges.last, offset == last.upperBound {
            characterRanges[characterRanges.count - 1] = last.lowerBound..<(offset + 1)
        } else {
            characterRanges.append(offset..<(offset + 1))
        }
    }
    var utf16Offsets = [0]
    for character in characters { utf16Offsets.append(utf16Offsets.last! + character.utf16.count) }
    return characterRanges.map { range in
        TextDiff.IntralineRange(location: utf16Offsets[range.lowerBound],
                               length: utf16Offsets[range.upperBound] - utf16Offsets[range.lowerBound])
    }
}

/// A Myers forward search with a fixed edit-distance and visited-step budget.
/// Trace layers contain only their active diagonals, bounding trace storage by D²
/// (at most 1,002,001 slots), independently of input size. Prefix/suffix scans and
/// empty-side scripts are linear and do not enter the edit search.
private func boundedDifferenceOffsets<Element: Equatable>(
    from old: [Element], to new: [Element], work: inout TextDiff.SearchWork
) -> (removed: Set<Int>, inserted: Set<Int>) {
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
    var oldEnd = old.count
    var newEnd = new.count
    while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
        oldEnd -= 1
        newEnd -= 1
    }
    let oldCount = oldEnd - prefix
    let newCount = newEnd - prefix
    func replacement() -> (Set<Int>, Set<Int>) { (Set(prefix..<oldEnd), Set(prefix..<newEnd)) }
    guard oldCount > 0, newCount > 0 else {
        work.usedTrivialCase = true
        return replacement()
    }
    // Length imbalance is a lower bound on D, so no search can fit this limit.
    guard abs(oldCount - newCount) <= TextDiff.maximumEditDistance else {
        work.usedCoarseFallback = true
        return replacement()
    }

    var trace: [[Int]] = []
    for depth in 0...min(oldCount + newCount, TextDiff.maximumEditDistance) {
        let previous = trace.last ?? []
        var frontier = Array(repeating: 0, count: depth * 2 + 1)
        for diagonal in stride(from: -depth, through: depth, by: 2) {
            guard work.steps < TextDiff.maximumSearchSteps else {
                work.usedCoarseFallback = true
                return replacement()
            }
            work.steps += 1
            var x: Int
            if depth == 0 {
                x = 0
            } else if diagonal == -depth || (diagonal != depth &&
                previous[diagonal - 1 + depth - 1] < previous[diagonal + 1 + depth - 1]) {
                x = previous[diagonal + 1 + depth - 1]
            } else {
                x = previous[diagonal - 1 + depth - 1] + 1
            }
            var y = x - diagonal
            while x < oldCount, y < newCount {
                guard work.steps < TextDiff.maximumSearchSteps else {
                    work.usedCoarseFallback = true
                    return replacement()
                }
                work.steps += 1
                guard old[prefix + x] == new[prefix + y] else { break }
                x += 1
                y += 1
            }
            frontier[diagonal + depth] = x
            if x >= oldCount, y >= newCount {
                work.editDistance = depth
                var removed: Set<Int> = []
                var inserted: Set<Int> = []
                // Recover the chosen shortest script through earlier frontiers.
                for d in stride(from: depth, through: 1, by: -1) {
                    let previous = trace[d - 1]
                    let k = x - y
                    let previousK: Int
                    if k == -d || (k != d && previous[k - 1 + d - 1] < previous[k + 1 + d - 1]) {
                        previousK = k + 1
                    } else {
                        previousK = k - 1
                    }
                    let previousX = previous[previousK + d - 1]
                    let previousY = previousX - previousK
                    while x > previousX, y > previousY { x -= 1; y -= 1 }
                    if x == previousX {
                        y -= 1
                        inserted.insert(prefix + y)
                    } else {
                        x -= 1
                        removed.insert(prefix + x)
                    }
                }
                return (removed, inserted)
            }
        }
        trace.append(frontier)
    }
    work.usedCoarseFallback = true
    return replacement()
}
