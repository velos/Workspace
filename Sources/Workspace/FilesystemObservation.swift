import Foundation

struct FilesystemObservation: Sendable {
    var metadata: MetadataIndex
    var cache: [WorkspacePath: Data] = [:]
    var cacheBytes = 0
    private struct Recency: Sendable { var older: WorkspacePath?; var newer: WorkspacePath? }
    private var recency: [WorkspacePath: Recency] = [:]
    private var oldest: WorkspacePath?
    private var newest: WorkspacePath?
    var aliases: [FileIdentity: Set<WorkspacePath>] = [:]
    private var children: [WorkspacePath: Set<WorkspacePath>] = [:]
    let budget: Int

    static func start(on fs: any FileSystem, budget: Int) async throws -> Self {
        let metadata = try await MetadataIndex.capture(from: fs)
        var result = Self(metadata: metadata, budget: budget)
        for (path, entry) in metadata.entries {
            if path != .root { result.children[path.parent, default: []].insert(path) }
            if entry.info.kind == .file, let identity = entry.info.identity {
                result.aliases[identity, default: []].insert(path)
            }
        }
        guard budget > 0 else { return result }
        // Warm only the bounded text cache. Large files never enter it.
        for path in metadata.entries.keys.sorted() {
            let info = metadata.entries[path]!.info
            if info.kind == .file && info.size <= UInt64(DiffOptions.default.maxTextBytes!)
                && info.size <= UInt64(budget - result.cacheBytes) {
                if let data = try? await fs.readFile(path: path) { result.insert(data, at: path) }
            }
        }
        return result
    }

    private mutating func unlink(_ path: WorkspacePath) {
        guard let links = recency.removeValue(forKey: path) else { return }
        if let older = links.older { recency[older]?.newer = links.newer } else { oldest = links.newer }
        if let newer = links.newer { recency[newer]?.older = links.older } else { newest = links.older }
    }

    private mutating func touch(_ path: WorkspacePath) {
        guard cache[path] != nil else { return }
        unlink(path)
        recency[path] = Recency(older: newest, newer: nil)
        if let newest { recency[newest]?.newer = path } else { oldest = path }
        newest = path
    }

    private mutating func removeCached(_ path: WorkspacePath) {
        if let old = cache.removeValue(forKey: path) { cacheBytes -= old.count }
        unlink(path)
    }

    mutating func insert(_ data: Data, at path: WorkspacePath) {
        removeCached(path)
        guard budget > 0, data.count <= budget, data.count <= DiffOptions.default.maxTextBytes! else { return }
        while cacheBytes + data.count > budget, let victim = oldest { removeCached(victim) }
        cache[path] = data
        cacheBytes += data.count
        touch(path)
    }

    mutating func replace(root: WorkspacePath, metadata replacement: MetadataIndex) {
        let removed = subtree(root)
        for path in removed {
            children.removeValue(forKey: path)
            children[path.parent]?.remove(path)
            if let old = metadata.entries.removeValue(forKey: path), let identity = old.info.identity {
                aliases[identity]?.remove(path)
                if aliases[identity]?.isEmpty == true { aliases.removeValue(forKey: identity) }
            }
            removeCached(path)
        }
        metadata.entries.merge(replacement.entries) { _, new in new }
        for (path, entry) in replacement.entries {
            if path != .root { children[path.parent, default: []].insert(path) }
            if entry.info.kind == .file, let identity = entry.info.identity { aliases[identity, default: []].insert(path) }
        }
    }

    mutating func remember(_ entry: Snapshot.Entry) {
        switch entry {
        case let .file(file): insert(file.data, at: file.path)
        case let .directory(directory): directory.children.forEach { remember($0) }
        default: break
        }
    }

    private func subtree(_ root: WorkspacePath) -> [WorkspacePath] {
        var paths = [root], cursor = 0
        while cursor < paths.count {
            paths.append(contentsOf: children[paths[cursor]] ?? [])
            cursor += 1
        }
        return paths
    }

    mutating func refresh(on fs: any FileSystem, signal: FileSystemChangeSignal) async throws -> ChangeSet {
        var before = MetadataIndex(), next = MetadataIndex()
        before.capturedAt = metadata.capturedAt
        before.exactTimestamps = metadata.exactTimestamps
        var verifyContents: Set<WorkspacePath> = []
        var checkRacyContents: Set<WorkspacePath> = []
        switch signal {
        case .rescan:
            before = metadata
            next = try await MetadataIndex.capture(from: fs)
            checkRacyContents = Set(next.entries.keys)
        case let .paths(paths):
            var affected = paths
            for path in paths.keys {
                if let identity = metadata.entries[path]?.info.identity, let shared = aliases[identity] {
                    for alias in shared { affected[alias] = max(affected[alias] ?? .entry, .entry) }
                }
            }
            var recursiveRoots: [WorkspacePath] = []
            func captureRecursive(_ root: WorkspacePath) async throws {
                for path in subtree(root) { before.entries[path] = metadata.entries[path] }
                let captured = try await MetadataIndex.capture(from: fs, at: root)
                next.entries.merge(captured.entries) { _, new in new }
                checkRacyContents.formUnion(captured.entries.keys)
                recursiveRoots.append(root)
            }
            func captureEntry(_ info: FileInfo) async throws {
                before.entries[info.path] = metadata.entries[info.path]
                let target = info.kind == .symlink ? try await fs.readSymlink(path: info.path) : nil
                next.entries[info.path] = .init(info: info, target: target)
            }
            for path in affected.keys.sorted() {
                // Preserve explicit file verification even beneath a shallow/recursive ancestor.
                verifyContents.insert(path)
                if recursiveRoots.contains(where: { Snapshot.contains($0, path) }) { continue }
                let scope = affected[path]!
                let old = metadata.entries[path]
                let info = try await Snapshot.infoIfPresent(at: path, on: fs)
                let replacedDirectory = old?.info.kind == .directory &&
                    (info?.kind != .directory || old?.info.identity != info?.identity)
                if scope == .recursive || replacedDirectory || (info?.kind == .directory && old?.info.kind != .directory) {
                    try await captureRecursive(path)
                    continue
                }
                before.entries[path] = old
                guard let info else { continue }
                try await captureEntry(info)
                guard scope == .shallow, info.kind == .directory else { continue }
                let listing = try await fs.listDirectory(path: path)
                let live = Set(listing.map { $0.info.path })
                for removed in (children[path] ?? []).subtracting(live) {
                    for descendant in subtree(removed) { before.entries[descendant] = metadata.entries[descendant] }
                }
                for child in listing {
                    let prior = metadata.entries[child.info.path]
                    if (child.info.kind == .directory || prior?.info.kind == .directory) &&
                        (prior?.info.kind != child.info.kind || prior?.info.identity != child.info.identity) {
                        try await captureRecursive(child.info.path)
                    } else {
                        try await captureEntry(child.info)
                    }
                }
            }
        }
        var changes: [FileChange] = []
        var omissions: [TextDiffOmission] = []
        var invalidated: Set<WorkspacePath> = []
        var used: [WorkspacePath] = []
        var admitted: [WorkspacePath: Data] = [:]
        var admittedBytes = 0
        var admittedOrder: [WorkspacePath] = []
        var admittedStart = 0
        for path in Set(before.entries.keys).union(next.entries.keys).sorted() {
            let old = before.entries[path], new = next.entries[path]
            let requiresContentCheck = new?.info.kind == .file && cache[path] != nil && (
                verifyContents.contains(path)
                || (checkRacyContents.contains(path) && old.map { new?.canReuseContents($0, capturedAt: before.capturedAt, exactTimestamps: before.exactTimestamps) != true } != false))
            guard old != new || requiresContentCheck else { continue }
            // mtime/identity changes on directories alone are not workspace changes.
            if let old, let new, old.info.kind == .directory, new.info.kind == .directory,
               old.info.permissions == new.info.permissions { continue }
            let oldData = cache[path]
            if oldData != nil { used.append(path) }
            var newData: Data?
            var contentReadFailed = false
            if budget > 0, let new, new.info.kind == .file, new.info.size <= UInt64(DiffOptions.default.maxTextBytes!),
               new.info.size <= UInt64(budget) {
                do { newData = try await fs.readFile(path: path) }
                catch { contentReadFailed = true }
            }
            if let oldData, let newData, old?.info.kind == .file, new?.info.kind == .file,
               oldData == newData, old?.info.permissions == new?.info.permissions { continue }

            func entry(_ value: MetadataIndex.Entry?, _ data: Data?) -> Snapshot.Entry {
                guard let value else { return .missing(.init(path: path)) }
                switch value.info.kind {
                case .file: return .file(.init(path: path, data: data ?? Data(), permissions: value.info.permissions))
                case .directory: return .directory(.init(path: path, permissions: value.info.permissions, children: []))
                case .symlink: return .symlink(.init(path: path, target: value.target!, permissions: value.info.permissions))
                }
            }
            let missingContent = (old?.info.kind == .file && oldData == nil) || (new?.info.kind == .file && newData == nil)
            if missingContent {
                if let old, let new, old.info.kind == new.info.kind {
                    changes.append(.init(path: path, kind: new.info.kind, effect: .modified))
                } else {
                    if let old { changes.append(.init(path: path, kind: old.info.kind, effect: .deleted)) }
                    if let new { changes.append(.init(path: path, kind: new.info.kind, effect: .created)) }
                }
                let oversized = max(old?.info.size ?? 0, new?.info.size ?? 0) > UInt64(DiffOptions.default.maxTextBytes!)
                omissions.append(.init(path: path, reason: contentReadFailed ? .contentReadFailed : (oversized ? .sizeLimitExceeded : .observationCacheMiss)))
            } else {
                let diff = ChangeSet.compare(before: Snapshot(rootPath: path, entry: entry(old, oldData)),
                                             after: Snapshot(rootPath: path, entry: entry(new, newData)),
                                             maxTextBytes: DiffOptions.default.maxTextBytes)
                changes += diff.changes
                omissions += diff.textDiffOmissions
            }
            invalidated.insert(path)
            if let newData {
                while admittedBytes + newData.count > budget, admittedStart < admittedOrder.count {
                    let victim = admittedOrder[admittedStart]
                    admittedStart += 1
                    admittedBytes -= admitted.removeValue(forKey: victim)!.count
                }
                admittedOrder.append(path)
                admitted[path] = newData
                admittedBytes += newData.count
            }
        }
        // Commit cache and metadata together only after every changed-file read succeeds.
        for path in used { touch(path) }
        for path in invalidated {
            removeCached(path)
        }
        for path in admittedOrder.dropFirst(admittedStart) { insert(admitted[path]!, at: path) }
        // Update index membership without invalidating the freshly updated cache.
        for path in before.entries.keys {
            children[path.parent]?.remove(path)
            if next.entries[path]?.info.kind != .directory { children.removeValue(forKey: path) }
            if let old = metadata.entries.removeValue(forKey: path), let identity = old.info.identity {
                aliases[identity]?.remove(path)
                if aliases[identity]?.isEmpty == true { aliases.removeValue(forKey: identity) }
            }
        }
        if case .rescan = signal { metadata.capturedAt = next.capturedAt }
        metadata.entries.merge(next.entries) { _, new in new }
        for (path, entry) in next.entries {
            if path != .root { children[path.parent, default: []].insert(path) }
            if entry.info.kind == .file, let identity = entry.info.identity { aliases[identity, default: []].insert(path) }
        }
        return ChangeSet(changes: changes, textDiffOmissions: omissions)
    }
}
