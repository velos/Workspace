import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Visits are serial and postorder; regular files are in path order. Links are visited,
/// never descended into. A missing root produces no visits. Read callbacks are
/// nonescaping and valid only during their visit. This is a live read-only walk,
/// not an atomic snapshot: errors from children disappearing during enumeration or
/// reads propagate. The caller can skip children missing at their metadata lookup
/// (ENOENT/ENOTDIR), independently of skipping unreadable directories. Read errors
/// after metadata always propagate. Local scoped no-follow opens reject substitutions
/// with symlinks, even
/// when the replacement link points inside the root. Very deep local subtrees fall
/// back to ordinary per-path operations with a root identity check at the handoff.
///
/// This optional package capability accelerates traversal while authorization
/// decorators retain per-entry checks through per-path operations.
package protocol TraversingFileSystem: FileSystem {
    /// Forwarders return false when their base needs the per-path fallback.
    var supportsScopedWalk: Bool { get }
    nonisolated(nonsending) func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool,
              visit: FileSystemWalkVisitor) async throws
}

package typealias FileSystemWalkVisitor = @isolated(any) (
    _ info: FileInfo,
    _ read: @Sendable (_ length: Int?) async throws -> Data,
    _ readLink: @Sendable () async throws -> String
) async throws -> Void

extension TraversingFileSystem {
    package var supportsScopedWalk: Bool { true }
}

extension FileSystem {
    package var supportsScopedWalk: Bool {
        (self as? any TraversingFileSystem)?.supportsScopedWalk ?? false
    }
    nonisolated(nonsending) package func walk(at path: WorkspacePath = .root, skippingUnreadableDirectories: Bool = false,
        skippingVanishedEntries: Bool = false,
                      visit: FileSystemWalkVisitor) async throws {
        if let traversal = self as? any TraversingFileSystem {
            try await traversal.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
                skippingVanishedEntries: skippingVanishedEntries, visit: visit)
        } else {
            try await walkUsingPaths(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
                skippingVanishedEntries: skippingVanishedEntries, visit: visit)
        }
    }

    // In particular, never unwrap AuthorizedFileSystem here: each stat, listing and
    // requested content read must pass through its normal per-entry checks.
    nonisolated(nonsending) package func walkUsingPaths(at path: WorkspacePath, skippingUnreadableDirectories: Bool,
        skippingVanishedEntries: Bool = false,
                               requireExisting: Bool = false, visit: FileSystemWalkVisitor) async throws {
        let info: FileInfo
        if requireExisting && !skippingVanishedEntries { info = try await stat(path: path) }
        else {
            guard let existing = try await Snapshot.infoIfPresent(at: path, on: self) else { return }
            info = existing
        }
        if info.kind == .directory {
            let children: [DirectoryEntry]
            do { children = try await listDirectory(path: path) }
            catch {
                guard skippingUnreadableDirectories, isSkippableWalkError(error, at: path) else { throw error }
                try await visit(info, { _ in throw WorkspaceError.unsupported("cannot read a directory") },
                                { throw WorkspaceError.unsupported("not a symlink") })
                return
            }
            for (child, _) in children.map({ ($0, walkSortKey($0)) }).sorted(by: {
                $0.1.utf8.lexicographicallyPrecedes($1.1.utf8)
            }) {
                try await walkUsingPaths(at: path.appending(child.name),
                                         skippingUnreadableDirectories: skippingUnreadableDirectories,
                                             skippingVanishedEntries: skippingVanishedEntries, requireExisting: true, visit: visit)
            }
        }
        try await visit(info, { length in
            if let length { return try await self.readFile(path: path, offset: 0, length: length) }
            return try await self.readFile(path: path)
        }, { try await self.readSymlink(path: path) })
    }
}

func walkSortKey(_ entry: DirectoryEntry) -> String {
    walkSortKey(name: entry.name, isDirectory: entry.info.kind == .directory)
}

func walkSortKey(name: String, isDirectory: Bool) -> String {
    name + (isDirectory ? "/" : "")
}

func isSkippableWalkError(_ error: any Error, at path: WorkspacePath) -> Bool {
    let error = error as NSError
    return !path.isRoot && error.domain == NSPOSIXErrorDomain
        && [Int(EACCES), Int(ENOENT), Int(ENOTDIR)].contains(error.code)
}
