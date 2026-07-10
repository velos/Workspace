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
            additions: hunks.flatMap(\.lines).count { $0.kind == .added },
            deletions: hunks.flatMap(\.lines).count { $0.kind == .removed }
        )
    }

    public init(originalLineCount: Int, updatedLineCount: Int, hunks: [Hunk]) {
        self.originalLineCount = originalLineCount
        self.updatedLineCount = updatedLineCount
        self.hunks = hunks
    }

    /// Builds a line diff with three context lines and UTF-16 intra-line ranges.
    public static func lineBased(from originalContent: String, to updatedContent: String) -> TextDiff {
        let originalLines = diffLineTokens(in: originalContent)
        let updatedLines = diffLineTokens(in: updatedContent)
        let changes = Array(updatedLines.difference(from: originalLines))

        let removals = Dictionary(grouping: changes.compactMap { change -> (Int, DiffLineToken)? in
            guard case let .remove(offset, element, _) = change else { return nil }
            return (offset, element)
        }, by: \.0)
        let insertions = Dictionary(grouping: changes.compactMap { change -> (Int, DiffLineToken)? in
            guard case let .insert(offset, element, _) = change else { return nil }
            return (offset, element)
        }, by: \.0)

        var lines: [Line] = []
        var originalIndex = 0
        var updatedIndex = 0
        var originalLineNumber = 1
        var updatedLineNumber = 1

        while originalIndex < originalLines.count || updatedIndex < updatedLines.count {
            if let removed = removals[originalIndex] {
                for (_, token) in removed {
                    lines.append(
                        Line(
                            kind: .removed,
                            text: token.text,
                            hasTrailingNewline: token.hasTrailingNewline,
                            oldLineNumber: originalLineNumber
                        )
                    )
                    originalIndex += 1
                    originalLineNumber += 1
                }
                continue
            }
            if let inserted = insertions[updatedIndex] {
                for (_, token) in inserted {
                    lines.append(
                        Line(
                            kind: .added,
                            text: token.text,
                            hasTrailingNewline: token.hasTrailingNewline,
                            newLineNumber: updatedLineNumber
                        )
                    )
                    updatedIndex += 1
                    updatedLineNumber += 1
                }
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

        applyIntralineRanges(to: &lines)
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
    var current = ""
    for character in text {
        if character == "\n" {
            tokens.append(DiffLineToken(text: current, hasTrailingNewline: true))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty || text.last != "\n" {
        tokens.append(DiffLineToken(text: current, hasTrailingNewline: false))
    }
    return tokens
}

private func applyIntralineRanges(to lines: inout [TextDiff.Line]) {
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
            let ranges = characterDifferenceRanges(from: lines[oldIndex].text, to: lines[newIndex].text)
            lines[oldIndex].intralineRanges = ranges.old
            lines[newIndex].intralineRanges = ranges.new
        }
    }
}

private func characterDifferenceRanges(
    from original: String,
    to updated: String
) -> (old: [TextDiff.IntralineRange], new: [TextDiff.IntralineRange]) {
    let oldCharacters = Array(original)
    let newCharacters = Array(updated)
    let difference = newCharacters.difference(from: oldCharacters)
    let removed = difference.compactMap { change -> Int? in
        guard case let .remove(offset, _, _) = change else { return nil }
        return offset
    }
    let inserted = difference.compactMap { change -> Int? in
        guard case let .insert(offset, _, _) = change else { return nil }
        return offset
    }
    return (
        collapsedUTF16Ranges(characterOffsets: removed, in: original),
        collapsedUTF16Ranges(characterOffsets: inserted, in: updated)
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
    return characterRanges.map { range in
        let prefix = String(characters[..<range.lowerBound])
        let fragment = String(characters[range])
        return TextDiff.IntralineRange(
            location: prefix.utf16.count,
            length: fragment.utf16.count
        )
    }
}
