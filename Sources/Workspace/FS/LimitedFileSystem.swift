import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FileSystemLimits: Sendable, Codable, Equatable {
    /// Logical regular-file bytes: each path counts its size, including every hard-link alias.
    /// Directories and symlinks contribute no bytes.
    public var maxTotalBytes: UInt64?
    public var maxEntryCount: Int?
    public var maxWriteBytes: Int?

    public init(maxTotalBytes: UInt64? = nil, maxEntryCount: Int? = nil, maxWriteBytes: Int? = nil) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntryCount = maxEntryCount
        self.maxWriteBytes = maxWriteBytes
    }
}

public enum FileSystemLimitError: Error, Sendable, Equatable, CustomStringConvertible {
    case totalBytes(attempted: UInt64, limit: UInt64)
    case entryCount(attempted: Int, limit: Int)
    case writeBytes(attempted: Int, limit: Int)

    public var description: String {
        switch self {
        case let .totalBytes(attempted, limit): "total byte limit exceeded: \(attempted) > \(limit)"
        case let .entryCount(attempted, limit): "entry count limit exceeded: \(attempted) > \(limit)"
        case let .writeBytes(attempted, limit): "write byte limit exceeded: \(attempted) > \(limit)"
        }
    }
}

/// A serializing filesystem decorator that rejects mutations exceeding projected limits.
///
/// All mutations through this instance share a FIFO gate. Mutations made directly to the base,
/// or through another decorator, are outside that gate. Accounting scans metadata, never content,
/// on each mutation so sequential external changes are reflected without a stale usage cache.
/// Append accounting uses metadata identities and link counts. Unknown aliases are charged
/// conservatively as all regular files of the target's size. Without the replacement feature,
/// non-appending writes are projected as replacing the final link itself; this is conservative
/// for bytes, but dangling-link entry counts require the backend to advertise its true behavior.
/// Custom backends must follow standard mutation semantics: replacement changes one entry;
/// append updates aliases; parents may be created. A composition cycle (for example a Mounted
/// base that mounts this same LimitedFileSystem) deadlocks while the gate is held.
public actor LimitedFileSystem: FileSystem, TraversingFileSystem, PreviewSemanticsFileSystem, PotentialPathResolvingFileSystem {
    private let base: any FileSystem
    private let pathResolver: FileSystemPathResolver
    public let limits: FileSystemLimits
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(base: any FileSystem, limits: FileSystemLimits) {
        self.base = base
        pathResolver = FileSystemPathResolver(base: base)
        self.limits = limits
    }

    nonisolated package var supportsScopedWalk: Bool { base.supportsScopedWalk }

    nonisolated(nonsending) package func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool,
                      visit: FileSystemWalkVisitor) async throws {
        try await base.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories, visit: visit)
    }

    public func stat(path: WorkspacePath) async throws -> FileInfo { try await base.stat(path: path) }
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        try await base.listDirectory(path: path)
    }
    public func readFile(path: WorkspacePath) async throws -> Data { try await base.readFile(path: path) }
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        try await base.readFile(path: path, offset: offset, length: length)
    }
    public func readFileChunks(path: WorkspacePath, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.readFileChunks(path: path, chunkSize: chunkSize)
    }
    package func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics {
        await base.previewBehavior(at: path)
    }

    public func capabilities() async -> FileSystemFeatures { await base.capabilities() }
    public func readSymlink(path: WorkspacePath) async throws -> String { try await base.readSymlink(path: path) }
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await base.resolveRealPath(path: path)
    }
    package func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath {
        try await pathResolver.resolve(path, features: await base.capabilities(), followFinal: true)
    }
    public func exists(path: WorkspacePath) async -> Bool { await base.exists(path: path) }
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        try await base.glob(pattern: pattern, currentDirectory: currentDirectory)
    }

    public func createFile(path: WorkspacePath, data: Data) async throws {
        try checkWrite(data.count)
        try await mutate(.createFile(path: path, size: UInt64(data.count))) {
            try await self.base.createFile(path: path, data: data)
        }
    }

    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        try checkWrite(data.count)
        try await mutate(.write(path: path, size: UInt64(data.count), append: append)) {
            try await self.base.writeFile(path: path, data: data, append: append)
        }
    }

    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        try await mutate(.directory(path: path)) {
            try await self.base.createDirectory(path: path, recursive: recursive)
        }
    }

    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        try await mutate(.remove(path: path)) {
            try await self.base.remove(path: path, recursive: recursive)
        }
    }

    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        try await mutate(.move(source: sourcePath, destination: destinationPath)) {
            try await self.base.move(from: sourcePath, to: destinationPath)
        }
    }

    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        try await mutate(.copy(source: sourcePath, destination: destinationPath)) {
            try await self.base.copy(from: sourcePath, to: destinationPath, recursive: recursive)
        }
    }

    public func createSymlink(path: WorkspacePath, target: String) async throws {
        try await mutate(.symlink(path: path)) {
            try await self.base.createSymlink(path: path, target: target)
        }
    }

    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        try await mutate(.hardLink(path: path, target: target)) {
            try await self.base.createHardLink(path: path, target: target)
        }
    }

    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        try await base.setPermissions(path: path, permissions: permissions)
    }

    private func acquireMutation() async {
        if !mutationActive {
            mutationActive = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationActive = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private enum Mutation {
        case createFile(path: WorkspacePath, size: UInt64)
        case write(path: WorkspacePath, size: UInt64, append: Bool)
        case directory(path: WorkspacePath)
        case remove(path: WorkspacePath)
        case move(source: WorkspacePath, destination: WorkspacePath)
        case copy(source: WorkspacePath, destination: WorkspacePath)
        case symlink(path: WorkspacePath)
        case hardLink(path: WorkspacePath, target: WorkspacePath)
    }

    private func mutate(_ mutation: Mutation, operation: () async throws -> Void) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        if limits.maxTotalBytes != nil || limits.maxEntryCount != nil {
            try await preflight(mutation)
        }
        try await operation()
    }

    private func checkWrite(_ count: Int) throws {
        if let limit = limits.maxWriteBytes, count > limit {
            throw FileSystemLimitError.writeBytes(attempted: count, limit: limit)
        }
    }

    private struct Usage {
        var bytes: UInt64 = 0
        var entries = 0

        mutating func add(bytes amount: UInt64) {
            let sum = bytes.addingReportingOverflow(amount)
            bytes = sum.overflow ? UInt64.max : sum.partialValue
        }
    }

    private func preflight(_ mutation: Mutation) async throws {
        var tree: [WorkspacePath: FileInfo] = [:]
        if base.supportsScopedWalk {
            try await base.walk { info, _, _ in tree[info.path] = info }
        } else {
            // Preserve metadata-only accounting for custom backends: listings already
            // supply child metadata and need not permit separate child stat calls.
            var pending = [try await base.stat(path: .root)]
            while let info = pending.popLast() {
                tree[info.path] = info
                if info.kind == .directory {
                    for child in try await base.listDirectory(path: info.path) {
                        var metadata = child.info
                        metadata.path = info.path.appending(child.name)
                        pending.append(metadata)
                    }
                }
            }
        }
        let current = Self.usage(tree)
        var projected = current
        let features = await base.capabilities()

        func resolve(_ path: WorkspacePath, in tree: [WorkspacePath: FileInfo], followFinal: Bool) async throws -> WorkspacePath {
            try await pathResolver.resolve(path, in: tree, features: features, followFinal: followFinal)
        }

        func subtract(_ path: WorkspacePath) {
            let removed = Self.usage(tree.filter { Self.contains($0.key, in: path) })
            projected.bytes -= removed.bytes
            projected.entries -= removed.entries
        }
        func addParents(_ path: WorkspacePath) {
            var parent = path.dirname
            while !parent.isRoot {
                if tree[parent] == nil { projected.entries += 1 }
                parent = parent.dirname
            }
        }
        func addLeaf(_ path: WorkspacePath, bytes: UInt64) {
            subtract(path)
            addParents(path)
            if !path.isRoot { projected.entries += 1 }
            projected.add(bytes: bytes)
        }

        switch mutation {
        case let .createFile(path, size):
            let target = try await resolve(path, in: tree, followFinal: false)
            if tree[target] != nil { throw Self.posix(EEXIST) }
            addLeaf(target, bytes: size)
        case let .write(path, size, append):
            let entry = try await resolve(path, in: tree, followFinal: false)
            let replaceLink = !append && tree[entry]?.kind == .symlink
                && !features.contains(.replacementFollowsFinalSymlink)
            let target = replaceLink ? entry : try await resolve(path, in: tree, followFinal: true)
            if tree[target]?.kind == .directory { throw Self.posix(EISDIR) }
            if append, let info = tree[target], info.kind == .file {
                // Entry-only quotas need no alias accounting. Identity is already in the
                // metadata walk, so disappearing candidates never cause another awaited stat.
                if limits.maxTotalBytes != nil {
                    let aliases: UInt64
                    if info.linkCount == 1, info.identity == nil {
                        aliases = 1
                    } else {
                        aliases = UInt64(tree.reduce(0) { count, entry in
                            let candidate = entry.value
                            guard candidate.kind == .file, candidate.size == info.size else { return count }
                            if entry.key == target { return count + 1 }
                            if let identity = info.identity, let other = candidate.identity {
                                // A mount can expose even a single-link inode at multiple paths.
                                return identity == other ? count + 1 : count
                            }
                            if info.linkCount == 1 || candidate.linkCount == 1 { return count }
                            return count + 1
                        })
                    }
                    let growth = size.multipliedReportingOverflow(by: aliases)
                    projected.add(bytes: growth.overflow ? UInt64.max : growth.partialValue)
                }
            } else {
                addLeaf(target, bytes: size)
            }
        case let .directory(path):
            let target = try await resolve(path, in: tree, followFinal: true)
            if tree[target] == nil { addLeaf(target, bytes: 0) }
        case let .remove(path):
            let target = try await resolve(path, in: tree, followFinal: false)
            subtract(target)
        case let .move(source, destination), let .copy(source, destination):
            let from = try await resolve(source, in: tree, followFinal: false)
            let to = try await resolve(destination, in: tree, followFinal: false)
            guard tree[from] != nil else { throw Self.posix(ENOENT) }
            if from == to { break }
            let copied = Self.usage(tree.filter { Self.contains($0.key, in: from) })
            if case .move = mutation {
                if tree[from]?.kind == .directory, Self.contains(to, in: from) { throw Self.posix(EINVAL) }
                // Source and destination subtrees can overlap on an invalid backend move.
                // Subtract their union once; let the backend preserve its destination error.
                let removed = Self.usage(tree.filter {
                    Self.contains($0.key, in: to) || Self.contains($0.key, in: from)
                })
                projected.bytes -= removed.bytes
                projected.entries -= removed.entries
            } else {
                subtract(to)
            }
            addParents(to)
            projected.add(bytes: copied.bytes)
            projected.entries += copied.entries + (from.isRoot && !to.isRoot ? 1 : 0)
        case let .symlink(path):
            let target = try await resolve(path, in: tree, followFinal: false)
            if tree[target] != nil { throw Self.posix(EEXIST) }
            addLeaf(target, bytes: 0)
        case let .hardLink(path, source):
            let target = try await resolve(path, in: tree, followFinal: false)
            let from = try await resolve(source, in: tree, followFinal: false)
            if tree[target] != nil { throw Self.posix(EEXIST) }
            guard let info = tree[from] else { throw Self.posix(ENOENT) }
            if info.kind == .directory { throw Self.posix(EPERM) }
            addLeaf(target, bytes: info.kind == .file ? info.size : 0)
        }
        if let limit = limits.maxTotalBytes, projected.bytes > limit, projected.bytes > current.bytes {
            throw FileSystemLimitError.totalBytes(attempted: projected.bytes, limit: limit)
        }
        if let limit = limits.maxEntryCount, projected.entries > limit, projected.entries > current.entries {
            throw FileSystemLimitError.entryCount(attempted: projected.entries, limit: limit)
        }
    }

    private static func usage(_ tree: [WorkspacePath: FileInfo]) -> Usage {
        var result = Usage()
        for (path, info) in tree {
            if !path.isRoot { result.entries += 1 }
            if info.kind == .file { result.add(bytes: info.size) }
        }
        return result
    }

    private static func contains(_ path: WorkspacePath, in parent: WorkspacePath) -> Bool {
        path.isWithin(parent)
    }

    private static func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

// Prefer backend-owned resolution so physical parents and absolute targets retain their
// backend meaning, including through decorators. Older backends use the heuristic below.
struct FileSystemPathResolver: Sendable {
    private let base: any FileSystem

    init(base: any FileSystem) {
        self.base = base
    }

    func resolve(
        _ path: WorkspacePath, in tree: [WorkspacePath: FileInfo]? = nil,
        features: FileSystemFeatures, followFinal: Bool, depth: Int = 0
    ) async throws -> WorkspacePath {
        guard depth < 64 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
        if !followFinal, !path.isRoot {
            return try await resolve(path.dirname, in: tree, features: features, followFinal: true, depth: depth)
                .appending(path.basename)
        }
        if let resolving = base as? any PotentialPathResolvingFileSystem {
            return try await resolving.resolvePotentialPath(path: path)
        }
        if features.contains(.realPathResolution) {
            var ancestor = path
            var missing: [String] = []
            while true {
                do {
                    let real = try await base.resolveRealPath(path: ancestor)
                    return missing.isEmpty ? real : real.appending(missing.reversed().joined(separator: "/"))
                } catch {
                    guard Self.isMissing(error), !ancestor.isRoot else { throw error }
                    // The ancestor may still contain intermediate symlinks, while the tree
                    // uses lstat paths. Ask the backend to resolve those intermediate links.
                    let info = try? await base.stat(path: ancestor)
                    if info?.kind == .symlink {
                        let target = try await base.readSymlink(path: ancestor)
                        let parent = try await resolve(
                            ancestor.dirname, in: tree, features: features, followFinal: true, depth: depth + 1
                        )
                        let targetPath = try WorkspacePath(validating: target, relativeTo: parent)
                        let combined = missing.isEmpty ? targetPath : targetPath.appending(missing.reversed().joined(separator: "/"))
                        return try await resolve(combined, in: tree, features: features, followFinal: true, depth: depth + 1)
                    }
                    missing.append(ancestor.basename)
                    ancestor = ancestor.dirname
                }
            }
        }
        var current = WorkspacePath.root
        for (index, component) in path.components.enumerated() {
            current = current.appending(component)
            let info: FileInfo?
            if let tree { info = tree[current] }
            else { info = try? await base.stat(path: current) }
            if info?.kind == .symlink {
                let target = try await base.readSymlink(path: current)
                let targetPath = try WorkspacePath(validating: target, relativeTo: current.dirname)
                let suffix = path.components.dropFirst(index + 1).joined(separator: "/")
                return try await resolve(
                    suffix.isEmpty ? targetPath : targetPath.appending(suffix), in: tree,
                    features: features, followFinal: true, depth: depth + 1
                )
            }
            if index < path.components.count - 1, let info, info.kind != .directory {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
            }
        }
        return current
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            || (error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
    }
}


extension LimitedFileSystem: FileSystemChangeSource {
    public func changes() async throws -> AsyncStream<Void> {
        unscopedChanges(try await changeSignals())
    }

    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        guard let source = base as? any FileSystemChangeSource else {
            throw WorkspaceError.unsupported("filesystem change notifications are not supported")
        }
        return try await source.changeSignals()
    }
}
