import Foundation

/// A line-based diff between two text snapshots.
public struct TextDiff: Sendable, Equatable, Codable {
    /// A contiguous hunk in a structured text diff.
    public struct Hunk: Sendable, Equatable, Codable {
        /// The 1-based starting line number in the original content.
        public var oldStartLine: Int
        /// The number of original lines represented in the hunk.
        public var oldLineCount: Int
        /// The 1-based starting line number in the updated content.
        public var newStartLine: Int
        /// The number of updated lines represented in the hunk.
        public var newLineCount: Int
        /// The context and changed lines in the hunk.
        public var lines: [Line]

        /// Creates a diff hunk.
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

    /// A single line in a structured text diff.
    public struct Line: Sendable, Equatable, Codable {
        /// The line classification used within a text diff.
        public enum Kind: String, Sendable, Codable {
            /// A context line that is unchanged between the old and new content.
            case context
            /// A line present only in the new content.
            case added
            /// A line present only in the old content.
            case removed
        }

        /// The role of the line within the diff.
        public var kind: Kind
        /// The line content without a trailing newline character.
        public var text: String
        /// Whether the original line ended with a trailing newline.
        public var hasTrailingNewline: Bool
        /// The original 1-based line number when present.
        public var oldLineNumber: Int?
        /// The updated 1-based line number when present.
        public var newLineNumber: Int?

        /// Creates a diff line.
        public init(
            kind: Kind,
            text: String,
            hasTrailingNewline: Bool,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil
        ) {
            self.kind = kind
            self.text = text
            self.hasTrailingNewline = hasTrailingNewline
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }
    }

    /// The hunks that make up the diff.
    public var hunks: [Hunk]

    /// Creates a text diff.
    public init(hunks: [Hunk]) {
        self.hunks = hunks
    }
}

// MARK: - Line-based diff (shared with ``Workspace`` previews)

extension TextDiff {
    /// A line-based diff between two UTF-8 text blobs, using the same algorithm as
    /// ``Workspace`` replacement and batch-edit previews.
    public static func lineBased(from originalContent: String, to updatedContent: String) -> TextDiff {
        let originalLines = diffLineTokens(in: originalContent)
        let updatedLines = diffLineTokens(in: updatedContent)
        let changes = Array(updatedLines.difference(from: originalLines))

        let removals = Dictionary(grouping: changes.compactMap { change -> (Int, DiffLineToken)? in
            if case let .remove(offset, element, _) = change {
                return (offset, element)
            }
            return nil
        }, by: \.0)

        let insertions = Dictionary(grouping: changes.compactMap { change -> (Int, DiffLineToken)? in
            if case let .insert(offset, element, _) = change {
                return (offset, element)
            }
            return nil
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

            guard originalIndex < originalLines.count, updatedIndex < updatedLines.count else {
                break
            }

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

        let changedIndices = lines.indices.filter { lines[$0].kind != .context }
        guard !changedIndices.isEmpty else {
            return TextDiff(hunks: [])
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
            let originalLineNumbers = hunkLines.compactMap(\.oldLineNumber)
            let updatedLineNumbers = hunkLines.compactMap(\.newLineNumber)
            return Hunk(
                oldStartLine: originalLineNumbers.first ?? 1,
                oldLineCount: originalLineNumbers.count,
                newStartLine: updatedLineNumbers.first ?? 1,
                newLineCount: updatedLineNumbers.count,
                lines: hunkLines
            )
        }

        return TextDiff(hunks: hunks)
    }
}

private struct DiffLineToken: Hashable {
    var text: String
    var hasTrailingNewline: Bool
}

private func diffLineTokens(in text: String) -> [DiffLineToken] {
    guard !text.isEmpty else {
        return []
    }

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
