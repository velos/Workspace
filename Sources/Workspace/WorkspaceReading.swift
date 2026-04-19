import Foundation

/// Read-only view over a ``Workspace``.
///
/// ``History/shared`` and ``History/Session/workspace`` are exposed as `any WorkspaceReading` so that
/// callers cannot accidentally bypass mutation tracking by writing through them. Any code that needs to
/// **mutate** a workspace tracked by ``History`` must go through the corresponding ``History`` or
/// ``History/Session`` API (for example ``History/writeFile(_:content:)`` or
/// ``History/Session/applyEdits(_:failurePolicy:)``).
///
/// All conformances are expected to be safe to share across actors and concurrency domains; the protocol
/// therefore refines `Sendable`. ``Workspace`` itself conforms.
public protocol WorkspaceReading: Sendable {
    /// Reads raw file contents from the workspace.
    func readData(from path: WorkspacePath) async throws -> Data

    /// Reads a UTF-8 file from the workspace.
    func readFile(_ path: WorkspacePath) async throws -> String

    /// Returns whether an entry exists at `path`.
    func exists(_ path: WorkspacePath) async -> Bool

    /// Returns metadata for the entry at `path`.
    func fileInfo(at path: WorkspacePath) async throws -> FileInfo

    /// Lists the direct children of the directory at `path`.
    func listDirectory(at path: WorkspacePath) async throws -> [DirectoryEntry]

    /// Expands a glob pattern relative to `currentDirectory`.
    func glob(_ pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath]

    /// Builds a recursive tree representation for the entry at `path`.
    func walkTree(_ path: WorkspacePath, maxDepth: Int?) async throws -> FileTree

    /// Summarizes the subtree rooted at `path`.
    func summarizeTree(_ path: WorkspacePath, maxDepth: Int?) async throws -> FileTreeSummary

    /// Captures a durable snapshot of the subtree rooted at `path`.
    func captureSnapshot(at path: WorkspacePath) async throws -> Snapshot

    /// Returns a preview of a replacement request without mutating the workspace.
    func previewReplacement(_ request: ReplacementRequest) async throws -> ReplacementResult

    /// Returns a preview of a batch of edits without mutating the workspace.
    func previewEdits(_ edits: [FileEdit]) async throws -> FileEdit.BatchResult

    /// Watches for future changes affecting `path`.
    func watchChanges(at path: WorkspacePath, recursive: Bool) async -> AsyncStream<ChangeEvent>
}

extension WorkspaceReading {
    /// Reads and decodes JSON from a UTF-8 file.
    public func readJSON<T: Decodable>(_ type: T.Type = T.self, from path: WorkspacePath) async throws -> T {
        let data = try await readData(from: path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WorkspaceError.decodingFailed(path, underlying: String(describing: error))
        }
    }

    /// Convenience overload that globs from the workspace root.
    public func glob(_ pattern: String) async throws -> [WorkspacePath] {
        try await glob(pattern, currentDirectory: .root)
    }

    /// Convenience overload that walks the entire subtree at `path`.
    public func walkTree(_ path: WorkspacePath) async throws -> FileTree {
        try await walkTree(path, maxDepth: nil)
    }

    /// Convenience overload that summarizes the entire subtree at `path`.
    public func summarizeTree(_ path: WorkspacePath) async throws -> FileTreeSummary {
        try await summarizeTree(path, maxDepth: nil)
    }

    /// Convenience overload that captures a snapshot of the workspace root.
    public func captureSnapshot() async throws -> Snapshot {
        try await captureSnapshot(at: .root)
    }

    /// Convenience overload that watches recursively.
    public func watchChanges(at path: WorkspacePath) async -> AsyncStream<ChangeEvent> {
        await watchChanges(at: path, recursive: true)
    }
}

extension Workspace: WorkspaceReading {}
