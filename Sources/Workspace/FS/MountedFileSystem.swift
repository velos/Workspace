import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A filesystem that composes a base filesystem with additional mounted filesystems.
///
/// Each mount is exposed at a virtual path, allowing callers to present a single workspace assembled
/// from multiple independent roots.
public final class MountedFileSystem: FileSystem, TraversingFileSystem, PreviewSemanticsFileSystem, PotentialPathResolvingFileSystem, @unchecked Sendable {
    /// A mounted filesystem and the virtual path where it appears.
    public struct Mount: Sendable {
        /// The normalized virtual mount point.
        public var mountPoint: WorkspacePath
        /// The filesystem exposed at `mountPoint`.
        public var fileSystem: any FileSystem

        /// Creates a mount description from a typed workspace path.
        public init(mountPoint: WorkspacePath, fileSystem: any FileSystem) {
            self.mountPoint = mountPoint
            self.fileSystem = fileSystem
        }

        init(mountPoint: WorkspacePath, filesystem: any FileSystem) {
            self.init(mountPoint: mountPoint, fileSystem: filesystem)
        }

        /// Convenience initializer that accepts a string mount point.
        init(mountPoint: String, filesystem: any FileSystem) {
            self.init(mountPoint: WorkspacePath(normalizing: mountPoint), fileSystem: filesystem)
        }
    }

    private let base: any FileSystem
    private let stateLock = NSLock()
    private var mounts: [Mount]
    private var mountObservers: [UUID: AsyncStream<[Mount]>.Continuation] = [:]
    private let syntheticDevice = UInt64.random(in: 1...UInt64.max)
    private var syntheticInodes: [WorkspacePath: UInt64] = [:]

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private func mountsSnapshot() -> [Mount] {
        withLock { mounts }
    }

    /// Creates a mountable filesystem with an optional base filesystem and initial mounts.
    public init(
        base: any FileSystem = InMemoryFileSystem(),
        mounts: [Mount] = []
    ) {
        self.base = base
        self.mounts = mounts.sorted { $0.mountPoint.components.count > $1.mountPoint.components.count }
    }

    /// Adds a filesystem mount at `mountPoint`.
    public func mount(_ mountPoint: WorkspacePath, fileSystem: any FileSystem) {
        withLock {
            let mount = Mount(mountPoint: mountPoint, fileSystem: fileSystem)
            mounts.append(mount)
            mounts.sort { $0.mountPoint.components.count > $1.mountPoint.components.count }
            for observer in mountObservers.values { observer.yield(mounts) }
        }
    }

    func mount(_ mountPoint: WorkspacePath, filesystem: any FileSystem) {
        mount(mountPoint, fileSystem: filesystem)
    }

    /// Convenience overload that accepts a string mount point.
    func mount(_ mountPoint: String, filesystem: any FileSystem) {
        mount(WorkspacePath(normalizing: mountPoint), fileSystem: filesystem)
    }

    package var supportsScopedWalk: Bool {
        base.supportsScopedWalk || mountsSnapshot().contains { $0.fileSystem.supportsScopedWalk }
    }

    nonisolated(nonsending) package func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool = false,
                                            visit: FileSystemWalkVisitor) async throws {
        let mounts = mountsSnapshot()
        // An entire subtree in one backend can use its descriptor-scoped walk.
        // At mount junctions, virtual listings retain shadowing and synthetic parents.
        if !mounts.contains(where: { $0.mountPoint != path && $0.mountPoint.isWithin(path) }) {
            let resolved = resolveWritable(path: path, mounts: mounts)
            var visited = false
            do {
                try await resolved.filesystem.walk(at: resolved.relativePath,
                    skippingUnreadableDirectories: skippingUnreadableDirectories,
                        skippingVanishedEntries: skippingVanishedEntries) { info, read, readLink in
                    visited = true
                    let virtual = resolved.mountPoint.appending(info.path.components.joined(separator: "/"))
                    try await withoutActuallyEscaping(read) { scopedRead in
                        try await withoutActuallyEscaping(readLink) { scopedLink in
                            try await visit(Self.virtualInfo(info, at: virtual),
                                            { try await scopedRead($0) }, { try await scopedLink() })
                        }
                    }
                }
            } catch {
                // A backend root may be a skippable child in our virtual namespace.
                guard !visited, resolved.relativePath.isRoot, skippingUnreadableDirectories,
                      isSkippableWalkError(error, at: path) else { throw error }
                try await walkUsingPaths(at: path, skippingUnreadableDirectories: true,
                    skippingVanishedEntries: skippingVanishedEntries, visit: visit)
            }
            return
        }
        guard let info = try await Snapshot.infoIfPresent(at: path, on: self) else { return }
        if info.kind == .directory {
            let listing: [DirectoryEntry]
            do { listing = try await listDirectory(path: path) }
            catch {
                guard skippingUnreadableDirectories, isSkippableWalkError(error, at: path) else { throw error }
                try await visit(info, { _ in throw WorkspaceError.unsupported("cannot read a directory") },
                                { throw WorkspaceError.unsupported("not a symlink") })
                return
            }
            for child in listing.sorted(by: { PathName(walkSortKey($0)) < PathName(walkSortKey($1)) }) {
                try await walk(at: child.info.path, skippingUnreadableDirectories: skippingUnreadableDirectories,
                    skippingVanishedEntries: skippingVanishedEntries, visit: visit)
            }
        }
        try await visit(info, { length in
            try await self.readFile(path: path, offset: 0, length: length)
        }, { try await self.readSymlink(path: path) })
    }

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let mounts = mountsSnapshot()
        let resolved = resolveWritable(path: path, mounts: mounts)
        do {
            return Self.virtualInfo(
                try await resolved.filesystem.stat(path: resolved.relativePath),
                at: path
            )
        } catch {
            guard Self.isMissing(error),
                  path.isRoot || !syntheticChildMountNames(under: path, mounts: mounts).isEmpty else { throw error }
            return syntheticInfo(at: path)
        }
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let mounts = mountsSnapshot()
        let syntheticNames = syntheticChildMountNames(under: path, mounts: mounts)
        let resolved = resolveWritable(path: path, mounts: mounts)
        var merged: [PathName: DirectoryEntry] = [:]
        do {
            for entry in try await resolved.filesystem.listDirectory(path: resolved.relativePath) {
                merged[PathName(entry.name)] = DirectoryEntry(
                    name: entry.name,
                    info: Self.virtualInfo(entry.info, at: path.appending(entry.name))
                )
            }
        } catch {
            let nsError = error as NSError
            guard Self.isMissing(error)
                    || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOTDIR)) else { throw error }
            guard path.isRoot || !syntheticNames.isEmpty else { throw error }
            let listingError = error
            var missing = false
            do {
                _ = try await resolved.filesystem.stat(path: resolved.relativePath)
            } catch {
                guard Self.isMissing(error) else { throw listingError }
                missing = true
            }
            guard missing else { throw listingError }
        }

        for name in syntheticNames {
            let child = path.appending(name)
            // Actual mounts shadow entries. Synthetic ancestors use backend metadata if
            // present, keeping traversal consistent with stat (including regular files).
            merged[PathName(name)] = DirectoryEntry(name: name, info: try await stat(path: child))
        }
        return merged.values.sorted { PathName($0.name) < PathName($1.name) }
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        if let resolved = resolveMounted(path: path, mounts: mountsSnapshot()) {
            return try await resolved.filesystem.readFile(path: resolved.relativePath)
        }
        return try await base.readFile(path: path)
    }

    /// See ``FileSystem/readFile(path:offset:length:)``.
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        if let resolved = resolveMounted(path: path, mounts: mountsSnapshot()) {
            return try await resolved.filesystem.readFile(
                path: resolved.relativePath,
                offset: offset,
                length: length
            )
        }
        return try await base.readFile(path: path, offset: offset, length: length)
    }

    /// See ``FileSystem/readFileChunks(path:chunkSize:)``.
    public func readFileChunks(
        path: WorkspacePath,
        chunkSize: Int
    ) async throws -> AsyncThrowingStream<Data, Error> {
        if let resolved = resolveMounted(path: path, mounts: mountsSnapshot()) {
            return try await resolved.filesystem.readFileChunks(
                path: resolved.relativePath,
                chunkSize: chunkSize
            )
        }
        return try await base.readFileChunks(path: path, chunkSize: chunkSize)
    }

    /// See ``FileSystem/createFile(path:data:)``.
    public func createFile(path: WorkspacePath, data: Data) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.createFile(path: resolved.relativePath, data: data)
    }

    package func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        return await resolved.filesystem.previewBehavior(at: resolved.relativePath)
    }

    /// See ``FileSystem/capabilities()``. Reports the intersection of the base filesystem's and
    /// every mount's capabilities, since a path may resolve to any of them.
    public func capabilities() async -> FileSystemFeatures {
        var combined = await base.capabilities()
        for mount in mountsSnapshot() {
            combined.formIntersection(await mount.fileSystem.capabilities())
        }
        return combined
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.writeFile(path: resolved.relativePath, data: data, append: append)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.createDirectory(path: resolved.relativePath, recursive: recursive)
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.remove(path: resolved.relativePath, recursive: recursive)
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let mounts = mountsSnapshot()
        let source = resolveWritable(path: sourcePath, mounts: mounts)
        let destination = resolveWritable(path: destinationPath, mounts: mounts)
        if source.mountPoint == destination.mountPoint {
            try await source.filesystem.move(from: source.relativePath, to: destination.relativePath)
            return
        }

        try await copyTree(
            from: source.filesystem,
            sourcePath: source.relativePath,
            to: destination.filesystem,
            destinationPath: destination.relativePath
        )
        try await source.filesystem.remove(path: source.relativePath, recursive: true)
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let mounts = mountsSnapshot()
        let source = resolveWritable(path: sourcePath, mounts: mounts)
        let destination = resolveWritable(path: destinationPath, mounts: mounts)
        if source.mountPoint == destination.mountPoint {
            try await source.filesystem.copy(
                from: source.relativePath,
                to: destination.relativePath,
                recursive: recursive
            )
            return
        }

        let info = try await source.filesystem.stat(path: source.relativePath)
        if info.kind == .directory, !recursive {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
        }
        try await copyTree(
            from: source.filesystem,
            sourcePath: source.relativePath,
            to: destination.filesystem,
            destinationPath: destination.relativePath
        )
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.createSymlink(path: resolved.relativePath, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let mounts = mountsSnapshot()
        let link = resolveWritable(path: path, mounts: mounts)
        let targetResolved = resolveWritable(path: target, mounts: mounts)
        if link.mountPoint != targetResolved.mountPoint {
            throw WorkspaceError.unsupported("hard links across mounts are not supported")
        }
        try await link.filesystem.createHardLink(path: link.relativePath, target: targetResolved.relativePath)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        return try await resolved.filesystem.readSymlink(path: resolved.relativePath)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        try await resolved.filesystem.setPermissions(path: resolved.relativePath, permissions: permissions)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        let real = try await resolved.filesystem.resolveRealPath(path: resolved.relativePath)
        return resolved.mountPoint.isRoot ? real : WorkspacePath.join(resolved.mountPoint, real.components.joined(separator: "/"))
    }

    // Used only when a symlink target or suffix is missing. Resolve inside the selected
    // backend before translating back; raw absolute targets are never outer virtual paths.
    package func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath {
        let resolved = resolveWritable(path: path, mounts: mountsSnapshot())
        let real = try await FileSystemPathResolver(base: resolved.filesystem).resolve(
            resolved.relativePath, features: await resolved.filesystem.capabilities(), followFinal: true
        )
        return resolved.mountPoint.isRoot ? real : WorkspacePath.join(resolved.mountPoint, real.components.joined(separator: "/"))
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        (try? await stat(path: path)) != nil
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let paths = try await allPaths()
        return paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }.sorted()
    }

    private func copyTree(
        from sourceFS: any FileSystem,
        sourcePath: WorkspacePath,
        to destinationFS: any FileSystem,
        destinationPath: WorkspacePath
    ) async throws {
        let info = try await sourceFS.stat(path: sourcePath)
        if info.kind == .directory {
            try await destinationFS.createDirectory(path: destinationPath, recursive: true)
            let children = try await sourceFS.listDirectory(path: sourcePath)
            for child in children {
                try await copyTree(
                    from: sourceFS,
                    sourcePath: sourcePath.appending(child.name),
                    to: destinationFS,
                    destinationPath: destinationPath.appending(child.name)
                )
            }
            return
        }

        if info.kind == .symlink {
            let target = try await sourceFS.readSymlink(path: sourcePath)
            try await destinationFS.createSymlink(path: destinationPath, target: target)
            return
        }

        let data = try await sourceFS.readFile(path: sourcePath)
        try await destinationFS.writeFile(path: destinationPath, data: data, append: false)
    }

    private func allPaths() async throws -> [WorkspacePath] {
        var visited = Set<WorkspacePath>()
        var queue: [WorkspacePath] = [.root]
        var paths: [WorkspacePath] = [.root]

        while let current = queue.first {
            queue.removeFirst()
            if visited.contains(current) {
                continue
            }
            visited.insert(current)

            guard let entries = try? await listDirectory(path: current) else {
                continue
            }

            for entry in entries {
                let childPath = current.appending(entry.name)
                paths.append(childPath)
                if entry.info.kind == .directory {
                    queue.append(childPath)
                }
            }
        }

        return Array(Set(paths))
    }

    private static func virtualInfo(_ info: FileInfo, at path: WorkspacePath) -> FileInfo {
        var adjusted = info
        adjusted.path = path
        return adjusted
    }

    private func syntheticInfo(at path: WorkspacePath) -> FileInfo {
        let inode = withLock {
            if let existing = syntheticInodes[path] { return existing }
            let next = UInt64(syntheticInodes.count) + 1
            syntheticInodes[path] = next
            return next
        }
        return FileInfo(path: path, kind: .directory, size: 0, permissions: .defaultDirectory,
                        modificationDate: nil, identity: FileIdentity(device: syntheticDevice, inode: inode))
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            || (error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
    }

    private func syntheticChildMountNames(under path: WorkspacePath, mounts: [Mount]) -> [String] {
        var names = Set<PathName>()
        for mount in mounts where mount.mountPoint != path {
            guard isPath(mount.mountPoint, inside: path) else {
                continue
            }
            if let first = mount.mountPoint.components.dropFirst(path.components.count).first {
                names.insert(PathName(first))
            }
        }
        return names.sorted().map(\.string)
    }

    private func isPath(_ candidate: WorkspacePath, inside parent: WorkspacePath) -> Bool {
        candidate.isWithin(parent)
    }

    private func resolveWritable(path: WorkspacePath, mounts: [Mount])
        -> (mountPoint: WorkspacePath, filesystem: any FileSystem, relativePath: WorkspacePath)
    {
        resolveMounted(path: path, mounts: mounts) ?? (.root, base, path)
    }

    private func resolveMounted(path: WorkspacePath, mounts: [Mount])
        -> (mountPoint: WorkspacePath, filesystem: any FileSystem, relativePath: WorkspacePath)?
    {
        for mount in mounts {
            if mount.mountPoint == path {
            return (mount.mountPoint, mount.fileSystem, .root)
            }

            if mount.mountPoint.isRoot {
                return (mount.mountPoint, mount.fileSystem, path)
            }

            if path.isWithin(mount.mountPoint) {
                let suffix = path.components.dropFirst(mount.mountPoint.components.count).joined(separator: "/")
                return (
                    mount.mountPoint,
                    mount.fileSystem,
                    WorkspacePath(normalizing: suffix.isEmpty ? "/" : suffix)
                )
            }
        }
        return nil
    }
}

extension MountedFileSystem: CompleteFileSystemChangeSource {
    package var changeSignalsAreComplete: Bool {
        get async {
            let mounts = mountsSnapshot()
            guard await base.changeSignalsAreComplete else { return false }
            for mount in mounts where await !mount.fileSystem.changeSignalsAreComplete { return false }
            return true
        }
    }
    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        let id = UUID()
        let (topology, updates) = AsyncStream<[Mount]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withLock {
            mountObservers[id] = updates
            updates.yield(mounts)
        }
        return AsyncStream { continuation in
            let task = Task {
                var subscriptions: [Task<Void, Never>] = []
                defer { subscriptions.forEach { $0.cancel() } }
                for await mounts in topology where !Task.isCancelled {
                    subscriptions.forEach { $0.cancel() }
                    subscriptions.removeAll()
                    let sources = [Mount(mountPoint: .root, fileSystem: self.base)] + mounts
                    for mount in sources {
                        guard let source = mount.fileSystem as? any FileSystemChangeSource else { continue }
                        let signals: AsyncStream<FileSystemChangeSignal>
                        do { signals = try await source.changeSignals() }
                        catch { continuation.finish(); return }
                        subscriptions.append(Task {
                            for await signal in signals where !Task.isCancelled {
                                switch signal {
                                case .rescan:
                                    continuation.yield(.paths([mount.mountPoint: .recursive]))
                                case let .paths(paths):
                                    var visible: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
                                    for (path, scope) in paths {
                                        let virtual = mount.mountPoint.appending(path.components.joined(separator: "/"))
                                        let owner = self.resolveWritable(path: virtual, mounts: mounts)
                                        guard owner.mountPoint == mount.mountPoint else { continue }
                                        visible[virtual] = scope
                                    }
                                    if !visible.isEmpty { continuation.yield(.paths(visible)) }
                                }
                            }
                            // A failed child must not leave a live, silently incomplete stream.
                            if !Task.isCancelled { continuation.finish() }
                        })
                    }
                    // Reconcile changes during subscription setup and any new mount.
                    continuation.yield(.rescan)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.withLock { self.mountObservers.removeValue(forKey: id)?.finish() }
            }
        }
    }
}
