import Foundation

public enum WorkspacePath {
    public static func validate(_ path: String) throws {
        if path.contains("\u{0}") {
            throw ShellError.invalidPath(path)
        }
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

    public static func splitComponents(_ absolutePath: String) -> [String] {
        absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public static func basename(_ path: String) -> String {
        let normalized = path == "/" ? "/" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func dirname(_ path: String) -> String {
        let normalized = normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return "/"
        }

        var parts = splitComponents(normalized)
        _ = parts.popLast()
        if parts.isEmpty {
            return "/"
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func join(_ lhs: String, _ rhs: String) -> String {
        if rhs.hasPrefix("/") {
            return normalize(path: rhs, currentDirectory: "/")
        }

        let separator = lhs.hasSuffix("/") ? "" : "/"
        return normalize(path: lhs + separator + rhs, currentDirectory: "/")
    }

    public static func containsGlob(_ token: String) -> Bool {
        token.contains("*") || token.contains("?") || token.contains("[")
    }

    public static func globToRegex(_ pattern: String) -> String {
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
