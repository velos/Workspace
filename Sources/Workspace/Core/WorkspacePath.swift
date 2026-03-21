import Foundation

public struct WorkspacePath: Sendable, Hashable, Comparable, Codable, ExpressibleByStringLiteral,
    LosslessStringConvertible, CustomStringConvertible
{
    public static let root = WorkspacePath(unchecked: "/")

    private let storage: String

    public init(stringLiteral value: StringLiteralType) {
        self.init(normalizing: value)
    }

    public init?(_ description: String) {
        try? self.init(validating: description)
    }

    public init(normalizing path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) {
        storage = Self.normalize(path: String(path), currentDirectory: currentDirectory.storage)
    }

    public init(validating path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) throws {
        let string = String(path)
        try Self.validate(string)
        self.init(normalizing: string, relativeTo: currentDirectory)
    }

    init(unchecked normalizedPath: String) {
        storage = normalizedPath
    }

    public var description: String {
        storage
    }

    public var string: String {
        storage
    }

    public var isRoot: Bool {
        storage == Self.root.storage
    }

    public var components: [String] {
        Self.splitComponents(storage)
    }

    public var basename: String {
        Self.basename(storage)
    }

    public var dirname: WorkspacePath {
        Self.dirname(storage)
    }

    public func appending(_ component: some StringProtocol) -> WorkspacePath {
        Self.join(self, String(component))
    }

    public static func < (lhs: WorkspacePath, rhs: WorkspacePath) -> Bool {
        lhs.storage < rhs.storage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(validating: string)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    public static func validate(_ path: some StringProtocol) throws {
        let string = String(path)
        if string.contains("\u{0}") {
            throw ShellError.invalidPath(string)
        }
    }

    public static func normalized(
        _ path: some StringProtocol,
        relativeTo currentDirectory: WorkspacePath = .root
    ) -> WorkspacePath {
        WorkspacePath(normalizing: path, relativeTo: currentDirectory)
    }

    public static func normalize(path: String, currentDirectory: String) -> String {
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

    public static func splitComponents(_ absolutePath: some StringProtocol) -> [String] {
        String(absolutePath).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public static func basename(_ path: some StringProtocol) -> String {
        let string = String(path)
        let normalized = string == "/" ? "/" : string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func dirname(_ path: some StringProtocol) -> WorkspacePath {
        let normalized = normalize(path: String(path), currentDirectory: "/")
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

    public static func join(_ lhs: some StringProtocol, _ rhs: some StringProtocol) -> String {
        let left = String(lhs)
        let right = String(rhs)
        if right.hasPrefix("/") {
            return normalize(path: right, currentDirectory: "/")
        }

        let separator = left.hasSuffix("/") ? "" : "/"
        return normalize(path: left + separator + right, currentDirectory: "/")
    }

    public static func join(_ lhs: WorkspacePath, _ rhs: some StringProtocol) -> WorkspacePath {
        WorkspacePath(unchecked: join(lhs.storage, String(rhs)))
    }

    public static func containsGlob(_ token: some StringProtocol) -> Bool {
        let string = String(token)
        return string.contains("*") || string.contains("?") || string.contains("[")
    }

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

public typealias PathUtils = WorkspacePath
