import Foundation

/// Shared include-union / exclude-subtraction semantics for edits and search.
struct FileSelectionPlan {
    let root: WorkspacePath
    let include: [WorkspacePath]
    let exclude: [WorkspacePath]

    init(_ selection: FileSelection) {
        root = selection.root
        include = selection.include.map { WorkspacePath(normalizing: $0, relativeTo: selection.root) }
        exclude = selection.exclude.map { WorkspacePath(normalizing: $0, relativeTo: selection.root) }
    }

    func paths(on fileSystem: any FileSystem) async throws -> [WorkspacePath] {
        var included = Set<WorkspacePath>()
        for pattern in include {
            included.formUnion(try await fileSystem.glob(pattern: pattern.string, currentDirectory: root))
        }
        for pattern in exclude {
            included.subtract(try await fileSystem.glob(pattern: pattern.string, currentDirectory: root))
        }
        return included.sorted()
    }

    /// Literal includes can follow directory aliases. Keep those, and authorization
    /// decorators' glob checks, on the per-path selection route.
    func walkFilter(on fileSystem: any FileSystem) throws -> Filter? {
        guard !include.isEmpty, fileSystem.supportsScopedWalk,
              include.allSatisfy({ WorkspacePath.containsGlob($0.string) }) else { return nil }
        return try Filter(include: include, exclude: exclude)
    }

    struct Filter {
        private enum Pattern {
            case literal(WorkspacePath)
            case glob(NSRegularExpression)
            init(_ path: WorkspacePath) throws {
                _ = try WorkspacePath(validating: path.string)
                if WorkspacePath.containsGlob(path.string) {
                    self = .glob(try NSRegularExpression(pattern: WorkspacePath.globToRegex(path.string)))
                } else { self = .literal(path) }
            }
            func matches(_ path: WorkspacePath, range: NSRange) -> Bool {
                switch self {
                case let .literal(value): return path == value
                case let .glob(regex): return regex.firstMatch(in: path.string, range: range) != nil
                }
            }
        }
        private let include: [Pattern]
        private let exclude: [Pattern]
        init(include: [WorkspacePath], exclude: [WorkspacePath]) throws {
            self.include = try include.map(Pattern.init)
            self.exclude = try exclude.map(Pattern.init)
        }
        func contains(_ path: WorkspacePath) -> Bool {
            let range = NSRange(path.string.startIndex..., in: path.string)
            return include.contains { $0.matches(path, range: range) }
                && !exclude.contains { $0.matches(path, range: range) }
        }
    }
}
