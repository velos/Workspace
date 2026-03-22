import Foundation

// MARK: - Deprecated public type names

@available(*, deprecated, renamed: "WorkspaceError")
public typealias ShellError = WorkspaceError

@available(*, deprecated, renamed: "FileSystem")
public typealias WorkspaceFilesystem = FileSystem

@available(*, deprecated, renamed: "ShellFilesystem")
public typealias ShellFilesystem = FileSystem

@available(*, deprecated, renamed: "FileTree")
public typealias WorkspaceTree = FileTree

@available(*, deprecated, renamed: "FileTreeSummary")
public typealias WorkspaceTreeSummary = FileTreeSummary

@available(*, deprecated, renamed: "FileEdit")
public typealias WorkspaceEdit = FileEdit

@available(*, deprecated, renamed: "PermissionOperation")
public typealias WorkspacePermissionOperation = PermissionOperation

@available(*, deprecated, renamed: "PermissionRequest")
public typealias WorkspacePermissionRequest = PermissionRequest

@available(*, deprecated, renamed: "PermissionDecision")
public typealias WorkspacePermissionDecision = PermissionDecision

@available(*, deprecated, renamed: "PermissionAuthorizing")
public typealias WorkspacePermissionAuthorizing = PermissionAuthorizing

@available(*, deprecated, renamed: "PermissionAuthorizer")
public typealias WorkspacePermissionAuthorizer = PermissionAuthorizer

@available(*, deprecated, renamed: "PermissionedFileSystem")
public typealias PermissionedWorkspaceFilesystem = PermissionedFileSystem

extension FileEdit {
    @available(*, deprecated, renamed: "BatchResult")
    public typealias Result = BatchResult
}
