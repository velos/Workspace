import Foundation

/// A normalized absolute path in the workspace's virtual filesystem.
///
/// `WorkspacePath` models shell-style paths independently of the host filesystem so the same value can
/// be used with in-memory, mounted, overlay, and disk-backed filesystems.
public struct WorkspacePath: Sendable, Hashable, Comparable, Codable, ExpressibleByStringLiteral,
    LosslessStringConvertible, CustomStringConvertible
{
    /// The root path, `/`.
    public static let root = WorkspacePath(unchecked: "/")

    private let storage: String

    /// Creates a normalized path from a string literal.
    public init(stringLiteral value: StringLiteralType) {
        self.init(normalizing: value)
    }

    /// Creates a validated and normalized path from a string description.
    ///
    /// Returns `nil` when the input contains unsupported characters such as a null byte.
    public init?(_ description: String) {
        try? self.init(validating: description)
    }

    /// Creates a normalized absolute path from a string, resolving it relative to `currentDirectory`
    /// when the input is not already absolute.
    public init(normalizing path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) {
        storage = Self.normalizedString(path: String(path), currentDirectory: currentDirectory.storage)
    }

    /// Creates a validated and normalized absolute path from a string.
    ///
    /// - Parameters:
    ///   - path: The path text to validate and normalize.
    ///   - currentDirectory: The base path used for relative inputs.
    /// - Throws: ``ShellError/invalidPath(_:)`` when the input contains unsupported characters.
    public init(validating path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) throws {
        let string = String(path)
        if string.contains("\u{0}") {
            throw ShellError.invalidPath(string)
        }
        self.init(normalizing: string, relativeTo: currentDirectory)
    }

    init(unchecked normalizedPath: String) {
        storage = normalizedPath
    }

    /// The normalized path string.
    public var description: String {
        storage
    }

    /// The normalized path string.
    public var string: String {
        storage
    }

    /// A Boolean value indicating whether this path is `/`.
    public var isRoot: Bool {
        storage == Self.root.storage
    }

    /// The path components excluding the leading `/`.
    public var components: [String] {
        Self.splitComponents(storage)
    }

    /// The final path component, or `/` for the root path.
    public var basename: String {
        Self.basename(storage)
    }

    /// The parent directory of the path.
    public var dirname: WorkspacePath {
        Self.dirname(storage)
    }

    /// Returns a new path by appending `component` and normalizing the result.
    public func appending(_ component: some StringProtocol) -> WorkspacePath {
        Self.join(self, String(component))
    }

    /// Orders paths lexicographically by their normalized string values.
    public static func < (lhs: WorkspacePath, rhs: WorkspacePath) -> Bool {
        lhs.storage < rhs.storage
    }

    /// Decodes a path from its string representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(validating: string)
    }

    /// Encodes the normalized path string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    private static func normalizedString(path: String, currentDirectory: String) -> String {
        if path.isEmpty {
            return currentDirectory
        }

        let base: [String]
        if path.hasPrefix("/") {
            base = []
        } else {
            base = splitComponents(currentDirectory)
        }

        var parts = base
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                }
            default:
                parts.append(String(piece))
            }
        }

        return "/" + parts.joined(separator: "/")
    }

    /// Splits an absolute path string into components, excluding the leading `/`.
    public static func splitComponents(_ absolutePath: some StringProtocol) -> [String] {
        String(absolutePath).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Returns the last component of `path`, or `/` for the root path.
    public static func basename(_ path: some StringProtocol) -> String {
        let string = String(path)
        let normalized = string == "/" ? "/" : string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// Returns the parent directory of `path`.
    public static func dirname(_ path: some StringProtocol) -> WorkspacePath {
        let normalized = normalizedString(path: String(path), currentDirectory: "/")
        if normalized == "/" {
            return .root
        }

        var parts = splitComponents(normalized)
        _ = parts.popLast()
        if parts.isEmpty {
            return .root
        }
        return WorkspacePath(unchecked: "/" + parts.joined(separator: "/"))
    }

    /// Joins two path fragments and returns the normalized string result.
    public static func join(_ lhs: some StringProtocol, _ rhs: some StringProtocol) -> String {
        let left = String(lhs)
        let right = String(rhs)
        if right.hasPrefix("/") {
            return normalizedString(path: right, currentDirectory: "/")
        }

        let separator = left.hasSuffix("/") ? "" : "/"
        return normalizedString(path: left + separator + right, currentDirectory: "/")
    }

    /// Joins a base path and a path fragment, returning a normalized ``WorkspacePath``.
    public static func join(_ lhs: WorkspacePath, _ rhs: some StringProtocol) -> WorkspacePath {
        WorkspacePath(unchecked: join(lhs.storage, String(rhs)))
    }

    /// Returns `true` when the token contains glob metacharacters.
    public static func containsGlob(_ token: some StringProtocol) -> Bool {
        let string = String(token)
        return string.contains("*") || string.contains("?") || string.contains("[")
    }

    /// Converts a shell-style glob pattern into an anchored regular expression pattern.
    public static func globToRegex(_ pattern: some StringProtocol) -> String {
        let pattern = String(pattern)
        var regex = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                regex += ".*"
            } else if char == "?" {
                regex += "."
            } else if char == "[" {
                if let closeIndex = pattern[index...].firstIndex(of: "]") {
                    let range = pattern.index(after: index)..<closeIndex
                    regex += "[" + String(pattern[range]) + "]"
                    index = closeIndex
                } else {
                    regex += "\\["
                }
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = pattern.index(after: index)
        }

        regex += "$"
        return regex
    }
}
