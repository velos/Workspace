import Foundation

/// A vendor-neutral JSON value used by tool definitions and adapters.
public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A portable function-tool definition with an ordinary JSON Schema input object.
public struct WorkspaceToolDefinition: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum WorkspaceToolError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownTool(String)
    case invalidArguments(String)

    public var description: String {
        switch self {
        case let .unknownTool(name): "unknown workspace tool: \(name)"
        case let .invalidArguments(message): "invalid workspace tool arguments: \(message)"
        }
    }
}

/// Dependency-free tool definitions and execution over one shared Workspace authority.
public actor WorkspaceToolAdapter {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public nonisolated static let definitions: [WorkspaceToolDefinition] = [
        .init(
            name: "workspace_read",
            description: "Read a UTF-8 file from the current workspace or a checkpoint.",
            inputSchema: .schema(
                properties: [
                    "path": .stringSchema("Absolute workspace path."),
                    "checkpoint_id": .stringSchema("Optional checkpoint UUID."),
                ],
                required: ["path"]
            )
        ),
        .init(
            name: "workspace_glob",
            description: "List workspace paths matching a glob in deterministic order.",
            inputSchema: .schema(
                properties: [
                    "pattern": .stringSchema("Glob pattern."),
                    "current_directory": .stringSchema("Directory used to resolve the pattern."),
                    "checkpoint_id": .stringSchema("Optional checkpoint UUID."),
                ],
                required: ["pattern"]
            )
        ),
        .init(
            name: "workspace_search",
            description: "Search UTF-8 files by literal text or regular expression.",
            inputSchema: .schema(
                properties: [
                    "pattern": .stringSchema("Text or regular expression to find."),
                    "regular_expression": .booleanSchema("Interpret pattern as a regular expression."),
                    "case_sensitive": .booleanSchema("Use case-sensitive literal matching."),
                    "root": .stringSchema("Root directory to search."),
                    "include": .arraySchema(items: .stringSchema("Include glob.")),
                    "exclude": .arraySchema(items: .stringSchema("Exclude glob.")),
                    "context_lines": .integerSchema("Context lines before and after each match."),
                ],
                required: ["pattern"]
            )
        ),
        .init(
            name: "workspace_apply",
            description: "Atomically apply recorded text, directory, removal, copy, or move edits.",
            inputSchema: .schema(
                properties: [
                    "edits": .arraySchema(
                        items: .schema(
                            properties: [
                                "kind": .enumSchema(["write_text", "append_text", "create_directory", "remove", "copy", "move"]),
                                "path": .stringSchema("Target workspace path."),
                                "content": .stringSchema("Text for write_text or append_text."),
                                "source": .stringSchema("Source path for copy or move."),
                                "recursive": .booleanSchema("Recursive directory behavior."),
                            ],
                            required: ["kind", "path"]
                        )
                    ),
                ],
                required: ["edits"]
            )
        ),
        .init(
            name: "workspace_diff",
            description: "Compare checkpoints or current state and return a ChangeSet plus optional unified patch.",
            inputSchema: .schema(
                properties: [
                    "from_checkpoint_id": .stringSchema("Source checkpoint UUID; omit for current state."),
                    "to_checkpoint_id": .stringSchema("Destination checkpoint UUID; omit for current state."),
                    "unified_patch": .booleanSchema("Include git-style textual patch output."),
                    "max_text_bytes": .integerSchema("Maximum bytes per file for text diffing."),
                ]
            )
        ),
        .init(
            name: "workspace_checkpoint",
            description: "Create a checkpoint of the current workspace state.",
            inputSchema: .schema(properties: ["label": .stringSchema("Optional checkpoint label.")])
        ),
    ]

    /// Executes one tool call from a JSON object and returns a JSON-encoded result.
    public func call(name: String, arguments: Data) async throws -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            switch name {
            case "workspace_read":
                let request = try decoder.decode(ReadArguments.self, from: arguments)
                let revision = try request.revision()
                return try encoder.encode(
                    ReadOutput(path: request.path, content: try await workspace.readText(request.path, at: revision))
                )
            case "workspace_glob":
                let request = try decoder.decode(GlobArguments.self, from: arguments)
                return try encoder.encode(
                    try await workspace.glob(
                        request.pattern,
                        currentDirectory: request.currentDirectory ?? .root,
                        at: request.revision()
                    )
                )
            case "workspace_search":
                let request = try decoder.decode(SearchArguments.self, from: arguments)
                return try encoder.encode(try await workspace.search(request.request))
            case "workspace_apply":
                let request = try decoder.decode(ApplyArguments.self, from: arguments)
                return try encoder.encode(try await workspace.apply(try request.edits.map { try $0.edit }))
            case "workspace_diff":
                let request = try decoder.decode(DiffArguments.self, from: arguments)
                let changes = try await workspace.diff(
                    from: try request.revision(request.fromCheckpointID),
                    to: try request.revision(request.toCheckpointID),
                    options: .init(maxTextBytes: request.maxTextBytes ?? DiffOptions.default.maxTextBytes)
                )
                return try encoder.encode(
                    DiffOutput(changes: changes, unifiedPatch: request.unifiedPatch == true ? changes.unifiedPatch() : nil)
                )
            case "workspace_checkpoint":
                let request = try decoder.decode(CheckpointArguments.self, from: arguments)
                return try encoder.encode(try await workspace.createCheckpoint(label: request.label))
            default:
                throw WorkspaceToolError.unknownTool(name)
            }
        } catch let error as WorkspaceToolError {
            throw error
        } catch let error as DecodingError {
            throw WorkspaceToolError.invalidArguments(String(describing: error))
        }
    }
}

private struct ReadArguments: Decodable {
    var path: WorkspacePath
    var checkpointID: String?
    enum CodingKeys: String, CodingKey { case path; case checkpointID = "checkpoint_id" }
    func revision() throws -> Revision { try toolRevision(checkpointID) }
}

private struct ReadOutput: Encodable { var path: WorkspacePath; var content: String }

private struct GlobArguments: Decodable {
    var pattern: String
    var currentDirectory: WorkspacePath?
    var checkpointID: String?
    enum CodingKeys: String, CodingKey {
        case pattern
        case currentDirectory = "current_directory"
        case checkpointID = "checkpoint_id"
    }
    func revision() throws -> Revision { try toolRevision(checkpointID) }
}

private struct SearchArguments: Decodable {
    var pattern: String
    var regularExpression = false
    var caseSensitive = true
    var root: WorkspacePath = .root
    var include: [String] = ["**/*"]
    var exclude: [String] = []
    var contextLines = 0
    enum CodingKeys: String, CodingKey {
        case pattern, root, include, exclude
        case regularExpression = "regular_expression"
        case caseSensitive = "case_sensitive"
        case contextLines = "context_lines"
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decode(String.self, forKey: .pattern)
        regularExpression = try container.decodeIfPresent(Bool.self, forKey: .regularExpression) ?? false
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? true
        root = try container.decodeIfPresent(WorkspacePath.self, forKey: .root) ?? .root
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? ["**/*"]
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        contextLines = try container.decodeIfPresent(Int.self, forKey: .contextLines) ?? 0
    }
    var request: SearchRequest {
        SearchRequest(
            pattern: regularExpression ? .regularExpression(pattern) : .literal(pattern, caseSensitive: caseSensitive),
            files: .init(root: root, include: include, exclude: exclude),
            contextLines: contextLines
        )
    }
}

private struct ApplyArguments: Decodable { var edits: [ToolEdit] }

private struct ToolEdit: Decodable {
    var kind: String
    var path: WorkspacePath
    var content: String?
    var source: WorkspacePath?
    var recursive: Bool?

    var edit: Edit {
        get throws {
            switch kind {
            case "write_text": .writeText(path, try required(content, "content"))
            case "append_text": .appendText(path, try required(content, "content"))
            case "create_directory": .createDirectory(path, recursive: recursive ?? true)
            case "remove": .remove(path, recursive: recursive ?? true)
            case "copy": .copy(from: try required(source, "source"), to: path, recursive: recursive ?? true)
            case "move": .move(from: try required(source, "source"), to: path)
            default: throw WorkspaceToolError.invalidArguments("unsupported edit kind \(kind)")
            }
        }
    }
}

private struct DiffArguments: Decodable {
    var fromCheckpointID: String?
    var toCheckpointID: String?
    var unifiedPatch: Bool?
    var maxTextBytes: Int?
    enum CodingKeys: String, CodingKey {
        case fromCheckpointID = "from_checkpoint_id"
        case toCheckpointID = "to_checkpoint_id"
        case unifiedPatch = "unified_patch"
        case maxTextBytes = "max_text_bytes"
    }
    func revision(_ value: String?) throws -> Revision { try toolRevision(value) }
}

private struct DiffOutput: Encodable { var changes: ChangeSet; var unifiedPatch: String? }
private struct CheckpointArguments: Decodable { var label: String? }

private func toolRevision(_ value: String?) throws -> Revision {
    guard let value else { return .current }
    guard let id = UUID(uuidString: value) else {
        throw WorkspaceToolError.invalidArguments("checkpoint id is not a UUID: \(value)")
    }
    return .checkpoint(id)
}

private func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw WorkspaceToolError.invalidArguments("missing \(name)") }
    return value
}

private extension JSONValue {
    static func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .boolean(false),
        ]
        if !required.isEmpty { value["required"] = .array(required.map(JSONValue.string)) }
        return .object(value)
    }

    static func stringSchema(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    static func booleanSchema(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    static func integerSchema(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
    static func arraySchema(items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }
    static func enumSchema(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }
}
