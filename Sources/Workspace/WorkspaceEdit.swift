import Foundation

/// A reusable file selection shared by search and replacement.
public struct FileSelection: Sendable, Codable, Equatable {
    public var root: WorkspacePath
    public var include: [String]
    public var exclude: [String]

    public init(
        root: WorkspacePath = .root,
        include: [String] = ["**/*"],
        exclude: [String] = []
    ) {
        self.root = root
        self.include = include
        self.exclude = exclude
    }
}
/// A literal or Foundation regular-expression text pattern.
public enum TextPattern: Sendable, Codable, Equatable {
    case literal(String, caseSensitive: Bool = true)
    case regularExpression(String)
}

/// A filesystem mutation command.
public enum Edit: Sendable, Codable, Equatable {
    case writeText(WorkspacePath, String)
    case appendText(WorkspacePath, String)
    case writeData(WorkspacePath, Data)
    case appendData(WorkspacePath, Data)
    case createDirectory(WorkspacePath, recursive: Bool = true)
    case remove(WorkspacePath, recursive: Bool = true)
    case copy(from: WorkspacePath, to: WorkspacePath, recursive: Bool = true)
    case move(from: WorkspacePath, to: WorkspacePath)
    case createSymbolicLink(WorkspacePath, target: String)
    case createHardLink(WorkspacePath, target: WorkspacePath)
    case setPermissions(WorkspacePath, POSIXPermissions)
    case replace(files: FileSelection, pattern: TextPattern, with: String)
}

/// Failure behavior for a multi-edit application.
public enum EditPolicy: String, Sendable, Codable {
    case atomic
    case stopOnError
    case continueAfterError
}

public struct EditFailure: Sendable, Codable, Equatable {
    public var index: Int
    public var edit: Edit
    public var message: String

    public init(index: Int, edit: Edit, message: String) {
        self.index = index
        self.edit = edit
        self.message = message
    }
}

public struct EditResult: Sendable, Codable, Equatable {
    public var changes: ChangeSet
    public var failures: [EditFailure]

    public init(changes: ChangeSet, failures: [EditFailure] = []) {
        self.changes = changes
        self.failures = failures
    }
}
