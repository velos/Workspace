import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A copy-on-write overlay over a disk directory.
///
/// Reads pass through lazily to the source directory (the *lower* layer); mutations land in an
/// in-memory *upper* layer, leaving the source directory untouched. Nothing is copied at
/// configuration time: a file's bytes enter memory only when it is read through the overlay or
/// copied up by a mutation. Deletions are recorded as whiteouts that hide the lower entry, and
/// directory listings merge both layers with upper entries shadowing lower ones.
///
/// File identities are forwarded from whichever layer holds the entry. Copy-up gives a file a new
/// identity, so limits charge appends to a hard-linked lower file conservatively.
///
/// `reload()` (or `configure(rootDirectory:)`) discards the upper layer and whiteouts, so the
/// overlay reflects the source directory's current state again.
public actor OverlayFileSystem: FileSystem, PreviewSemanticsFileSystem {
    private let fileManager: FileManager
    private var upper: InMemoryFileSystem
    private var lower: (any FileSystem)?
    private var rootURL: URL?
    /// Paths whose lower-layer entries (including everything beneath them) are hidden from the
    /// merged view. Creating a new entry at a cut path shadows it in the upper layer; the cut
    /// keeps hiding the original lower content.
    private var cuts: Set<WorkspacePath> = []
    private var rootPermissionsChanged = false
    private var previewSource: (any FileSystem)?

    /// Creates an unconfigured overlay filesystem.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        upper = InMemoryFileSystem()
    }

    /// Creates a live copy-on-write overlay over any filesystem.
    public init(over base: any FileSystem) {
        fileManager = .default
        upper = InMemoryFileSystem()
        lower = base
        rootURL = nil
    }

    init(previewOf base: any FileSystem) {
        fileManager = .default
        upper = InMemoryFileSystem()
        lower = base
        previewSource = base
    }

    init(over base: any FileSystem, semanticsOf source: any FileSystem) {
        fileManager = .default
        upper = InMemoryFileSystem()
        lower = base
        previewSource = source
    }

    package func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics {
        if let previewSource { return await previewSource.previewBehavior(at: path) }
        return .init(preservesOverwritePermissions: true,
                     followsDirectorySymlinks: true, followsPermissionSymlinks: true, createsWriteParents: true)
    }

    /// Creates and configures an overlay for `rootDirectory`.
    init(rootDirectory: URL, fileManager: FileManager = .default) async throws {
        self.fileManager = fileManager
        upper = InMemoryFileSystem()
        try await configure(rootDirectory: rootDirectory)
    }

    /// Creates a disk overlay rooted at `root`.
    public init(root: URL, fileManager: FileManager = .default) async throws {
        self.fileManager = fileManager
        upper = InMemoryFileSystem()
        try await configure(rootDirectory: root)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    func configure(rootDirectory: URL) async throws {
        rootURL = rootDirectory.standardizedFileURL
        try resetLayers()
    }

    /// Discards overlay writes and whiteouts so reads reflect the source directory again.
    func reload() async throws {
        guard rootURL != nil else {
            throw WorkspaceError.unsupported("overlay filesystem requires rootDirectory")
        }
        try resetLayers()
    }

    /// Discards upper-layer changes and whiteouts.
    public func discardChanges() async throws {
        upper = InMemoryFileSystem()
        cuts = []
        rootPermissionsChanged = false
        if rootURL != nil {
            try resetLayers()
        }
    }

    private func resetLayers() throws {
        upper = InMemoryFileSystem()
        cuts = []
        rootPermissionsChanged = false
        guard let rootURL else {
            lower = nil
            return
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            lower = try LocalFileSystem(rootDirectory: rootURL, fileManager: fileManager)
        } else {
            lower = nil
        }
    }

    // MARK: - Reads

    /// See ``FileSystem/stat(path:)``.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        let resolved = try await resolveMergedPath(path, followFinal: false)
        guard let info = await mergedEntry(resolved) else {
            throw posixError(ENOENT)
        }
        var adjusted = info
        if path.isRoot, !rootPermissionsChanged, let lower {
            adjusted.permissions = try await lower.stat(path: .root).permissions
        }
        adjusted.path = path
        return adjusted
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let originalPath = path
        let path = try await resolveMergedPath(path)
        let upperInfo = await upperEntry(path)
        let lowerInfo = await lowerVisibleEntry(path)
        guard upperInfo != nil || lowerInfo != nil else {
            throw posixError(ENOENT)
        }

        var byName: [PathName: DirectoryEntry] = [:]
        if let lowerInfo, upperInfo == nil || upperInfo?.kind == .directory {
            guard lowerInfo.kind == .directory || upperInfo != nil else {
                throw posixError(ENOTDIR)
            }
            if lowerInfo.kind == .directory, let lower {
                for entry in try await lower.listDirectory(path: path)
                where !isCut(path.appending(entry.name)) {
                    byName[PathName(entry.name)] = entry
                }
            }
        }
        if let upperInfo {
            guard upperInfo.kind == .directory else {
                throw posixError(ENOTDIR)
            }
            for entry in try await upper.listDirectory(path: path) {
                byName[PathName(entry.name)] = entry
            }
        }
        return byName.values.map { entry in
            var info = entry.info
            info.path = originalPath.appending(entry.name)
            return DirectoryEntry(name: entry.name, info: info)
        }.sorted { PathName($0.name) < PathName($1.name) }
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let target = try await resolveMergedPath(path)
        if await upperEntry(target) != nil {
            return try await upper.readFile(path: target)
        }
        guard let info = await lowerVisibleEntry(target), let lower else {
            throw posixError(ENOENT)
        }
        guard info.kind != .directory else {
            throw posixError(EISDIR)
        }
        return try await lower.readFile(path: target)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        let path = try await resolveMergedPath(path, followFinal: false)
        if await upperEntry(path) != nil {
            return try await upper.readSymlink(path: path)
        }
        guard let info = await lowerVisibleEntry(path), let lower else {
            throw posixError(ENOENT)
        }
        guard info.kind == .symlink else {
            throw posixError(EINVAL)
        }
        return try await lower.readSymlink(path: path)
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let target = try await resolveMergedPath(path)
        guard await mergedEntry(target) != nil else {
            throw posixError(ENOENT)
        }
        return target
    }

    /// See ``FileSystem/exists(path:)``.
    public func exists(path: WorkspacePath) async -> Bool {
        guard let target = try? await resolveMergedPath(path, followFinal: false) else {
            return false
        }
        return await mergedEntry(target) != nil
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let normalizedPattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(normalizedPattern.string) {
            return await exists(path: normalizedPattern) ? [normalizedPattern] : []
        }

        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(normalizedPattern.string))
        let paths = await allMergedPaths()
        return paths.filter { path in
            let range = NSRange(path.string.startIndex..<path.string.endIndex, in: path.string)
            return regex.firstMatch(in: path.string, range: range) != nil
        }.sorted()
    }

    /// See ``FileSystem/capabilities()``.
    public func capabilities() async -> FileSystemFeatures {
        [.symlinks, .hardLinks, .permissions, .realPathResolution]
    }

    // MARK: - Mutations

    /// See ``FileSystem/writeFile(path:data:append:)``.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        guard !path.isRoot else {
            throw posixError(EISDIR)
        }
        let semantics = await previewSemantics(at: path)
        let target = try await resolveMergedPath(path, allowMissingAncestors: semantics.createsWriteParents, createParents: semantics.createsWriteParents)
        if let info = await upperEntry(target) {
            try await upper.writeFile(path: target, data: data, append: append)
            if semantics.preservesOverwritePermissions { try await upper.setPermissions(path: target, permissions: info.permissions) }
            return
        }
        if let info = await lowerVisibleEntry(target), let lower {
            guard info.kind != .directory else {
                throw posixError(EISDIR)
            }
            try await ensureUpperDirectories(for: target, createMissing: semantics.createsWriteParents)
            let contents: Data
            if append {
                contents = try await lower.readFile(path: target) + data
            } else {
                contents = data
            }
            try await upper.writeFile(path: target, data: contents, append: false)
            try await upper.setPermissions(path: target, permissions: !semantics.preservesOverwritePermissions && !append ? .defaultFile : info.permissions)
            return
        }
        try await ensureUpperDirectories(for: target, createMissing: semantics.createsWriteParents)
        try await upper.writeFile(path: target, data: data, append: false)
    }

    /// See ``FileSystem/createFile(path:data:)``.
    public func createFile(path: WorkspacePath, data: Data) async throws {
        let createsParents = await previewSemantics(at: path).createsWriteParents
        let path = try await resolveMergedPath(path, followFinal: false, allowMissingAncestors: createsParents, createParents: createsParents)
        guard await mergedEntry(path) == nil else {
            throw posixError(EEXIST)
        }
        try await ensureUpperDirectories(for: path, createMissing: createsParents)
        try await upper.createFile(path: path, data: data)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        if !(await previewSemantics(at: path)).followsDirectorySymlinks {
            var current = WorkspacePath.root
            for component in path.components {
                current = current.appending(component)
                if let info = await mergedEntry(current), info.kind != .directory { throw posixError(ENOTDIR) }
            }
        }
        let path = try await resolveMergedPath(path, allowMissingAncestors: recursive)
        if path.isRoot {
            return
        }

        var current = WorkspacePath.root
        let components = path.components
        for (index, component) in components.enumerated() {
            current = current.appending(component)
            let isLast = index == components.count - 1

            if let info = await mergedEntry(current) {
                guard info.kind == .directory else {
                    throw posixError(ENOTDIR)
                }
                if isLast, !recursive {
                    throw posixError(EEXIST)
                }
                continue
            }

            if !recursive, !isLast {
                throw posixError(ENOENT)
            }
            try await ensureUpperDirectories(for: current)
            try await upper.createDirectory(path: current, recursive: false)
        }
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        let path = try await resolveMergedPath(path, followFinal: false)
        guard !path.isRoot else {
            throw posixError(EPERM)
        }
        let upperHas = await upperEntry(path) != nil
        let lowerVisible = await lowerVisibleEntry(path) != nil
        guard upperHas || lowerVisible else {
            return
        }

        if !recursive, (await mergedEntry(path))?.kind == .directory {
            let children = try await listDirectory(path: path)
            if !children.isEmpty {
                throw posixError(ENOTEMPTY)
            }
        }

        if upperHas {
            try await upper.remove(path: path, recursive: true)
        }
        if lowerVisible {
            // Deeper cuts are redundant once this path is cut.
            cuts = cuts.filter { !$0.isWithin(path) }
            cuts.insert(path)
        }
    }

    /// See ``FileSystem/move(from:to:)``.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let sourcePath = try await resolveMergedPath(sourcePath, followFinal: false)
        let createsParents = await previewSemantics(at: destinationPath).createsWriteParents
        let potentialDestination = try await resolveMergedPath(destinationPath, followFinal: false, allowMissingAncestors: createsParents)
        if sourcePath == potentialDestination {
            return
        }
        guard let sourceInfo = await mergedEntry(sourcePath) else {
            throw posixError(ENOENT)
        }
        if sourceInfo.kind == .directory, potentialDestination.isWithin(sourcePath) {
            throw posixError(EINVAL)
        }
        let destinationPath = try await resolveMergedPath(destinationPath, followFinal: false,
            allowMissingAncestors: createsParents, createParents: createsParents)
        guard await mergedEntry(destinationPath) == nil else {
            throw posixError(EEXIST)
        }

        try await materializeTree(sourcePath)
        try await ensureUpperDirectories(for: destinationPath, createMissing: createsParents)
        try await upper.move(from: sourcePath, to: destinationPath)
        if await lowerVisibleEntry(sourcePath) != nil {
            cuts = cuts.filter { !$0.isWithin(sourcePath) }
            cuts.insert(sourcePath)
        }
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool)
        async throws
    {
        let sourcePath = try await resolveMergedPath(sourcePath, followFinal: false)
        let createsParents = await previewSemantics(at: destinationPath).createsWriteParents
        let potentialDestination = try await resolveMergedPath(destinationPath, followFinal: false, allowMissingAncestors: createsParents)
        guard !potentialDestination.isWithin(sourcePath) else { throw posixError(EINVAL) }
        guard let sourceInfo = await mergedEntry(sourcePath) else {
            throw posixError(ENOENT)
        }
        if sourceInfo.kind == .directory, !recursive {
            throw posixError(EISDIR)
        }
        let destinationPath = try await resolveMergedPath(destinationPath, followFinal: false,
            allowMissingAncestors: createsParents, createParents: createsParents)
        guard await mergedEntry(destinationPath) == nil else {
            throw posixError(EEXIST)
        }

        try await materializeTree(sourcePath)
        try await ensureUpperDirectories(for: destinationPath, createMissing: createsParents)
        try await upper.copy(from: sourcePath, to: destinationPath, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        let createsParents = await previewSemantics(at: path).createsWriteParents
        let path = try await resolveMergedPath(path, followFinal: false, allowMissingAncestors: createsParents, createParents: createsParents)
        guard await mergedEntry(path) == nil else {
            throw posixError(EEXIST)
        }
        try await ensureUpperDirectories(for: path, createMissing: createsParents)
        try await upper.createSymlink(path: path, target: target)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let createsParents = await previewSemantics(at: path).createsWriteParents
        let target = try await resolveMergedPath(target, followFinal: false)
        guard let targetInfo = await mergedEntry(target) else {
            throw posixError(ENOENT)
        }
        guard targetInfo.kind != .directory else {
            throw posixError(EPERM)
        }
        let path = try await resolveMergedPath(path, followFinal: false, allowMissingAncestors: createsParents, createParents: createsParents)
        guard await mergedEntry(path) == nil else {
            throw posixError(EEXIST)
        }

        if await upperEntry(target) == nil {
            try await copyUpLeaf(target, info: targetInfo)
        }
        try await ensureUpperDirectories(for: path, createMissing: createsParents)
        try await upper.createHardLink(path: path, target: target)
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        let path = try await resolveMergedPath(path, followFinal: previewSemantics(at: path).followsPermissionSymlinks)
        if await upperEntry(path) == nil {
            guard let info = await lowerVisibleEntry(path) else {
                throw posixError(ENOENT)
            }
            if info.kind == .directory {
                try await ensureUpperDirectories(for: path)
                try await upper.createDirectory(path: path, recursive: true)
            } else {
                try await copyUpLeaf(path, info: info)
            }
        }
        try await upper.setPermissions(path: path, permissions: permissions)
        if path.isRoot { rootPermissionsChanged = true }
    }

    // MARK: - Merged view

    private func isCut(_ path: WorkspacePath) -> Bool {
        if cuts.contains(path) {
            return true
        }
        return cuts.contains { path.isWithin($0) }
    }

    private func upperEntry(_ path: WorkspacePath) async -> FileInfo? {
        try? await upper.stat(path: path)
    }

    private func lowerVisibleEntry(_ path: WorkspacePath) async -> FileInfo? {
        guard let lower, !isCut(path) else {
            return nil
        }
        return try? await lower.stat(path: path)
    }

    private func mergedEntry(_ path: WorkspacePath) async -> FileInfo? {
        if let info = await upperEntry(path) {
            return info
        }
        return await lowerVisibleEntry(path)
    }

    /// Resolve each component in the merged namespace before consulting a backing filesystem.
    /// A lower-layer ancestor link must never let that backend bypass cuts or upper entries.
    private func resolveMergedPath(
        _ path: WorkspacePath, followFinal: Bool = true, allowMissingAncestors: Bool = false, createParents: Bool = false
    ) async throws -> WorkspacePath {
        var current = WorkspacePath.root
        var pending = path.components
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." {
                continue
            }
            if component == ".." {
                guard !current.isRoot else { throw WorkspaceError.invalidPath(path.string) }
                current = current.dirname
                continue
            }
            let next = current.appending(component)
            let final = pending.isEmpty
            guard let info = await mergedEntry(next) else {
                if !final && createParents {
                    try await ensureUpperDirectories(for: next)
                    try await upper.createDirectory(path: next, recursive: false)
                    current = next
                    continue
                }
                if final || allowMissingAncestors {
                    current = next
                    continue
                }
                throw posixError(ENOENT)
            }
            if info.kind == .symlink && (!final || followFinal) {
                hops += 1
                guard hops <= 40 else {
                    throw posixError(ELOOP)
                }
                let target: String
                if await upperEntry(next) != nil {
                    target = try await upper.readSymlink(path: next)
                } else if let lower {
                    target = try await lower.readSymlink(path: next)
                } else {
                    throw posixError(ENOENT)
                }
                if target.utf8.first == 47 {
                    current = .root
                }
                pending = WorkspacePath.splitComponents(target) + pending
                continue
            }
            if !final && info.kind != .directory {
                throw posixError(ENOTDIR)
            }
            current = next
        }
        return current
    }

    /// Materializes every merged-visible ancestor directory of `path` into the upper layer,
    /// preserving lower-layer permissions. Creation operations may also create missing parents.
    private func ensureUpperDirectories(for path: WorkspacePath, createMissing: Bool = false) async throws {
        var current = WorkspacePath.root
        for component in path.dirname.components {
            current = current.appending(component)
            if let info = await upperEntry(current) {
                guard info.kind == .directory else { throw posixError(ENOTDIR) }
                continue
            }
            guard let info = await lowerVisibleEntry(current) else {
                guard createMissing else { throw posixError(ENOENT) }
                try await upper.createDirectory(path: current, recursive: false)
                continue
            }
            guard info.kind == .directory else {
                throw posixError(ENOTDIR)
            }
            try await upper.createDirectory(path: current, recursive: false)
            try await upper.setPermissions(path: current, permissions: info.permissions)
        }
    }

    /// Copies a lower-layer file or symlink into the upper layer as-is.
    private func copyUpLeaf(_ path: WorkspacePath, info: FileInfo) async throws {
        guard let lower else {
            throw posixError(ENOENT)
        }
        try await ensureUpperDirectories(for: path)
        switch info.kind {
        case .symlink:
            try await upper.createSymlink(path: path, target: lower.readSymlink(path: path))
        default:
            try await upper.writeFile(path: path, data: lower.readFile(path: path), append: false)
            try await upper.setPermissions(path: path, permissions: info.permissions)
        }
    }

    /// Materializes the merged subtree rooted at `path` into the upper layer so a whole-tree
    /// mutation (move or copy) can be delegated to the upper backend.
    private func materializeTree(_ path: WorkspacePath) async throws {
        guard let info = await mergedEntry(path) else {
            throw posixError(ENOENT)
        }

        if info.kind != .directory {
            if await upperEntry(path) == nil {
                try await copyUpLeaf(path, info: info)
            }
            return
        }

        if await upperEntry(path) == nil {
            try await ensureUpperDirectories(for: path)
            try await upper.createDirectory(path: path, recursive: true)
            try await upper.setPermissions(path: path, permissions: info.permissions)
        }

        if let lower, let lowerInfo = await lowerVisibleEntry(path), lowerInfo.kind == .directory {
            for entry in try await lower.listDirectory(path: path) {
                let child = path.appending(entry.name)
                if isCut(child) {
                    continue
                }
                try await materializeTree(child)
            }
        }
    }

    private func allMergedPaths() async -> [WorkspacePath] {
        var paths: [WorkspacePath] = [.root]
        var queue: [WorkspacePath] = [.root]
        var index = 0
        while index < queue.count {
            let directory = queue[index]
            index += 1
            guard let entries = try? await listDirectory(path: directory) else {
                continue
            }
            for entry in entries {
                let child = directory.appending(entry.name)
                paths.append(child)
                if entry.info.kind == .directory {
                    queue.append(child)
                }
            }
        }
        return paths
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
