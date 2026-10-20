import Foundation

/// A normalized absolute path in the workspace's virtual filesystem.
///
/// `WorkspacePath` models shell-style paths independently of the host filesystem so the same value can
/// be used with in-memory, mounted, overlay, and disk-backed filesystems.
/// Identity, hashing, ordering, and containment use exact UTF-8 bytes. Case and Unicode
/// normalization are significant: `/café` and `/cafe\u{301}` are different paths.
public struct WorkspacePath: Sendable, Hashable, Comparable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    /// The root path, `/`.
    public static let root = WorkspacePath(unchecked: "/")

    private let storage: String

    /// Creates a normalized path from a string literal.
    public init(stringLiteral value: StringLiteralType) {
        precondition(!value.utf8.contains(0), "workspace path contains a null byte")
        storage = Self.normalizedString(path: value, currentDirectory: Self.root.storage)
    }

    /// Creates a validated, normalized path from dynamic text.
    public init(_ path: String, relativeTo currentDirectory: WorkspacePath = .root) throws {
        if path.utf8.contains(0) {
            throw WorkspaceError.invalidPath(path)
        }
        storage = Self.normalizedString(path: path, currentDirectory: currentDirectory.storage)
    }

    /// Creates a normalized absolute path from a string, resolving it relative to `currentDirectory`
    /// when the input is not already absolute.
    init(normalizing path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) {
        storage = Self.normalizedString(path: String(path), currentDirectory: currentDirectory.storage)
    }

    /// Creates a validated and normalized absolute path from a string.
    ///
    /// - Parameters:
    ///   - path: The path text to validate and normalize.
    ///   - currentDirectory: The base path used for relative inputs.
    /// - Throws: ``WorkspaceError/invalidPath(_:)`` when the input contains unsupported characters.
    init(validating path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) throws {
        let string = String(path)
        if string.utf8.contains(0) {
            throw WorkspaceError.invalidPath(string)
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

    /// Whether this path is equal to or below `ancestor`, comparing exact UTF-8
    /// component bytes, just like WorkspacePath's `==`.
    func isWithin(_ ancestor: WorkspacePath) -> Bool {
        if ancestor.isRoot { return true }
        let bytes = storage.utf8
        let ancestorBytes = ancestor.storage.utf8
        guard bytes.starts(with: ancestorBytes) else { return false }
        let next = bytes.dropFirst(ancestorBytes.count).first
        return next == nil || next == 47
    }

    /// The final path component, or `/` for the root path.
    var basename: String {
        guard !isRoot else { return "/" }
        let slash = storage.utf8.lastIndex(of: 47)!
        return String(decoding: storage.utf8[storage.utf8.index(after: slash)...], as: UTF8.self)
    }

    /// The final path component, or `/` for the root.
    public var name: String { basename }

    /// The parent directory of the path.
    var dirname: WorkspacePath {
        guard let slash = storage.utf8.lastIndex(of: 47), slash != storage.utf8.startIndex else { return .root }
        return WorkspacePath(unchecked: String(decoding: storage.utf8[..<slash], as: UTF8.self))
    }

    /// The containing path. The root is its own parent.
    public var parent: WorkspacePath { dirname }

    /// Returns a new path by appending `component` and normalizing the result.
    public func appending(_ component: some StringProtocol) -> WorkspacePath {
        let component = String(component)
        if !component.isEmpty, component != ".", component != "..", !component.utf8.contains(47) {
            return WorkspacePath(unchecked: (isRoot ? "/" : storage + "/") + component)
        }
        return Self.join(self, component)
    }

    public static func == (lhs: WorkspacePath, rhs: WorkspacePath) -> Bool {
        lhs.storage.utf8.elementsEqual(rhs.storage.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        PathName(storage).hash(into: &hasher)
    }

    /// Orders paths lexicographically by their normalized UTF-8 bytes.
    public static func < (lhs: WorkspacePath, rhs: WorkspacePath) -> Bool {
        lhs.storage.utf8.lexicographicallyPrecedes(rhs.storage.utf8)
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
        if path.utf8.first == 47 {
            base = []
        } else {
            base = splitComponents(currentDirectory)
        }

        var parts = base
        // POSIX separators are bytes, not grapheme clusters. An extending scalar
        // after '/' must not hide a component boundary from resolution.
        for piece in splitComponents(path) {
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

    /// Splits on UTF-8 slash bytes, omitting empty components and preserving `.` and `..`.
    static func splitComponents(_ absolutePath: some StringProtocol) -> [String] {
        absolutePath.utf8.split(separator: 47, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns the last component of `path`, or `/` for the root path.
    static func basename(_ path: some StringProtocol) -> String {
        splitComponents(path).last ?? "/"
    }

    /// Returns the parent directory of `path`.
    static func dirname(_ path: some StringProtocol) -> WorkspacePath {
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
    static func join(_ lhs: some StringProtocol, _ rhs: some StringProtocol) -> String {
        let left = String(lhs)
        let right = String(rhs)
        if right.utf8.first == 47 {
            return normalizedString(path: right, currentDirectory: "/")
        }

        let separator = left.utf8.last == 47 ? "" : "/"
        return normalizedString(path: left + separator + right, currentDirectory: "/")
    }

    /// Joins a base path and a path fragment, returning a normalized ``WorkspacePath``.
    static func join(_ lhs: WorkspacePath, _ rhs: some StringProtocol) -> WorkspacePath {
        WorkspacePath(unchecked: join(lhs.storage, String(rhs)))
    }

    /// Returns `true` when the token contains glob metacharacters.
    static func containsGlob(_ token: some StringProtocol) -> Bool {
        let string = String(token)
        return string.utf8.contains(42) || string.utf8.contains(63) || string.utf8.contains(91)
    }

    /// Converts a shell-style glob pattern into an anchored regular expression pattern.
    ///
    /// `*` and `?` match within a single path component (they never cross `/`), `**` matches any
    /// characters including `/`, and character classes support shell-style negation (`[!abc]`).
    static func globToRegex(_ pattern: some StringProtocol) -> String {
        let pattern = Array(pattern.utf8)
        var regex = Array("^".utf8)
        var index = 0
        func append(_ text: String) { regex.append(contentsOf: text.utf8) }

        while index < pattern.count {
            let byte = pattern[index]
            if byte == 42 { // *
                if index + 1 < pattern.count, pattern[index + 1] == 42 {
                    if index + 2 < pattern.count, pattern[index + 2] == 47 {
                        append("(?:.*/)?")
                        index += 2
                    } else {
                        append(".*")
                        index += 1
                    }
                } else {
                    append("[^/]*")
                }
            } else if byte == 63 { // ?
                append("[^/]")
            } else if byte == 91 { // [
                if let closeIndex = pattern[index...].firstIndex(of: 93), closeIndex > index + 1 {
                    var body = Array(pattern[(index + 1)..<closeIndex])
                    if body.first == 33 { body[0] = 94 } // ! -> ^
                    regex.append(91)
                    regex.append(contentsOf: body)
                    regex.append(93)
                    index = closeIndex
                } else {
                    append("\\[")
                }
            } else if byte < 128 {
                append(NSRegularExpression.escapedPattern(for: String(decoding: [byte], as: UTF8.self)))
            } else {
                regex.append(byte)
            }
            index += 1
        }

        append("$")
        return String(decoding: regex, as: UTF8.self)
    }
}
