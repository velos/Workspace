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
