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

/// Dependency-free tool definitions and execution over one shared Workspace authority.
public actor WorkspaceToolAdapter {
    public let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    /// Read pages default to 64 KiB of source bytes, capped at 256 KiB. JSON escaping
    /// can expand content by at most six times, plus the path and fixed metadata.
    public nonisolated static let defaultReadMaxBytes = 65_536
    public nonisolated static let minimumReadMaxBytes = 4
    public nonisolated static let maximumReadMaxBytes = 262_144
    /// Search budgets bound the encoded JSON result, including context and metadata.
    public nonisolated static let defaultSearchMaxBytes = 65_536
    public nonisolated static let minimumSearchMaxBytes = SearchRequest.Limits.minimumOutputBytes
    public nonisolated static let maximumSearchMaxBytes = 262_144
    /// Glob, diff, and apply budgets include JSON escaping and result metadata.
    public nonisolated static let defaultResultMaxBytes = 65_536
    public nonisolated static let minimumResultMaxBytes = 1_024
    public nonisolated static let maximumResultMaxBytes = 262_144
    public nonisolated static let defaultFileDetailMaxBytes = 8_192
    public nonisolated static let maximumFileDetailMaxBytes = 65_536
    public nonisolated static let defaultGlobMaxMatches = 1_000
    public nonisolated static let maximumGlobMaxMatches = 10_000
    private nonisolated static var resultBudgetSchema: JSONValue {
        .integerSchema("Maximum encoded result bytes; default \(defaultResultMaxBytes), minimum \(minimumResultMaxBytes). Larger values clamp to \(maximumResultMaxBytes).", minimum: minimumResultMaxBytes, maximum: maximumResultMaxBytes)
    }
    private nonisolated static var fileBudgetSchema: JSONValue {
        .integerSchema("Maximum encoded diff bytes per file in this result, including optional patch; default \(defaultFileDetailMaxBytes). Larger values clamp to \(maximumFileDetailMaxBytes).", minimum: 0, maximum: maximumFileDetailMaxBytes)
    }
    private nonisolated static let defaultDiffMaxBytes = DiffOptions.default.maxTextBytes ?? Int.max

    public nonisolated static let definitions: [WorkspaceToolDefinition] = [
        .init(
            name: "workspace_read",
            description: "Read a UTF-8 text file from the current workspace or a checkpoint, up to max_bytes per call. If truncated is true, call again with offset set to nextOffset.",
            inputSchema: .schema(
                properties: [
                    "path": .stringSchema("Absolute workspace path."),
                    "offset": .integerSchema("Byte offset; default 0. At/past EOF returns empty content.", minimum: 0),
                    "max_bytes": .integerSchema("Maximum file content bytes per call; default \(defaultReadMaxBytes), minimum \(minimumReadMaxBytes). Larger values clamp to \(maximumReadMaxBytes).", minimum: minimumReadMaxBytes, maximum: maximumReadMaxBytes),
                    "checkpoint_id": .stringSchema("Optional checkpoint UUID."),
                ],
                required: ["path"]
            )
        ),
        .init(
            name: "workspace_glob",
            description: "List matching workspace paths in deterministic order within max_matches and max_bytes. If nextMatchOffset is present, call again with match_offset set to it. Narrow pattern or current_directory to reduce matches.",
            inputSchema: .schema(
                properties: [
                    "pattern": .stringSchema("Glob pattern."),
                    "current_directory": .stringSchema("Directory used to resolve the pattern."),
                    "match_offset": .integerSchema("Matches to skip; default 0. Continue at nextMatchOffset.", minimum: 0),
                    "max_matches": .integerSchema("Maximum matches per page; default \(defaultGlobMaxMatches). Larger values clamp to \(maximumGlobMaxMatches).", minimum: 1, maximum: maximumGlobMaxMatches),
                    "max_bytes": resultBudgetSchema,
                    "checkpoint_id": .stringSchema("Optional checkpoint UUID."),
                ],
                required: ["pattern"]
            )
        ),
        .init(
            name: "workspace_search",
            description: "Search UTF-8 text files by literal text or regular expression in path and line order. If nextMatchOffset is present, call again with match_offset set to it. A match marked truncated was shortened; use workspace_read to read the file for its full text.",
            inputSchema: .schema(
                properties: [
                    "pattern": .stringSchema("Text or regular expression to find."),
                    "regular_expression": .booleanSchema("Interpret pattern as a regular expression."),
                    "case_sensitive": .booleanSchema("Use case-sensitive literal matching."),
                    "root": .stringSchema("Root directory to search."),
                    "include": .arraySchema(items: .stringSchema("Include glob.")),
                    "exclude": .arraySchema(items: .stringSchema("Exclude glob.")),
                    "context_lines": .integerSchema("Context lines on each side; default 0. Larger values clamp to \(SearchRequest.maximumContextLines).", minimum: 0, maximum: SearchRequest.maximumContextLines),
                    "match_offset": .integerSchema("Matching lines to skip; default 0. Continue at nextMatchOffset.", minimum: 0),
                    "max_bytes": .integerSchema("Maximum encoded result size in bytes; default \(defaultSearchMaxBytes), minimum \(minimumSearchMaxBytes). Larger values clamp to \(maximumSearchMaxBytes).", minimum: minimumSearchMaxBytes, maximum: maximumSearchMaxBytes),
                ],
                required: ["pattern"]
            )
        ),
        .init(
            name: "workspace_apply",
            description: "Atomically apply all edits and return bounded ChangeSet detail. Inspect truncated, omittedFiles, and omittedTextDiffs; statistics cover the full effect. Use workspace_read to inspect omitted files, or create a checkpoint before applying and diff from it. Do not repeat edits to retrieve detail.",
            inputSchema: .schema(
                properties: [
                    "max_bytes": resultBudgetSchema,
                    "max_file_bytes": fileBudgetSchema,
                    "edits": .arraySchema(
                        items: .schema(
                            properties: [
                                "kind": .enumSchema(ToolEdit.Kind.allCases.map(\.rawValue)),
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
            description: "Compare revisions and return bounded ChangeSet detail plus optional unified patch. If nextChangeOffset is present, call again with change_offset set to it using the same revisions and paths. Narrow paths or increase max_file_bytes to inspect omitted text; use workspace_read for full file contents. Inspect truncated and omittedFiles. Statistics cover all selected changes with available text diffs.",
            inputSchema: .schema(
                properties: [
                    "max_bytes": resultBudgetSchema,
                    "max_file_bytes": fileBudgetSchema,
                    "change_offset": .integerSchema("Changes to skip; default 0. Continue at nextChangeOffset.", minimum: 0),
                    "paths": .arraySchema(items: .stringSchema("Exact workspace path to include; omit to compare all paths.")),
                    "from_checkpoint_id": .stringSchema("Source checkpoint UUID; omit for current state."),
                    "to_checkpoint_id": .stringSchema("Destination checkpoint UUID; omit for current state."),
                    "unified_patch": .booleanSchema("Include git-style textual patch output."),
                    "max_text_bytes": .integerSchema("Skip text diffing for files larger than this many source bytes; default and cap \(defaultDiffMaxBytes).", minimum: 0, maximum: defaultDiffMaxBytes),
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
        var requestedPaths: [WorkspacePath] = []
        do {
            switch name {
            case "workspace_read":
                let request = try decoder.decode(ReadArguments.self, from: arguments)
                requestedPaths = [request.path]
                let maxBytes = try boundedToolInteger(request.maxBytes, default: Self.defaultReadMaxBytes,
                                                     minimum: Self.minimumReadMaxBytes, maximum: Self.maximumReadMaxBytes, name: "max_bytes")
                let offset = request.offset ?? 0
                let revision = try request.revision()
                let file = try await workspace.resolvedReadableFile(at: request.path, revision: revision)
                let totalBytes = file.size
                let length = offset < totalBytes ? Int(min(UInt64(maxBytes), totalBytes - offset)) : 0
                let read = try await file.readRange(offset, length)
                let data = Data(read.prefix(length))
                var leadingContext = Data()
                if offset > 0, let first = data.first, (0x80...0xBF).contains(first) {
                    let count = Int(min(offset, 3))
                    leadingContext = try await file.readRange(offset - UInt64(count), count)
                }
                let (content, end) = try toolTextPage(data, path: request.path,
                    hasMore: offset < totalBytes && UInt64(data.count) < totalBytes - offset,
                    offset: offset, leadingContext: leadingContext)
                guard end > 0 || offset >= totalBytes else {
                    throw WorkspaceToolError(code: .conflict, path: request.path,
                        message: "The file changed during the read; retry this page.")
                }
                // The read length was bounded by totalBytes - offset, so this cannot overflow.
                let nextOffset = offset + UInt64(end)
                return try encoder.encode(ReadOutput(path: request.path, content: content, offset: offset,
                    nextOffset: nextOffset, totalBytes: totalBytes, truncated: nextOffset < totalBytes))
            case "workspace_glob":
                let request = try decoder.decode(GlobArguments.self, from: arguments)
                requestedPaths = [request.currentDirectory ?? .root]
                let budget = try toolResultBudget(request.maxBytes)
                let offset = try boundedToolInteger(request.matchOffset, default: 0, minimum: 0, maximum: Int.max, name: "match_offset")
                let count = try boundedToolInteger(request.maxMatches, default: Self.defaultGlobMaxMatches, minimum: 1,
                                                  maximum: Self.maximumGlobMaxMatches, name: "max_matches")
                let matches = try await workspace.glob(request.pattern, currentDirectory: request.currentDirectory ?? .root,
                                                       at: request.revision()).sorted()
                return try boundedGlobOutput(matches, offset: offset, maxMatches: count, maxBytes: budget, encoder: encoder)
            case "workspace_search":
                let request = try decoder.decode(SearchArguments.self, from: arguments)
                requestedPaths = [request.root]
                return try encoder.encode(try await workspace.search(request.request()))
            case "workspace_apply":
                let request = try decoder.decode(ApplyArguments.self, from: arguments)
                requestedPaths = request.edits.flatMap { [$0.path] + ($0.source.map { [$0] } ?? []) }
                let budget = try toolResultBudget(request.maxBytes)
                let fileBudget = try toolFileBudget(request.maxFileBytes)
                do {
                    let result = try await workspace.apply(try request.edits.map { try $0.edit })
                    return boundedApplyOutput(result.changes, maxBytes: budget, maxFileBytes: fileBudget, encoder: encoder)
                } catch {
                    if await isSubtreeTransferFailure(error, edits: request.edits) {
                        let failure = WorkspaceToolError(mapping: error, requestedPaths: requestedPaths)
                        throw WorkspaceToolError(code: failure.code, path: failure.path,
                            message: "The destination is inside the source.")
                    }
                    throw error
                }
            case "workspace_diff":
                let request = try decoder.decode(DiffArguments.self, from: arguments)
                let budget = try toolResultBudget(request.maxBytes)
                let fileBudget = try toolFileBudget(request.maxFileBytes)
                let offset = try boundedToolInteger(request.changeOffset, default: 0, minimum: 0, maximum: Int.max, name: "change_offset")
                var changes = try await workspace.diff(
                    from: try request.revision(request.fromCheckpointID),
                    to: try request.revision(request.toCheckpointID),
                    options: .init(maxTextBytes: try boundedToolInteger(request.maxTextBytes, default: Self.defaultDiffMaxBytes,
                        minimum: 0, maximum: Self.defaultDiffMaxBytes, name: "max_text_bytes"))
                )
                if let paths = request.paths {
                    let selected = Set(paths)
                    changes = ChangeSet(changes: changes.changes.filter { selected.contains($0.path) },
                                        textDiffOmissions: changes.textDiffOmissions.filter { selected.contains($0.path) })
                }
                return try boundedChangesOutput(changes, offset: offset, maxBytes: budget, maxFileBytes: fileBudget,
                                                patch: request.unifiedPatch == true, applying: false, encoder: encoder)
            case "workspace_checkpoint":
                let request = try decoder.decode(CheckpointArguments.self, from: arguments)
                return try encoder.encode(try await workspace.createCheckpoint(label: request.label))
            default:
                throw WorkspaceToolError.unknownTool(name)
            }
        } catch let error as WorkspaceToolError {
            throw error
        } catch let error as DecodingError {
            throw toolArgumentError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceToolError(mapping: error, requestedPaths: requestedPaths)
        }
    }

    private func isSubtreeTransferFailure(_ error: any Error, edits: [ToolEdit]) async -> Bool {
        let failure = error as NSError
        guard failure.domain == NSPOSIXErrorDomain, failure.code == Int(POSIXError.Code.EINVAL.rawValue),
              edits.count == 1, let edit = edits.first, edit.kind == .copy || edit.kind == .move,
              let source = edit.source else { return false }
        // A batch can fail on several operations, and EINVAL has other causes.
        // Only specialize an unambiguous transfer with confirmed containment.
        let fs = workspace.fileSystem
        let resolver = FileSystemPathResolver(base: fs)
        let features = await fs.capabilities()
        do {
            let from = try await resolver.resolve(source, features: features, followFinal: false)
            let to = try await resolver.resolve(edit.path, features: features, followFinal: false)
            return to.isWithin(from)
        } catch {
            return false
        }
    }
}

private struct ReadArguments: Decodable {
    var path: WorkspacePath
    var checkpointID: String?
    var offset: UInt64?
    var maxBytes: Int?
    enum CodingKeys: String, CodingKey {
        case path, offset
        case checkpointID = "checkpoint_id"
        case maxBytes = "max_bytes"
    }
    func revision() throws -> Revision { try toolRevision(checkpointID) }
}

private struct ReadOutput: Encodable {
    var path: WorkspacePath
    var content: String
    var offset: UInt64
    var nextOffset: UInt64
    var totalBytes: UInt64
    var truncated: Bool
}

private struct GlobArguments: Decodable {
    var pattern: String
    var currentDirectory: WorkspacePath?
    var checkpointID: String?
    var matchOffset: Int?
    var maxMatches: Int?
    var maxBytes: Int?
    enum CodingKeys: String, CodingKey {
        case matchOffset = "match_offset"
        case maxMatches = "max_matches"
        case maxBytes = "max_bytes"
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
    var matchOffset = 0
    var maxBytes: Int?
    enum CodingKeys: String, CodingKey {
        case pattern, root, include, exclude
        case regularExpression = "regular_expression"
        case caseSensitive = "case_sensitive"
        case contextLines = "context_lines"
        case matchOffset = "match_offset"
        case maxBytes = "max_bytes"
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
        matchOffset = try container.decodeIfPresent(Int.self, forKey: .matchOffset) ?? 0
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes)
    }
    func request() throws -> SearchRequest {
        guard !pattern.isEmpty else { throw WorkspaceToolError.invalidArguments("The pattern must not be empty.") }
        if regularExpression {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { throw WorkspaceToolError.invalidArguments("The pattern must be a valid regular expression.") }
        }
        let context = try boundedToolInteger(contextLines, default: 0, minimum: 0,
            maximum: SearchRequest.maximumContextLines, name: "context_lines")
        let offset = try boundedToolInteger(matchOffset, default: 0, minimum: 0, maximum: Int.max, name: "match_offset")
        let budget = try boundedToolInteger(maxBytes, default: WorkspaceToolAdapter.defaultSearchMaxBytes,
            minimum: WorkspaceToolAdapter.minimumSearchMaxBytes,
            maximum: WorkspaceToolAdapter.maximumSearchMaxBytes, name: "max_bytes")
        var limits = SearchRequest.Limits.default
        limits.maxOutputBytes = budget
        return SearchRequest(
            pattern: regularExpression ? .regularExpression(pattern) : .literal(pattern, caseSensitive: caseSensitive),
            files: .init(root: root, include: include, exclude: exclude),
            contextLines: context,
            limits: limits,
            matchOffset: offset
        )
    }
}

private struct ApplyArguments: Decodable {
    var edits: [ToolEdit]
    var maxBytes: Int?
    var maxFileBytes: Int?
    enum CodingKeys: String, CodingKey {
        case edits
        case maxBytes = "max_bytes"
        case maxFileBytes = "max_file_bytes"
    }
}

private struct ToolEdit: Decodable, Sendable {
    enum Kind: String, Decodable, CaseIterable, Sendable {
        case writeText = "write_text"
        case appendText = "append_text"
        case createDirectory = "create_directory"
        case remove, copy, move

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let kind = Self(rawValue: raw) else {
                let valid = Self.allCases.map(\.rawValue).joined(separator: ", ")
                throw WorkspaceToolError.invalidArguments(
                    "Unsupported value at \(toolCodingPath(decoder.codingPath)); use one of \(valid).")
            }
            self = kind
        }
    }

    var kind: Kind
    var path: WorkspacePath
    var content: String?
    var source: WorkspacePath?
    var recursive: Bool?

    var edit: Edit {
        get throws {
            switch kind {
            case .writeText: .writeText(path, try required(content, "content"))
            case .appendText: .appendText(path, try required(content, "content"))
            case .createDirectory: .createDirectory(path, recursive: recursive ?? true)
            case .remove: .remove(path, recursive: recursive ?? true)
            case .copy: .copy(from: try required(source, "source"), to: path, recursive: recursive ?? true)
            case .move: .move(from: try required(source, "source"), to: path)
            }
        }
    }
}

private struct DiffArguments: Decodable {
    var fromCheckpointID: String?
    var toCheckpointID: String?
    var unifiedPatch: Bool?
    var maxTextBytes: Int?
    var maxBytes: Int?
    var maxFileBytes: Int?
    var changeOffset: Int?
    var paths: [WorkspacePath]?
    enum CodingKeys: String, CodingKey {
        case paths
        case maxBytes = "max_bytes"
        case maxFileBytes = "max_file_bytes"
        case changeOffset = "change_offset"
        case fromCheckpointID = "from_checkpoint_id"
        case toCheckpointID = "to_checkpoint_id"
        case unifiedPatch = "unified_patch"
        case maxTextBytes = "max_text_bytes"
    }
    func revision(_ value: String?) throws -> Revision { try toolRevision(value) }
}

private struct CheckpointArguments: Decodable { var label: String? }

private func toolRevision(_ value: String?) throws -> Revision {
    guard let value else { return .current }
    guard let id = UUID(uuidString: value) else {
        throw WorkspaceToolError.invalidArguments("The checkpoint ID must be a UUID.")
    }
    return .checkpoint(id)
}

// Coding paths contain schema field names and array indexes, never argument values.
// Do not use DecodingError.debugDescription or underlying errors in model output.
private func toolArgumentError(_ error: DecodingError) -> WorkspaceToolError {
    let keys: [any CodingKey]
    let problem: String
    switch error {
    case let .keyNotFound(key, context):
        keys = context.codingPath + [key]
        problem = "Missing required value"
    case let .valueNotFound(_, context):
        keys = context.codingPath
        problem = "Expected a non-null value"
    case let .typeMismatch(type, context):
        keys = context.codingPath
        if type == String.self { problem = "Expected a string" }
        else if type == Bool.self { problem = "Expected a boolean" }
        else if type == Int.self || type == UInt64.self { problem = "Expected an integer" }
        else if type == Double.self { problem = "Expected a number" }
        else if type == [Any].self { problem = "Expected an array" }
        else if type == [String: Any].self { problem = "Expected an object" }
        else { problem = "Expected a value of the required type" }
    case let .dataCorrupted(context):
        keys = context.codingPath
        problem = "Invalid value or malformed JSON"
    @unknown default:
        keys = []
        problem = "Invalid arguments"
    }
    return .invalidArguments("\(problem) at \(toolCodingPath(keys)).")
}

private func toolCodingPath(_ keys: [any CodingKey]) -> String {
    let path = keys.reduce(into: "") { result, key in
        if let index = key.intValue { result += "[\(index)]" }
        else { result += (result.isEmpty ? "" : ".") + key.stringValue }
    }
    return path.isEmpty ? "arguments" : path
}

private func required<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw WorkspaceToolError.invalidArguments("Missing required value at \(name).") }
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
    static func integerSchema(_ description: String, minimum: Int, maximum: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("integer"), "description": .string(description),
                                          "minimum": .number(Double(minimum))]
        if let maximum { value["maximum"] = .number(Double(maximum)) }
        return .object(value)
    }
    static func arraySchema(items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }
    static func enumSchema(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }
}

private func boundedToolInteger(_ value: Int?, default fallback: Int, minimum: Int, maximum: Int, name: String) throws -> Int {
    let value = value ?? fallback
    guard value >= minimum else {
        throw WorkspaceToolError.invalidArguments("The \(name) argument must be at least \(minimum).")
    }
    return min(value, maximum)
}

// Accept a valid prefix ending before one incomplete UTF-8 scalar. Invalid bytes,
// overlong sequences, surrogates and a caller offset inside a scalar remain errors.
private func toolTextPage(
    _ data: Data, path: WorkspacePath, hasMore: Bool, offset: UInt64 = 0, leadingContext: Data = Data()
) throws -> (String, Int) {
    if offset > 0, let first = data.first, (0x80...0xBF).contains(first) {
        let leading = data.prefix { (0x80...0xBF).contains($0) }
        // Verify that these bytes complete a valid character starting before the offset.
        // Orphaned continuation bytes in a malformed file remain invalidEncoding errors.
        if leading.count <= 3, let start = leadingContext.lastIndex(where: { !(0x80...0xBF).contains($0) }),
           String(data: Data(leadingContext[start...]) + leading, encoding: .utf8) != nil {
            // Report invalidEncoding instead if the rest of the page also contains invalid bytes.
            _ = try toolTextPage(Data(data.dropFirst(leading.count)), path: path, hasMore: hasMore)
            throw WorkspaceToolError.invalidArguments(
                "The offset is inside a UTF-8 character; use a nextOffset value from a previous read."
            )
        }
        throw WorkspaceError.invalidEncoding(path)
    }
    if let content = String(data: data, encoding: .utf8) { return (content, data.count) }
    if hasMore {
        for suffixLength in 1...min(3, data.count) {
            let end = data.count - suffixLength
            guard let content = String(data: data.prefix(end), encoding: .utf8) else { continue }
            let tail = Array(data.suffix(suffixLength))
            let first = tail[0]
            let width = (0xC2...0xDF).contains(first) ? 2
                : (0xE0...0xEF).contains(first) ? 3
                : (0xF0...0xF4).contains(first) ? 4 : 0
            guard tail.count < width, tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            if tail.count > 1 {
                let second = tail[1]
                if (first == 0xE0 && second < 0xA0) || (first == 0xED && second > 0x9F)
                    || (first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F) { continue }
            }
            return (content, end)
        }
    }
    throw WorkspaceError.invalidEncoding(path)
}

private func toolResultBudget(_ value: Int?) throws -> Int {
    try boundedToolInteger(value, default: WorkspaceToolAdapter.defaultResultMaxBytes,
                           minimum: WorkspaceToolAdapter.minimumResultMaxBytes,
                           maximum: WorkspaceToolAdapter.maximumResultMaxBytes, name: "max_bytes")
}

private func toolFileBudget(_ value: Int?) throws -> Int {
    try boundedToolInteger(value, default: WorkspaceToolAdapter.defaultFileDetailMaxBytes, minimum: 0,
                           maximum: WorkspaceToolAdapter.maximumFileDetailMaxBytes, name: "max_file_bytes")
}
