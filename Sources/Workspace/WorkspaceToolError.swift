import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A model-facing tool failure. Encode this value as the provider's tool-error result.
/// Messages never embed underlying error descriptions or resolved filesystem names.
public struct WorkspaceToolError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Codable {
        case unknownTool = "unknown_tool"
        case invalidArguments = "invalid_arguments"
        case notFound = "not_found"
        case checkpointNotFound = "checkpoint_not_found"
        case notADirectory = "not_a_directory"
        case isADirectory = "is_a_directory"
        case alreadyExists = "already_exists"
        case permissionDenied = "permission_denied"
        case operationNotPermitted = "operation_not_permitted"
        case invalidPath = "invalid_path"
        case illegalByteSequence = "illegal_byte_sequence"
        case limitExceeded = "limit_exceeded"
        case conflict
        case directoryNotEmpty = "directory_not_empty"
        case symlinkLoop = "symlink_loop"
        case unsupported
        case storageCorrupted = "storage_corrupted"
        case rollbackFailed = "rollback_failed"
        case ioError = "io_error"
    }

    public let code: Code
    /// A caller-requested workspace path or scope, which need not name the failing entry.
    /// Resolved targets and stored alias spellings are never substituted here.
    public let path: WorkspacePath?
    public let message: String

    public init(code: Code, path: WorkspacePath? = nil, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(code.rawValue)\(path.map { " at \($0)" } ?? ""): \(message)"
    }

    public static func unknownTool(_ name: String) -> Self {
        let scalars = name.unicodeScalars.prefix(129)
        let prefix = String(String.UnicodeScalarView(scalars.prefix(128)))
        let displayed = prefix + (scalars.count > 128 ? "…" : "")
        return Self(code: .unknownTool, path: nil, message: "Unknown workspace tool: \(displayed).")
    }

    public static func invalidArguments(_ message: String) -> Self {
        Self(code: .invalidArguments, path: nil, message: message)
    }

    static func readConflict(path: WorkspacePath) -> Self {
        Self(code: .conflict, path: path, message: "The file changed during the read; retry this page.")
    }

    init(mapping error: any Error, requestedPaths: [WorkspacePath]) {
        // Never substitute a backend-reported spelling. Even a valid virtual path
        // may disclose a resolved target the caller did not request.
        let candidates = Set(requestedPaths)
        var path = candidates.count == 1 ? candidates.first : nil
        var pathScoped = false
        let code: Code
        let message: String
        switch error {
        case is WorkspaceRollbackError:
            code = .rollbackFailed; message = "The operation failed and the previous state could not be fully restored. Inspect the workspace before retrying."
        case let limit as FileSystemLimitError:
            code = .limitExceeded
            switch limit {
            case let .writeBytes(_, configured):
                message = "The per-write byte limit is \(configured) bytes. Split the write into smaller calls."
            case let .totalBytes(_, configured):
                message = "The total byte limit is \(configured) bytes. Free space before retrying."
            case let .entryCount(_, configured):
                message = "The entry count limit is \(configured). Remove entries before retrying."
            }
        case let workspace as WorkspaceError:
            switch workspace {
            case .invalidPath:
                pathScoped = true
                code = .invalidPath; message = "The path is invalid or resolves outside the workspace."
            case .readOnly, .accessDenied:
                pathScoped = true
                code = .permissionDenied; message = "Workspace access is denied for this operation."
            case let .invalidEncoding(reported):
                pathScoped = true
                if candidates.contains(reported) { path = reported }
                code = .illegalByteSequence; message = "The file is not valid UTF-8 text."
            case .decodingFailed:
                code = .invalidArguments; message = "The file does not contain valid JSON for this operation."
            case .unsupported:
                code = .unsupported; message = "This operation is not supported with these arguments or on this filesystem."
            case .checkpointNotFound, .revisionDataNotFound:
                code = .checkpointNotFound; message = "The requested checkpoint or revision data was not found."
            case .mutationFailed:
                code = .ioError; message = "The workspace mutation could not be recorded."
            case .storageCorrupted:
                code = .storageCorrupted; message = "Workspace revision storage is damaged."
            }
        case is Workspace.Transaction.TransactionError:
            code = .conflict; message = "The transaction conflicts with the current workspace state."
        default:
            let posix = error as NSError
            if posix.domain == NSPOSIXErrorDomain {
                pathScoped = true
                switch posix.code {
                case Int(ENOENT): code = .notFound; message = "The requested file or directory was not found."
                case Int(ENOTDIR): code = .notADirectory; message = "A path component is not a directory."
                case Int(EISDIR): code = .isADirectory; message = "The path is a directory; this operation requires a file."
                case Int(EEXIST): code = .alreadyExists; message = "An entry already exists at the destination."
                case Int(EPERM): code = .operationNotPermitted; message = "The filesystem does not permit this operation on this path."
                case Int(EACCES), Int(EROFS): code = .permissionDenied; message = "Workspace access is denied for this operation."
                case Int(EINVAL), Int(ENAMETOOLONG): code = .invalidPath; message = "The path is invalid for this operation."
                case Int(EILSEQ): code = .illegalByteSequence; message = "The path or content contains an invalid byte sequence."
                case Int(EFBIG), Int(ENOSPC), Int(EDQUOT): pathScoped = false; code = .limitExceeded; message = "The operation exceeds a filesystem size or capacity limit."
                case Int(EBUSY), Int(EAGAIN): code = .conflict; message = "The operation conflicts with the current filesystem state; retry after refreshing."
                case Int(ENOTEMPTY): code = .directoryNotEmpty; message = "The directory is not empty."
                case Int(ELOOP): code = .symlinkLoop; message = "The path contains too many symbolic links or a symbolic link cycle."
                case Int(ENOTSUP): code = .unsupported; message = "The filesystem does not support this operation."
                default: code = .ioError; message = "The workspace filesystem operation failed."
                }
            } else if posix.domain == NSCocoaErrorDomain {
                pathScoped = CocoaError(_nsError: posix).isFileError
                switch posix.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                    code = .notFound; message = "The requested file or directory was not found."
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                    code = .permissionDenied; message = "Workspace access is denied for this operation."
                case NSFileWriteFileExistsError:
                    code = .alreadyExists; message = "An entry already exists at the destination."
                case NSFileReadInvalidFileNameError, NSFileWriteInvalidFileNameError:
                    code = .invalidPath; message = "The path is invalid for this operation."
                case NSFileReadInapplicableStringEncodingError:
                    code = .illegalByteSequence; message = "The file is not valid text in the requested encoding."
                case NSFileWriteOutOfSpaceError:
                    pathScoped = false
                    code = .limitExceeded; message = "The filesystem has insufficient capacity for this operation."
                default:
                    code = .ioError; message = "The workspace filesystem operation failed."
                }
            } else {
                // Backend and persistence errors may contain host paths, policy details,
                // or stored spellings. Never forward their description or userInfo.
                code = .ioError; message = "The workspace operation failed."
            }
        }
        self.init(code: code, path: pathScoped ? path : nil, message: message)
    }
}
