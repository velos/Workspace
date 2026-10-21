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

// Retained accounting omits timestamps, permissions and the duplicate path.
struct LimitedAccountingEntry: Sendable {
    let kind: FileTree.Kind
    let size: UInt64
    let identity: FileIdentity?
    let linkCount: UInt64?

    init(_ info: FileInfo) {
        kind = info.kind
        size = info.size
        identity = info.identity
        linkCount = info.linkCount
    }
}

/// A serializing filesystem decorator that rejects mutations exceeding projected limits.
///
/// All mutations through this instance share a FIFO gate. Mutations made directly to the base,
/// or through another decorator, are outside that gate. Accounting uses metadata, never content.
/// With complete change notifications, preflights reconcile signals consumed before projection finishes;
/// undelivered external changes may remain invisible. `revalidate()` forces a fresh metadata
/// walk without waiting for notifications. Neither notifications nor revalidation make a
/// preflight atomic with external writers. Without notifications or an exact mutation generation,
/// every preflight walks the whole tree. Successful mutations reconcile only affected metadata.
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
    private let accountingCacheEntryLimit: Int
    #if os(iOS) || os(watchOS)
    private static let defaultAccountingCacheEntryLimit = 25_000
    #else
    private static let defaultAccountingCacheEntryLimit = 250_000
    #endif
    private var accounting = Accounting()
    private var cacheValid = false
    private var cachedGeneration: UInt64?
    private var observationStarted = false
    private var observationAvailable = false
    private var observationTask: Task<Void, Never>?
    private var invalidations: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
    private var rescan = false
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a quota-enforcing decorator. `accountingCacheEntryLimit` caps retained
    /// accounting entries, including the root. `nil` uses 250,000 entries (25,000 on
    /// iOS/watchOS). Zero or negative values disable retention: every preflight walks
    /// the tree. Above the cap, accounting is discarded after each operation; the
    /// cap bounds retained entries, not peak memory during a walk.
    public init(base: any FileSystem, limits: FileSystemLimits, accountingCacheEntryLimit: Int? = nil) {
        self.base = base
        pathResolver = FileSystemPathResolver(base: base)
        self.limits = limits
        self.accountingCacheEntryLimit = max(0, accountingCacheEntryLimit ?? Self.defaultAccountingCacheEntryLimit)
    }

    deinit { observationTask?.cancel() }

    /// Forces fresh metadata accounting under the mutation gate. External writers must be
    /// quiescent for a coherent result; this does not wait for backend notification delivery.
    public func revalidate() async throws {
        await acquireMutation()
        defer { discardOversizedAccounting(); releaseMutation() }
        cacheValid = false
        _ = try await prepareAccounting()
    }

    nonisolated package var supportsScopedWalk: Bool { base.supportsScopedWalk }

    nonisolated(nonsending) package func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool = false,
                      visit: FileSystemWalkVisitor) async throws {
        try await base.walk(at: path, skippingUnreadableDirectories: skippingUnreadableDirectories,
            skippingVanishedEntries: skippingVanishedEntries, visit: visit)
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
        defer { discardOversizedAccounting(); releaseMutation() }
        try Task.checkCancellation()
        let generation = cachedGeneration
        do {
            let behavior = await base.previewBehavior(at: path)
            let target = try await pathResolver.resolve(path, features: await base.capabilities(),
                                                        followFinal: behavior.followsPermissionSymlinks)
            try await base.setPermissions(path: path, permissions: permissions)
            guard cacheValid else { return }
            do {
                // Permissions may change traversal of this subtree, including its aliases.
                try await reconcile([target: .recursive])
                let after = await (base as? any MutationGenerationFileSystem)?.mutationGeneration
                if let generation { cacheValid = after == generation &+ 1 }
                cachedGeneration = after
                if accounting.unidentifiedEntries > 0 { cacheValid = false }
            } catch { cacheValid = false }
        } catch {
            cacheValid = false
            throw error
        }
    }

    private func discardOversizedAccounting() {
        if accountingCacheEntryLimit == 0 || accounting.tree.count > accountingCacheEntryLimit {
            accounting = Accounting()
            cacheValid = false
        }
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
        defer { discardOversizedAccounting(); releaseMutation() }
        try Task.checkCancellation()
        guard limits.maxTotalBytes != nil || limits.maxEntryCount != nil else {
            try await operation()
            return
        }
        let retain = try await prepareAccounting()
        let affected = try await preflight(mutation)
        // Missing identities can hide aliases exposed through a composition, even
        // when a file has a single physical link. Treat that effect as uncertain.
        let uncertain = accounting.unidentifiedEntries > 0
        let generation = cachedGeneration
        do {
            try await operation()
        } catch {
            cacheValid = false // Includes partial mutation and cancellation after backend work.
            throw error
        }
        guard retain, !uncertain else { cacheValid = false; return }
        do {
            // Read back the projected scopes so identities, link counts, implicit parents and
            // backend-specific copy/replacement behavior are exact, rather than invented.
            try await reconcile(affected)
            let after = await (base as? any MutationGenerationFileSystem)?.mutationGeneration
            if let generation {
                cacheValid = after == generation &+ 1
            }
            cachedGeneration = after
            if accounting.unidentifiedEntries > 0 { cacheValid = false }
        } catch {
            // The mutation succeeded. A failed metadata refresh must not turn it into a
            // reported mutation failure (and tempt the caller to retry it).
            cacheValid = false
        }
    }

    private func checkWrite(_ count: Int) throws {
        if let limit = limits.maxWriteBytes, count > limit {
            throw FileSystemLimitError.writeBytes(attempted: count, limit: limit)
        }
    }

    private struct Usage {
        // Saturate only at the public quota boundary; subtraction must remain exact even
        // when a backend reports logical sizes whose sum exceeds UInt64.max.
        private var lowBytes: UInt64 = 0
        private var highBytes: UInt64 = 0
        var bytes: UInt64 { highBytes == 0 ? lowBytes : UInt64.max }
        var entries = 0
        mutating func add(bytes amount: UInt64) {
            let sum = lowBytes.addingReportingOverflow(amount)
            lowBytes = sum.partialValue
            if sum.overflow { highBytes += 1 }
        }
        mutating func add(_ other: Usage) {
            add(bytes: other.lowBytes)
            highBytes += other.highBytes
            entries += other.entries
        }
        mutating func subtract(_ other: Usage) {
            let difference = lowBytes.subtractingReportingOverflow(other.lowBytes)
            lowBytes = difference.partialValue
            highBytes -= other.highBytes + (difference.overflow ? 1 : 0)
            entries -= other.entries
        }
    }

    private struct Accounting {
        var tree: [WorkspacePath: LimitedAccountingEntry] = [:]
        var children: [WorkspacePath: Set<WorkspacePath>] = [:]
        var identities: [FileIdentity: Set<WorkspacePath>] = [:]
        var filesBySize: [UInt64: Set<WorkspacePath>] = [:]
        var unknownFilesBySize: [UInt64: Set<WorkspacePath>] = [:]
        var usage = Usage()
        var unidentifiedEntries = 0

        mutating func put(_ info: FileInfo) {
            erase(info.path)
            tree[info.path] = LimitedAccountingEntry(info)
            if info.kind != .symlink, info.identity == nil { unidentifiedEntries += 1 }
            if !info.path.isRoot {
                children[info.path.dirname, default: []].insert(info.path)
                usage.entries += 1
            }
            if let identity = info.identity { identities[identity, default: []].insert(info.path) }
            if info.kind == .file {
                filesBySize[info.size, default: []].insert(info.path)
                if info.identity == nil, info.linkCount != 1 {
                    unknownFilesBySize[info.size, default: []].insert(info.path)
                }
                usage.add(bytes: info.size)
            }
        }

        mutating func erase(_ path: WorkspacePath) {
            guard let old = tree.removeValue(forKey: path) else { return }
            if old.kind != .symlink, old.identity == nil { unidentifiedEntries -= 1 }
            if !path.isRoot {
                children[path.dirname]?.remove(path)
                if children[path.dirname]?.isEmpty == true { children.removeValue(forKey: path.dirname) }
                usage.entries -= 1
            }
            if let identity = old.identity {
                identities[identity]?.remove(path)
                if identities[identity]?.isEmpty == true { identities.removeValue(forKey: identity) }
            }
            if old.kind == .file {
                filesBySize[old.size]?.remove(path)
                if filesBySize[old.size]?.isEmpty == true { filesBySize.removeValue(forKey: old.size) }
                unknownFilesBySize[old.size]?.remove(path)
                if unknownFilesBySize[old.size]?.isEmpty == true { unknownFilesBySize.removeValue(forKey: old.size) }
                var removed = Usage()
                removed.add(bytes: old.size)
                usage.subtract(removed)
            }
        }

        func subtree(_ path: WorkspacePath) -> Set<WorkspacePath> {
            var result: Set<WorkspacePath> = []
            var pending = [path]
            while let next = pending.popLast() {
                if tree[next] != nil { result.insert(next) }
                pending.append(contentsOf: children[next] ?? [])
            }
            return result
        }

        func aliases(of path: WorkspacePath) -> Set<WorkspacePath> {
            guard let info = tree[path] else { return [] }
            if let identity = info.identity {
                var result = identities[identity] ?? [path]
                if info.kind == .file, info.linkCount != 1 {
                    result.formUnion(unknownFilesBySize[info.size] ?? [])
                }
                return result
            }
            guard info.kind == .file, info.linkCount != 1 else { return [path] }
            return Set((filesBySize[info.size] ?? []).filter { tree[$0]?.linkCount != 1 })
        }
    }

    private func startObservation() async {
        guard !observationStarted else { return }
        observationStarted = true
        guard let source = base as? any FileSystemChangeSource else { return }
        do {
            let stream = try await source.changeSignals()
            observationAvailable = true
            observationTask = Task { [weak self] in
                for await signal in stream {
                    guard !Task.isCancelled else { return }
                    await self?.receive(signal)
                }
                await self?.observationEnded()
            }
        } catch {
            observationEnded()
        }
    }

    private func receive(_ signal: FileSystemChangeSignal) {
        switch signal {
        case .rescan:
            rescan = true
            invalidations.removeAll()
        case let .paths(paths):
            guard !rescan else { return }
            for (path, scope) in paths { invalidations[path] = max(invalidations[path] ?? .entry, scope) }
        }
    }

    private func observationEnded() {
        observationAvailable = false
        rescan = true
        invalidations.removeAll()
    }

    private func prepareAccounting() async throws -> Bool {
        await startObservation()
        while true {
            try Task.checkCancellation()
            let generation = await (base as? any MutationGenerationFileSystem)?.mutationGeneration
            // Mounted coverage can change after a later mount. A live stream alone
            // does not guarantee notifications from every child.
            let complete = await base.changeSignalsAreComplete
            let retain = (observationAvailable && complete) || generation != nil
            if !retain || generation != cachedGeneration { cacheValid = false }
            let full = !cacheValid || rescan
            let dirty = invalidations
            invalidations.removeAll()
            rescan = false
            do {
                if full {
                    accounting = Accounting()
                    try await capture(.root)
                    cacheValid = true
                } else {
                    try await reconcile(dirty)
                }
            } catch {
                cacheValid = false
                throw error
            }
            let after = await (base as? any MutationGenerationFileSystem)?.mutationGeneration
            if generation != after { cacheValid = false; continue }
            cachedGeneration = after
            if rescan || !invalidations.isEmpty { continue }
            return retain && accountingCacheEntryLimit > 0 && accounting.tree.count <= accountingCacheEntryLimit
        }
    }

    private func capture(_ path: WorkspacePath, info: FileInfo? = nil) async throws {
        if base.supportsScopedWalk {
            // Preserve strict accounting-walk failures for vanished listed entries.
            // Callers invalidate partial accounting before propagating the error.
            try await base.walk(at: path, skippingVanishedEntries: false) { info, _, _ in self.accounting.put(info) }
        } else {
            // Listings supply metadata: no child stat or content-read requirement.
            let root: FileInfo?
            if let info { root = info }
            else if path.isRoot { root = try await base.stat(path: path) }
            else { root = try await Snapshot.infoIfPresent(at: path, on: base) }
            guard let root else { return }
            var pending = [root]
            while let next = pending.popLast() {
                accounting.put(next)
                if next.kind == .directory {
                    for child in try await base.listDirectory(path: next.path) {
                        var metadata = child.info
                        metadata.path = next.path.appending(child.name)
                        pending.append(metadata)
                    }
                }
            }
        }
    }

    private func reconcile(_ scopes: [WorkspacePath: FileSystemChangeSignal.Scope]) async throws {
        // Expand old aliases before removing metadata. Directory aliases can expose a
        // mutation at another mount point; file aliases can change size/link count too.
        var expanded = scopes
        for (path, scope) in scopes {
            for alias in accounting.aliases(of: path) {
                expanded[alias] = max(expanded[alias] ?? .entry, scope)
            }
        }
        // Parents precede their descendants, including entry-scoped replacements.
        for (path, scope) in expanded.sorted(by: { $0.key < $1.key }) {
            var ancestor = path
            var covered = false
            while !ancestor.isRoot {
                ancestor = ancestor.dirname
                if expanded[ancestor] == .recursive { covered = true; break }
            }
            if !covered { try await refresh(path, scope: scope) }
        }
    }

    private func refresh(_ path: WorkspacePath, scope: FileSystemChangeSignal.Scope,
                         includingAliases: Bool = true, listedInfo: FileInfo? = nil) async throws {
        // A delayed child event must not resurrect entries beneath a directory that
        // has since become a symlink. Accounting walks never descend through links.
        if !path.isRoot {
            var parent = path.dirname
            while true {
                guard accounting.tree[parent]?.kind == .directory else { return }
                if parent.isRoot { break }
                parent = parent.dirname
            }
        }
        let old = accounting.tree[path]
        let info: FileInfo?
        if let listedInfo { info = listedInfo }
        else { info = try await Snapshot.infoIfPresent(at: path, on: base) }
        let sameDirectory = old?.kind == .directory && info?.kind == .directory
            && old?.identity != nil && old?.identity == info?.identity
        if scope == .recursive || (old?.kind == .directory && !sameDirectory)
            || (info?.kind == .directory && !sameDirectory) {
            // Also refresh aliases outside a removed/replaced subtree: unlink changes
            // their link counts and a later append must not use stale singleton data.
            let removed = accounting.subtree(path)
            var aliases: Set<WorkspacePath> = []
            if includingAliases {
                for entry in removed { aliases.formUnion(accounting.aliases(of: entry)) }
            }
            for entry in removed { accounting.erase(entry) }
            if let info { try await capture(path, info: info) }
            for alias in aliases.subtracting(removed) {
                try await refresh(alias, scope: .entry, includingAliases: false)
            }
            return
        }
        if let info {
            accounting.put(info)
            if includingAliases, info.kind != .directory {
                for alias in accounting.aliases(of: path) where alias != path {
                    try await refresh(alias, scope: .entry, includingAliases: false)
                }
            }
        } else { accounting.erase(path) }
        if scope == .shallow, info?.kind == .directory {
            var former = accounting.children[path] ?? []
            for child in try await base.listDirectory(path: path) {
                let childPath = path.appending(child.name)
                former.remove(childPath)
                // A shallow scope validates immediate children but retains unchanged
                // directory interiors. Identity-less directories cannot prove reuse.
                var metadata = child.info
                metadata.path = childPath
                try await refresh(childPath, scope: .entry, listedInfo: metadata)
            }
            for child in former { try await refresh(child, scope: .recursive) }
        }
    }

    private func preflight(_ mutation: Mutation) async throws -> [WorkspacePath: FileSystemChangeSignal.Scope] {
        while true {
            do {
                let affected = try await project(mutation)
                if !rescan && invalidations.isEmpty { return affected }
            } catch {
                // Even an early projection rejection (e.g. EEXIST) may have raced a
                // signal consumed during path resolution. Retry against fresh metadata.
                if !rescan && invalidations.isEmpty { throw error }
            }
            _ = try await prepareAccounting()
        }
    }

    private func project(_ mutation: Mutation) async throws -> [WorkspacePath: FileSystemChangeSignal.Scope] {
        let tree = accounting.tree
        let current = accounting.usage
        var projected = current
        var affected: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
        let features = await base.capabilities()

        func resolve(_ path: WorkspacePath, in tree: [WorkspacePath: LimitedAccountingEntry], followFinal: Bool) async throws -> WorkspacePath {
            try await pathResolver.resolve(path, in: tree, features: features, followFinal: followFinal)
        }

        func subtract(_ path: WorkspacePath) {
            let removed = usage(of: accounting.subtree(path))
            projected.subtract(removed)
            affected[path] = .recursive
        }
        func addParents(_ path: WorkspacePath) {
            var parent = path.dirname
            var changedRoot = path
            while true {
                if !parent.isRoot, tree[parent] == nil {
                    projected.entries += 1
                    affected[parent] = .recursive
                    changedRoot = parent
                }
                // Translate only the changed suffix through directory aliases. Walking
                // the entire aliased directory would make a leaf write scale with its tree.
                for alias in accounting.aliases(of: parent) where alias != parent {
                    let suffix = changedRoot.components.dropFirst(parent.components.count).joined(separator: "/")
                    affected[alias.appending(suffix)] = .recursive
                }
                if parent.isRoot { break }
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
                    } else if let identity = info.identity {
                        let known = accounting.identities[identity]?.count ?? 1
                        let uncertain = info.linkCount == 1 ? 0 : (accounting.unknownFilesBySize[info.size]?.count ?? 0)
                        aliases = UInt64(known + uncertain)
                    } else {
                        aliases = UInt64((accounting.filesBySize[info.size] ?? []).reduce(0) { count, path in
                            guard let candidate = tree[path] else { return count }
                            if path == target { return count + 1 }
                            if let identity = info.identity, let other = candidate.identity {
                                return identity == other ? count + 1 : count
                            }
                            if info.linkCount == 1 || candidate.linkCount == 1 { return count }
                            return count + 1
                        })
                    }
                    let growth = size.multipliedReportingOverflow(by: aliases)
                    projected.add(bytes: growth.overflow ? UInt64.max : growth.partialValue)
                }
                affected[target] = .entry
            } else {
                addLeaf(target, bytes: size)
            }
        case let .directory(path):
            let target = try await resolve(path, in: tree, followFinal: true)
            if tree[target] == nil { addLeaf(target, bytes: 0) }
            else { affected[target] = .entry }
        case let .remove(path):
            let target = try await resolve(path, in: tree, followFinal: false)
            subtract(target)
            addParents(target)
        case let .move(source, destination), let .copy(source, destination):
            let from = try await resolve(source, in: tree, followFinal: false)
            let to = try await resolve(destination, in: tree, followFinal: false)
            guard tree[from] != nil else { throw Self.posix(ENOENT) }
            if from == to { break }
            let copied = usage(of: accounting.subtree(from))
            affected[to] = .recursive
            if case .move = mutation {
                if tree[from]?.kind == .directory, Self.contains(to, in: from) { throw Self.posix(EINVAL) }
                // Source and destination subtrees can overlap on an invalid backend move.
                // Subtract their union once; let the backend preserve its destination error.
                let removed = usage(of: accounting.subtree(to).union(accounting.subtree(from)))
                projected.subtract(removed)
                affected[from] = .recursive
                addParents(from)
            } else {
                subtract(to)
            }
            addParents(to)
            projected.add(copied)
            projected.entries += (from.isRoot && !to.isRoot ? 1 : 0)
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
            affected[from] = .entry
        }
        if let limit = limits.maxTotalBytes, projected.bytes > limit, projected.bytes > current.bytes {
            throw FileSystemLimitError.totalBytes(attempted: projected.bytes, limit: limit)
        }
        if let limit = limits.maxEntryCount, projected.entries > limit, projected.entries > current.entries {
            throw FileSystemLimitError.entryCount(attempted: projected.entries, limit: limit)
        }
        return affected
    }

    private func usage(of paths: Set<WorkspacePath>) -> Usage {
        var result = Usage()
        for path in paths {
            guard let info = accounting.tree[path] else { continue }
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
// backend meaning, including through decorators. Backends without this capability use the heuristic below.
struct FileSystemPathResolver: Sendable {
    private let base: any FileSystem

    init(base: any FileSystem) {
        self.base = base
    }

    func resolve(
        _ path: WorkspacePath, in tree: [WorkspacePath: LimitedAccountingEntry]? = nil,
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
            let kind: FileTree.Kind?
            if let tree { kind = tree[current]?.kind }
            else { kind = try? await base.stat(path: current).kind }
            if kind == .symlink {
                let target = try await base.readSymlink(path: current)
                let targetPath = try WorkspacePath(validating: target, relativeTo: current.dirname)
                let suffix = path.components.dropFirst(index + 1).joined(separator: "/")
                return try await resolve(
                    suffix.isEmpty ? targetPath : targetPath.appending(suffix), in: tree,
                    features: features, followFinal: true, depth: depth + 1
                )
            }
            if index < path.components.count - 1, let kind, kind != .directory {
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


extension LimitedFileSystem: CompleteFileSystemChangeSource {
    package var changeSignalsAreComplete: Bool { get async { await base.changeSignalsAreComplete } }
    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        guard let source = base as? any FileSystemChangeSource else {
            throw WorkspaceError.unsupported("filesystem change notifications are not supported")
        }
        return try await source.changeSignals()
    }
}
