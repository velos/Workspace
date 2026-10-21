import Foundation
import Testing
@testable import Workspace

@Suite("Model-facing tool errors")
struct WorkspaceToolErrorTests {
    struct Failure: Sendable {
        var error: any Error
        var code: WorkspaceToolError.Code
        var pathScoped = false
        var message: String?
    }

    static let failures: [Failure] = {
        let posix: [(Int32, WorkspaceToolError.Code)] = [
            (ENOENT, .notFound), (ENOTDIR, .notADirectory), (EISDIR, .isADirectory),
            (EEXIST, .alreadyExists), (EACCES, .permissionDenied), (EPERM, .operationNotPermitted),
            (EROFS, .permissionDenied), (EINVAL, .invalidPath), (ENAMETOOLONG, .invalidPath),
            (EILSEQ, .illegalByteSequence), (EFBIG, .limitExceeded), (ENOSPC, .limitExceeded),
            (EDQUOT, .limitExceeded), (EBUSY, .conflict), (EAGAIN, .conflict),
            (ENOTEMPTY, .directoryNotEmpty), (ELOOP, .symlinkLoop), (ENOTSUP, .unsupported), (EIO, .ioError),
        ]
        let cocoa: [(Int, WorkspaceToolError.Code)] = [
            (NSFileNoSuchFileError, .notFound), (NSFileReadNoSuchFileError, .notFound),
            (NSFileReadNoPermissionError, .permissionDenied), (NSFileWriteNoPermissionError, .permissionDenied),
            (NSFileWriteVolumeReadOnlyError, .permissionDenied), (NSFileWriteFileExistsError, .alreadyExists),
            (NSFileReadInvalidFileNameError, .invalidPath), (NSFileWriteInvalidFileNameError, .invalidPath),
            (NSFileReadInapplicableStringEncodingError, .illegalByteSequence),
            (NSFileWriteOutOfSpaceError, .limitExceeded), (NSFileReadUnknownError, .ioError),
        ]
        // Underlying messages, userInfo, and even typed paths may contain private names.
        let privateDetails = "/private/host/Stored-Spelling"
        let info = [NSFilePathErrorKey: privateDetails, NSLocalizedDescriptionKey: privateDetails]
        let filesystem = posix.map { Failure(error: NSError(domain: NSPOSIXErrorDomain, code: Int($0.0), userInfo: info), code: $0.1, pathScoped: $0.1 != .limitExceeded) }
            + cocoa.map { Failure(error: NSError(domain: NSCocoaErrorDomain, code: $0.0, userInfo: info), code: $0.1, pathScoped: $0.1 != .limitExceeded) }
        let workspace: [(WorkspaceError, WorkspaceToolError.Code, Bool)] = [
            (.invalidPath(privateDetails), .invalidPath, true), (.readOnly, .permissionDenied, true),
            (.accessDenied(operation: privateDetails, message: privateDetails), .permissionDenied, true),
            (.invalidEncoding("/Stored-Spelling"), .illegalByteSequence, true),
            (.decodingFailed("/Stored-Spelling", underlying: privateDetails), .invalidArguments, false),
            (.unsupported(privateDetails), .unsupported, false), (.checkpointNotFound(UUID()), .checkpointNotFound, false),
            (.revisionDataNotFound(UUID()), .checkpointNotFound, false), (.mutationFailed(privateDetails), .ioError, false),
            (.storageCorrupted(privateDetails), .storageCorrupted, false),
        ]
        return filesystem + workspace.map { Failure(error: $0.0, code: $0.1, pathScoped: $0.2) } + [
            .init(error: FileSystemLimitError.totalBytes(attempted: 200, limit: 123), code: .limitExceeded,
                  message: "The total byte limit is 123 bytes. Free space before retrying."),
            .init(error: FileSystemLimitError.entryCount(attempted: 200, limit: 123), code: .limitExceeded,
                  message: "The entry count limit is 123. Remove entries before retrying."),
            .init(error: FileSystemLimitError.writeBytes(attempted: 200, limit: 123), code: .limitExceeded,
                  message: "The per-write byte limit is 123 bytes. Split the write into smaller calls."),
            .init(error: Workspace.Transaction.TransactionError.conflicts([]), code: .conflict),
            .init(error: Workspace.Transaction.TransactionError.committing, code: .conflict),
            .init(error: Workspace.Transaction.TransactionError.inactive, code: .conflict),
            .init(error: WorkspaceRollbackError(originalError: WorkspaceError.invalidPath(privateDetails),
                                               rollbackError: WorkspaceError.storageCorrupted(privateDetails)), code: .rollbackFailed),
            .init(error: NSError(domain: privateDetails, code: 1, userInfo: info), code: .ioError),
            .init(error: NSError(domain: NSCocoaErrorDomain, code: NSPropertyListReadCorruptError, userInfo: info), code: .ioError),
        ]
    }()

    @Test(arguments: failures)
    func `call maps errors without disclosing backend details`(failure: Failure) async throws {
        let fs = HookableFileSystem()
        try await fs.writeFile(path: "/requested", data: Data([1]), append: false)
        await fs.onRead { _ in throw failure.error }
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        do {
            _ = try await adapter.call(name: "workspace_apply", arguments: Data(#"{"edits":[{"kind":"write_text","path":"/requested","content":"new"}]}"#.utf8))
            Issue.record("expected tool error")
        } catch let error as WorkspaceToolError {
            #expect(error.code == failure.code)
            let expectedPath: WorkspacePath? = failure.pathScoped ? "/requested" : nil
            #expect(error.path == expectedPath)
            if let message = failure.message { #expect(error.message == message) }
            #expect(error.message.first?.isUppercase == true)
            #expect(error.message.hasSuffix("."))
            #expect(!error.message.isEmpty)
            #expect(!error.description.contains("Stored-Spelling"))
            #expect(!error.description.contains("/private/host"))
            let encoded = try JSONEncoder().encode(error)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(json["code"] as? String == failure.code.rawValue)
            #expect(json["path"] as? String == expectedPath?.string)
            #expect(try JSONDecoder().decode(WorkspaceToolError.self, from: encoded) == error)
        }
    }

    @Test
    func `real paths aliases and argument errors remain private`() async throws {
        let root = try TestSupport.temporaryDirectory("ToolErrorPrivacy")
        defer { TestSupport.remove(root) }
        let local = try LocalFileSystem(root: root)
        try await local.writeFile(path: "/Stored-Spelling", data: Data([0xff]), append: false)
        try await local.createSymlink(path: "/requested", target: "Stored-Spelling")
        try await local.createSymlink(path: "/outside", target: root.deletingLastPathComponent().appendingPathComponent("host-secret").path)
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: local))
        for (json, code, path) in [
            (#"{"path":"/requested"}"#, WorkspaceToolError.Code.illegalByteSequence, WorkspacePath("/requested")),
            (#"{"path":"/stored-spelling"}"#, .notFound, "/stored-spelling"),
            (#"{"path":"/outside"}"#, .invalidPath, "/outside"),
            (#"{"path":"/missing"}"#, .notFound, "/missing"),
            (#"{"path":"/Stored-Spelling/child"}"#, .notADirectory, "/Stored-Spelling/child"),
            (#"{"path":"/"}"#, .isADirectory, "/"),
        ] {
            do {
                _ = try await adapter.call(name: "workspace_read", arguments: Data(json.utf8))
                Issue.record("expected tool error")
            } catch let error as WorkspaceToolError {
                #expect(error.code == code)
                #expect(error.path == path)
                #expect(!error.message.contains("Stored-Spelling"))
                #expect(!error.description.contains(root.path))
                #expect(!error.description.contains("host-secret"))
            }
        }
        for (name, arguments, code) in [
            ("missing", "{}", WorkspaceToolError.Code.unknownTool),
            ("workspace_read", #"{"path":3}"#, .invalidArguments),
            ("workspace_search", #"{"pattern":"[","regular_expression":true}"#, .invalidArguments),
            ("workspace_search", #"{"pattern":""}"#, .invalidArguments),
            ("workspace_read", #"{"path":"/bad\u0000path"}"#, .invalidPath),
            ("workspace_apply", #"{"edits":[{"kind":"write_text","path":"/missing-content"}]}"#, .invalidArguments),
        ] {
            do {
                _ = try await adapter.call(name: name, arguments: Data(arguments.utf8))
                Issue.record("expected tool error")
            } catch let error as WorkspaceToolError {
                #expect(error.code == code)
                #expect(error.path == nil)
            }
        }
    }

    @Test(arguments: ["copy", "move"], ["memory", "local", "overlay"])
    func `subtree transfers explain invalid destinations`(kind: String, backend: String) async throws {
        let root = try TestSupport.temporaryDirectory("ToolSubtreeError")
        defer { TestSupport.remove(root) }
        let fs: any FileSystem = switch backend {
        case "local": try LocalFileSystem(root: root)
        case "overlay": OverlayFileSystem(over: InMemoryFileSystem())
        default: InMemoryFileSystem()
        }
        try await fs.createFile(path: "/d/file", data: Data([1]))
        try await fs.createSymlink(path: "/alias", target: "d")
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        for destination in ["/d/new/x", "/alias/new/x"] {
            let arguments = ["edits": [["kind": kind, "source": "/d", "path": destination]]]
            await #expect(throws: WorkspaceToolError(code: .invalidPath,
                message: "The destination is inside the source.")) {
                _ = try await adapter.call(name: "workspace_apply", arguments: JSONEncoder().encode(arguments))
            }
        }
    }

    @Test
    func `unknown tool messages include a bounded requested name`() async throws {
        let adapter = WorkspaceToolAdapter(workspace: Workspace())
        for (name, displayed) in [("workspace_missing", "workspace_missing"),
                                  (String(repeating: "x", count: 1000), String(repeating: "x", count: 128) + "…")] {
            await #expect(throws: WorkspaceToolError(code: .unknownTool,
                message: "Unknown workspace tool: \(displayed).")) {
                _ = try await adapter.call(name: name, arguments: Data("{}".utf8))
            }
        }
    }

    @Test
    func `read shrink reports a retryable conflict at the requested spelling`() async throws {
        let memory = InMemoryFileSystem()
        try await memory.writeFile(path: "/Stored-Spelling", data: Data("before".utf8), append: false)
        try await memory.createSymlink(path: "/requested", target: "Stored-Spelling")
        // Authorization runs after size metadata is obtained and before the range read.
        let authorizer = PermissionAuthorizer { request in
            if request.operation == .readFile {
                try? await memory.writeFile(path: "/Stored-Spelling", data: Data(), append: false)
            }
            return .allow
        }
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: AuthorizedFileSystem(base: memory, authorizer: authorizer)))
        await #expect(throws: WorkspaceToolError(code: .conflict, path: "/requested",
            message: "The file changed during the read; retry this page.")) {
            _ = try await adapter.call(name: "workspace_read", arguments: Data(#"{"path":"/requested"}"#.utf8))
        }
    }

    @Test
    func `missing checkpoints do not blame the requested file`() async throws {
        let workspace = Workspace()
        try await workspace.writeText("/file.txt", "present")
        let adapter = WorkspaceToolAdapter(workspace: workspace)
        let arguments = Data("{\"path\":\"/file.txt\",\"checkpoint_id\":\"\(UUID())\"}".utf8)
        await #expect(throws: WorkspaceToolError(code: .checkpointNotFound,
            message: "The requested checkpoint or revision data was not found.")) {
            _ = try await adapter.call(name: "workspace_read", arguments: arguments)
        }
    }

    @Test(arguments: [
        ("workspace_apply", #"{"edits":[{"path":"/file"}]}"#, "Missing required value at edits[0].kind."),
        ("workspace_read", #"{"path":17}"#, "Expected a string at path."),
        ("workspace_read", #"{"path":null}"#, "Expected a non-null value at path."),
        ("workspace_read", #"{"path":"/file","offset":true}"#, "Expected an integer at offset."),
        ("workspace_read", #"{"path":"/file","checkpoint_id":"secret-invalid-id"}"#, "The checkpoint ID must be a UUID."),
        ("workspace_apply", #"{"edits":[{"path":"/file","kind":"secret-invalid-kind"}]}"#, "Unsupported value at edits[0].kind; use one of write_text, append_text, create_directory, remove, copy, move."),
    ])
    func `argument diagnostics identify fields without values`(tool: String, arguments: String, message: String) async throws {
        let adapter = WorkspaceToolAdapter(workspace: Workspace())
        await #expect(throws: WorkspaceToolError.invalidArguments(message)) {
            _ = try await adapter.call(name: tool, arguments: Data(arguments.utf8))
        }
    }

    @Test(arguments: ["workspace_glob", "workspace_search"], [false, true])
    func `glob and search root denials report only the requested root`(tool: String, explicitRoot: Bool) async throws {
        let authorizer = PermissionAuthorizer { request in
            .deny(message: "Private policy details for \(request.path?.string ?? "no path"): /Stored-Spelling")
        }
        let fs = AuthorizedFileSystem(base: InMemoryFileSystem(), authorizer: authorizer)
        let adapter = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        let rootKey = tool == "workspace_glob" ? "current_directory" : "root"
        let pattern = tool == "workspace_glob" ? "**/*" : "needle"
        var arguments = ["pattern": pattern]
        if explicitRoot { arguments[rootKey] = "/requested" }
        do {
            _ = try await adapter.call(name: tool, arguments: JSONEncoder().encode(arguments))
            Issue.record("expected policy denial")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .permissionDenied)
            #expect(error.path == (explicitRoot ? "/requested" : "/"))
            #expect(error.message == "Workspace access is denied for this operation.")
            #expect(!error.description.contains("Stored-Spelling"))
            #expect(!error.description.contains("Private policy"))
        }
    }

    @Test
    func `batch failures omit an ambiguous path and cancellation stays cancellation`() async throws {
        let adapter = WorkspaceToolAdapter(workspace: Workspace())
        do {
            _ = try await adapter.call(name: "workspace_apply", arguments: Data(#"{"edits":[{"kind":"write_text","path":"/new/file","content":"ok"},{"kind":"copy","source":"/missing","path":"/copy"}]}"#.utf8))
            Issue.record("expected missing source")
        } catch let error as WorkspaceToolError {
            #expect(error.code == .notFound)
            #expect(error.path == nil)
        }
        #expect(!(await adapter.workspace.fileSystem.exists(path: "/new")))
        let fs = HookableFileSystem()
        try await fs.writeFile(path: "/file", data: Data([1]), append: false)
        await fs.onRead { _ in throw CancellationError() }
        let cancellable = WorkspaceToolAdapter(workspace: Workspace(fileSystem: fs))
        await #expect(throws: CancellationError.self) {
            _ = try await cancellable.call(name: "workspace_apply", arguments: Data(#"{"edits":[{"kind":"write_text","path":"/file","content":"new"}]}"#.utf8))
        }
    }
}
