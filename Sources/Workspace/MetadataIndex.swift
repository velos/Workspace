import Foundation

/// Metadata reuse may tolerate device renumbering; equality must remain exact.
protocol MetadataReusable: Equatable {
    func isReusable(as other: Self) -> Bool
}

extension Collection where Element: MetadataReusable {
    /// Ordered children must have the same length and reusable metadata at every position.
    func isReusable(as other: Self) -> Bool {
        elementsEqual(other) { $0.isReusable(as: $1) }
    }
}

/// An lstat index: directory timestamps are hints, never logical changes.
struct MetadataIndex: Sendable {
    struct Entry: Sendable, MetadataReusable {
        var info: FileInfo
        var target: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.info.kind == rhs.info.kind && lhs.info.size == rhs.info.size
                && lhs.info.modificationDate == rhs.info.modificationDate
                && lhs.info.identity == rhs.info.identity
                && lhs.info.path == rhs.info.path && lhs.info.linkCount == rhs.info.linkCount
                && lhs.info.permissions == rhs.info.permissions
                && lhs.target.map(PathName.init) == rhs.target.map(PathName.init)
        }

        /// Observation compares logical metadata; paths are keyed separately and link counts
        /// do not describe contents. Device renumbering alone does not invalidate a hint.
        func isReusable(as other: Self) -> Bool {
            info.kind == other.info.kind && info.size == other.info.size
                && info.modificationDate == other.info.modificationDate
                && FileIdentity.matchesForMetadataReuse(info.identity, other.info.identity)
                && info.permissions == other.info.permissions
                && target.map(PathName.init) == other.target.map(PathName.init)
        }

        func canReuseContents(_ old: Self, capturedAt: Date, exactTimestamps: Bool = false) -> Bool {
            info.kind == .file && old.info.kind == .file
                && old.info.modificationDate.map { exactTimestamps || $0.addingTimeInterval(2) < capturedAt } == true
                && info.size == old.info.size && info.modificationDate == old.info.modificationDate
                && (info.identity == nil || old.info.identity == nil
                    || FileIdentity.matchesForMetadataReuse(info.identity, old.info.identity))
        }
    }
    var entries: [WorkspacePath: Entry] = [:]
    // Set before enumeration; never advance while reusing entries from an older walk.
    var capturedAt = Date()
    var exactTimestamps = false

    static func capture(from fs: any FileSystem, at root: WorkspacePath = .root) async throws -> Self {
        var result = Self()
        result.exactTimestamps = await fs.supportsExactContentTimestamps
        // A scoped leaf reconciliation needs only one stat, not another walk.
        // Whole-tree capture starts directly at the traversal seam.
        let rootInfo: FileInfo?
        if root.isRoot {
            rootInfo = nil
        } else {
            guard let info = try await Snapshot.infoIfPresent(at: root, on: fs) else { return result }
            rootInfo = info
            if info.kind != .directory {
                let target = info.kind == .symlink ? try await fs.readSymlink(path: root) : nil
                result.entries[root] = Entry(info: info, target: target)
                return result
            }
        }
        if fs.supportsScopedWalk {
            try await fs.walk(at: root) { info, _, readLink in
                let target = info.kind == .symlink ? try await readLink() : nil
                result.entries[info.path] = Entry(info: info, target: target)
            }
            return result
        }
        func visit(_ info: FileInfo) async throws {
            let target = info.kind == .symlink ? try await fs.readSymlink(path: info.path) : nil
            result.entries[info.path] = Entry(info: info, target: target)
            if info.kind == .directory {
                for child in try await fs.listDirectory(path: info.path).sorted(by: { PathName($0.name) < PathName($1.name) }) {
                    try await visit(child.info)
                }
            }
        }
        if let rootInfo {
            try await visit(rootInfo)
        } else if let info = try await Snapshot.infoIfPresent(at: root, on: fs) {
            try await visit(info)
        }
        return result
    }
}
