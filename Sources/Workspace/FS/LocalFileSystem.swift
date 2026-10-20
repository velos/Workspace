import Foundation

#if canImport(Darwin)
import Darwin
private typealias LocalStat = Darwin.stat
#if os(macOS)
import CoreServices
#endif
#elseif canImport(Glibc)
import Glibc
private typealias LocalStat = Glibc.stat
#endif

/// A disk-backed filesystem rooted at a concrete directory on the host filesystem.
///
/// Operations retain the configured root descriptor and walk directories with `O_NOFOLLOW`.
/// Symlinks are expanded explicitly, with a 40-hop limit; final syscalls never follow links.
/// This is a safety layer, not a sandbox: a host process can relocate an already-open directory
/// outside the root, change hard-linked data, or mutate entries during recursive operations.
/// Watch subscriptions still use the configured URL and are not descriptor-pinned.
public final class LocalFileSystem: FileSystem, TraversingFileSystem, PreviewSemanticsFileSystem, PotentialPathResolvingFileSystem, @unchecked Sendable {
    /// Returns zero on success or a captured POSIX errno on failure. Injection is per-instance
    /// so unsupported filesystem behavior can be tested without mounts or global syscall hooks.
    typealias ExclusiveRename = @Sendable (Int32, String, Int32, String) -> Int32

    private let fileManager: FileManager
    private let spelling = LocalPathSpelling()
    private let exclusiveRename: ExclusiveRename
    private let stateLock = NSLock()
    private var configuration: ConfigurationSnapshot?

    #if DEBUG
    private var spellingChecks = 0
    var spellingCheckCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return spellingChecks
    }
    #endif

    private final class Descriptor: @unchecked Sendable {
        let value: Int32
        let spellingPolicy: LocalPathSpelling.Policy
        let directoryInfo: LocalStat?
        init(_ value: Int32, spellingPolicy: LocalPathSpelling.Policy, directoryInfo: LocalStat? = nil) {
            self.value = value
            self.spellingPolicy = spellingPolicy
            self.directoryInfo = directoryInfo
        }
        deinit {
            close(value)
        }
    }

    private struct ConfigurationSnapshot {
        let rootURL: URL
        let resolvedRootPath: String
        let foundationRootPath: String
        let root: Descriptor
        let rootSpelling: String?
    }

    // Glibc does not expose O_PATH without _GNU_SOURCE.
    private static var searchDirectoryFlags: Int32 {
        #if canImport(Darwin)
        O_SEARCH | O_DIRECTORY
        #else
        0x0020_0000 | O_DIRECTORY  // Linux O_PATH, from asm-generic/fcntl.h.
        #endif
    }

    private struct Entry: Sendable {
        let parent: Descriptor
        let name: String
        private var resolvedPath: WorkspacePath?
        private var pathComponents: [String] = []
        var path: WorkspacePath {
            resolvedPath ?? WorkspacePath(unchecked: "/" + pathComponents.joined(separator: "/"))
        }
        var isVerified = false
        var directoryInfo: LocalStat?

        // Every variable *at() name comes from an immutable, validated Entry.
        // Even a future parser bug must not pass a multi-component path to the kernel.
        init(parent: Descriptor, name: String, path: WorkspacePath) throws {
            try LocalFileSystem.validateEntryName(name)
            self.parent = parent
            self.name = name
            self.resolvedPath = path
        }

        // Ancestor opens usually never consume the path. Retain components and
        // construct it only for a returned target or diagnostic.
        init(parent: Descriptor, name: String, components: [String]) throws {
            try LocalFileSystem.validateEntryName(name)
            self.parent = parent
            self.name = name
            self.pathComponents = components
        }

        func atPath(_ path: WorkspacePath) -> Entry {
            var entry = self
            entry.resolvedPath = path
            entry.pathComponents = []
            return entry
        }

        // Names emitted by readdir already have stored spelling. This initializer
        // still applies the jail's byte-level single-component validation.
        init(parent: Descriptor, storedName: String, path: WorkspacePath) throws {
            try self.init(parent: parent, name: storedName, path: path)
            isVerified = true
        }

        func requireVerified() throws {
            guard isVerified else { throw WorkspaceError.invalidPath(path.string) }
        }

        // The only permitted dot entry refers to an already resolved directory fd.
        init(directory: Descriptor, path: WorkspacePath) {
            self.parent = directory
            self.name = "."
            self.resolvedPath = path
            self.isVerified = true
            self.directoryInfo = directory.directoryInfo
        }
    }

    private static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.utf8.contains(47), !name.utf8.contains(0) else {
            throw WorkspaceError.invalidPath(name)
        }
    }

    /// Creates an unconfigured disk-backed filesystem.
    init(
        fileManager: FileManager = .default,
        exclusiveRename: @escaping ExclusiveRename = LocalFileSystem.renameExclusively
    ) {
        self.fileManager = fileManager
        self.exclusiveRename = exclusiveRename
    }

    /// Creates and configures a disk-backed filesystem rooted at `rootDirectory`.
    convenience init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.init(fileManager: fileManager)
        try applyConfiguration(rootDirectory: rootDirectory)
    }

    /// Creates a disk-backed filesystem with a retained root directory descriptor.
    public convenience init(root: URL, fileManager: FileManager = .default) throws {
        try self.init(rootDirectory: root, fileManager: fileManager)
    }

    /// See ``FileSystem/configure(rootDirectory:)``.
    func configure(rootDirectory: URL) async throws {
        try applyConfiguration(rootDirectory: rootDirectory)
    }

    /// Applies configuration synchronously for adapters with synchronous initializers.
    internal func applyConfiguration(rootDirectory: URL) throws {
        let url = rootDirectory.standardizedFileURL
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        guard let physical = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            free(physical)
        }
        let canonical = String(cString: physical)
        let rootFD = open(canonical, Self.searchDirectoryFlags | O_NOFOLLOW | O_CLOEXEC)
        let openError = errno
        try check(rootFD, errorCode: openError)
        let root = try directoryDescriptor(rootFD)
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        configuration = ConfigurationSnapshot(
            rootURL: url,
            resolvedRootPath: canonical,
            foundationRootPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
            root: root,
            rootSpelling: root.spellingPolicy == .darwin ? Self.directoryPath(root.value) : nil
        )
    }

    private func requireConfiguration() throws -> ConfigurationSnapshot {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        guard let configuration else {
            throw WorkspaceError.unsupported("local filesystem requires a root")
        }
        return configuration
    }

    private func check(_ result: Int32, errorCode: Int32 = errno) throws {
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    private func directoryDescriptor(_ fd: Int32, info suppliedInfo: LocalStat? = nil) throws -> Descriptor {
        do {
            var info = suppliedInfo ?? LocalStat()
            #if canImport(Glibc)
            // Flags belong to this opened inode. A concurrent workspace rename
            // can replace a previously statted directory with a casefolded one.
            try check(fstat(fd, &info))
            #else
            if suppliedInfo == nil { try check(fstat(fd, &info)) }
            #endif
            return Descriptor(fd, spellingPolicy: try spelling.policy(for: fd, info: info), directoryInfo: info)
        }
        catch { close(fd); throw error }
    }

    private func checkSpelling(_ entry: Entry, creating: Bool = false) throws {
        #if DEBUG
        stateLock.lock()
        spellingChecks += 1
        stateLock.unlock()
        #endif
        try spelling.check(parent: entry.parent.value, name: entry.name,
                           policy: entry.parent.spellingPolicy, creating: creating)
    }

    private func verifiedEntry(_ entry: Entry, creating: Bool = false) throws -> Entry {
        try checkSpelling(entry, creating: creating)
        var verified = entry
        verified.isVerified = true
        return verified
    }

    private func metadata(_ entry: Entry) throws -> LocalStat {
        try entry.requireVerified()
        var value = LocalStat()
        try check(fstatat(entry.parent.value, entry.name, &value, AT_SYMLINK_NOFOLLOW))
        return value
    }

    private func linkTarget(_ entry: Entry) throws -> String {
        try entry.requireVerified()
        var bytes = [UInt8](repeating: 0, count: 256)
        while true {
            let count = bytes.withUnsafeMutableBytes {
                readlinkat(
                    entry.parent.value, entry.name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
            }
            guard count >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if count < bytes.count {
                guard let target = String(bytes: bytes.prefix(count), encoding: .utf8) else {
                    throw WorkspaceError.invalidPath("non-UTF-8 symlink target at \(entry.path)")
                }
                return target
            }
            bytes = [UInt8](repeating: 0, count: bytes.count * 2)
        }
    }

    /// Absolute disk symlink targets are host paths. Accept physical, Foundation-resolved, and
    /// configured root spellings, mapping each to the retained descriptor with exact boundaries.
    private func absoluteComponents(_ target: String, configuration: ConfigurationSnapshot) throws -> [String] {
        // Keep dot components for descriptor-relative resolution; lexical normalization
        // here would erase symlink traversal before a subsequent "..".
        let targetComponents = WorkspacePath.splitComponents(target)
        for root in [configuration.resolvedRootPath, configuration.foundationRootPath, configuration.rootURL.path] {
            let rootComponents = WorkspacePath.splitComponents(root)
            if targetComponents.starts(with: rootComponents, by: { $0.utf8.elementsEqual($1.utf8) }) {
                return Array(targetComponents.dropFirst(rootComponents.count))
            }
        }
        throw WorkspaceError.invalidPath(target)
    }

    private enum ResolutionRetry: Error { case componentChecks }

    /// F_GETPATH is used only for APFS directories, never final file descriptors:
    /// directories have one physical path, whereas a file may have many hard links.
    private static func directoryPath(_ fd: Int32) -> String? {
        #if canImport(Darwin)
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN)) { buffer in
            guard fcntl(fd, F_GETPATH, buffer.baseAddress!) == 0 else { return nil }
            return String(validatingCString: buffer.baseAddress!)
        }
        #else
        return nil
        #endif
    }

    private func verifyParent(
        _ directory: Descriptor, names: [String], configuration: ConfigurationSnapshot,
        batchAPFS: Bool
    ) throws {
        guard batchAPFS, !names.isEmpty else { return }
        guard directory.spellingPolicy == .darwin,
              let root = configuration.rootSpelling,
              let stored = Self.directoryPath(directory.value) else {
            throw ResolutionRetry.componentChecks
        }
        let expected = (root == "/" ? "" : root) + "/" + names.joined(separator: "/")
        #if canImport(Darwin)
        guard expected.utf8.count < Int(MAXPATHLEN) else { throw ResolutionRetry.componentChecks }
        #endif
        guard stored.utf8.elementsEqual(expected.utf8) else {
            // The host may have relocated the pinned root or an ancestor since
            // configuration. Only component checks can distinguish that from an alias.
            throw ResolutionRetry.componentChecks
        }
    }

    private func resolve(
        _ path: WorkspacePath, followFinal: Bool, createParents: Bool = false,
        allowMissingAncestors: Bool = false, creating: Bool = false,
        configuration: ConfigurationSnapshot? = nil
    ) throws -> Entry {
        let config = try configuration ?? requireConfiguration()
        do {
            return try resolveComponents(path, followFinal: followFinal, createParents: createParents,
                allowMissingAncestors: allowMissingAncestors, creating: creating, configuration: config,
                batchAPFS: config.rootSpelling != nil)
        } catch is ResolutionRetry {
            // F_GETPATH failure/mismatch/overflow or crossing a non-APFS mount: do not trust
            // an incomplete path. Retry descriptor-relative per-component checks.
            return try resolveComponents(path, followFinal: followFinal, createParents: createParents,
                allowMissingAncestors: allowMissingAncestors, creating: creating, configuration: config,
                batchAPFS: false)
        }
    }

    private func resolveComponents(
        _ path: WorkspacePath, followFinal: Bool, createParents: Bool,
        allowMissingAncestors: Bool, creating: Bool, configuration config: ConfigurationSnapshot,
        batchAPFS: Bool
    ) throws -> Entry {
        guard !path.string.utf8.contains(0) else { throw WorkspaceError.invalidPath(path.string) }
        var pending = path.components
        let root = config.root
        var current = root
        var names: [String] = []
        var missingAncestor = false
        var hops = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." || name.isEmpty { continue }
            if name == ".." {
                guard !names.isEmpty else { throw WorkspaceError.invalidPath(path.string) }
                if !missingAncestor {
                    try verifyParent(current, names: names, configuration: config, batchAPFS: batchAPFS)
                }
                names.removeLast()
                current = root
                missingAncestor = false
                for ancestor in names {
                    let entry = try verifiedEntry(Entry(parent: current, name: ancestor, path: .root), creating: creating)
                    do {
                        current = try openEntry(entry, flags: Self.searchDirectoryFlags)
                    } catch let error as NSError where allowMissingAncestors
                        && error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                        missingAncestor = true
                        break
                    }
                }
                continue
            }
            let final = pending.isEmpty
            var entry = try Entry(parent: current, name: name,
                components: names + [name])
            if missingAncestor {
                // Only potential-path resolution consumes unverified entries, and
                // only their path strings. I/O helpers require a verified Entry.
                if final { return entry }
                names.append(name)
                continue
            }
            if !batchAPFS { entry = try verifiedEntry(entry, creating: creating) }
            if final && !followFinal {
                if batchAPFS {
                    try verifyParent(current, names: names, configuration: config, batchAPFS: true)
                    entry = try verifiedEntry(entry, creating: creating)
                }
                return entry
            }
            // A no-follow directory open checks the type and pins an ancestor
            // without a preceding lstat. APFS defers its spelling check to the
            // same parent boundary as the metadata route below.
            if !final {
                let fd = openat(entry.parent.value, entry.name, Self.searchDirectoryFlags | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    current = try directoryDescriptor(fd)
                    if batchAPFS && current.spellingPolicy != .darwin {
                        throw ResolutionRetry.componentChecks
                    }
                    names.append(entry.name)
                    continue
                }
                let code = errno
                guard code == ELOOP || code == ENOTDIR || code == ENOENT else {
                    if batchAPFS {
                        try verifyParent(current, names: names, configuration: config, batchAPFS: true)
                        _ = try verifiedEntry(entry, creating: creating)
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
            }
            var info = LocalStat()
            let status = fstatat(entry.parent.value, entry.name, &info, AT_SYMLINK_NOFOLLOW)
            let statusError = errno
            // Directory traversal may defer spelling checks until the parent fd is
            // verified as a whole. Before reading a link, returning a target, or
            // creating anything, both the parent and current name are verified.
            let traverseDirectory = status == 0 && info.st_mode & S_IFMT == S_IFDIR && !final
            if batchAPFS && !traverseDirectory {
                try verifyParent(current, names: names, configuration: config, batchAPFS: true)
                entry = try verifiedEntry(entry, creating: creating)
            }
            if status < 0 {
                guard statusError == ENOENT else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(statusError))
                }
                if final { return entry }
                if allowMissingAncestors {
                    names.append(name)
                    missingAncestor = true
                    continue
                }
                guard createParents else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
                let result = mkdirat(entry.parent.value, entry.name, 0o755)
                if result < 0 && errno != EEXIST { try check(result) }
                if result == 0 { try validateCreated(entry, directory: true) }
                else { try checkSpelling(entry, creating: true) }
                info = try metadata(entry)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= 40 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP)) }
                let target = try linkTarget(entry)
                if target.utf8.first == 47 {
                    pending = try absoluteComponents(target, configuration: config) + pending
                    current = root
                    names = []
                } else {
                    pending = WorkspacePath.splitComponents(target) + pending
                }
                continue
            }
            if info.st_mode & S_IFMT == S_IFDIR { entry.directoryInfo = info }
            if final { return entry }
            if batchAPFS && !entry.isVerified {
                // Like the fast open above, this may open an unverified directory
                // with O_NOFOLLOW, retains its mandatory policy, and cannot expose
                // data or mutate it until verifyParent succeeds at the boundary.
                let fd = openat(entry.parent.value, entry.name, Self.searchDirectoryFlags | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    let error = errno
                    try verifyParent(current, names: names, configuration: config, batchAPFS: true)
                    _ = try verifiedEntry(entry, creating: creating)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
                }
                current = try directoryDescriptor(fd, info: info)
                if current.spellingPolicy != .darwin { throw ResolutionRetry.componentChecks }
            } else {
                current = try openEntry(entry, flags: Self.searchDirectoryFlags, directoryInfo: info)
            }
            names.append(name)
        }
        if !missingAncestor {
            try verifyParent(current, names: names, configuration: config, batchAPFS: batchAPFS)
        }
        return Entry(directory: current, path: WorkspacePath(unchecked: "/" + names.joined(separator: "/")))
    }

    private func openEntry(
        _ entry: Entry, flags: Int32, mode: mode_t = 0o666, directoryInfo: LocalStat? = nil
    ) throws -> Descriptor {
        try entry.requireVerified()
        var openFlags = flags | O_NOFOLLOW | O_CLOEXEC
        let verifyCreation = flags & O_CREAT != 0 && entry.parent.spellingPolicy.verifiesCreation
        if verifyCreation { openFlags |= O_EXCL }
        var fd = openat(entry.parent.value, entry.name, openFlags, mode)
        let created = verifyCreation && fd >= 0
        if fd < 0 && errno == EEXIST && verifyCreation && flags & O_EXCL == 0 {
            // Open an existing entry without O_CREAT: cleanup must never unlink
            // an old file, even if another process removes it between these calls.
            fd = openat(entry.parent.value, entry.name, (openFlags & ~(O_CREAT | O_EXCL)), mode)
        }
        let openError = errno
        try check(fd, errorCode: openError)
        if created {
            do { try validateCreated(entry, directory: false) }
            catch { close(fd); throw error }
        }
        if flags & O_DIRECTORY != 0 {
            return try directoryDescriptor(fd, info: directoryInfo ?? entry.directoryInfo)
        }
        return Descriptor(fd, spellingPolicy: .exact) // non-directory fd; never a resolution parent
    }

    /// HFS+ can rewrite a new name; unknown filesystems must prove preservation too.
    /// This is called only after a successful exclusive creation, before filling it.
    private func validateCreated(_ entry: Entry, directory: Bool) throws {
        if entry.parent.spellingPolicy.verifiesCreation {
            do {
                try spelling.check(parent: entry.parent.value, name: entry.name,
                                   policy: entry.parent.spellingPolicy, creating: true, afterCreate: true)
            } catch {
                let result = unlinkat(entry.parent.value, entry.name, directory ? AT_REMOVEDIR : 0)
                if result < 0 {
                    throw WorkspaceRollbackError(originalError: error,
                        rollbackError: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                }
                throw error
            }
        }
        if directory {
            // Inode reuse after a workspace-created directory must not reuse flags
            // cached for an earlier directory, potentially under a different parent.
            spelling.forget(try metadata(entry))
        }
    }

    private func validateMoved(_ source: Entry, to destination: Entry) throws {
        guard destination.parent.spellingPolicy.verifiesCreation else { return }
        do {
            try spelling.check(parent: destination.parent.value, name: destination.name,
                               policy: destination.parent.spellingPolicy, creating: true, afterCreate: true)
        } catch {
            // A rename is not a disposable creation. Preserve the source on rewrite.
            if renameat(destination.parent.value, destination.name, source.parent.value, source.name) < 0 {
                throw WorkspaceRollbackError(originalError: error,
                    rollbackError: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
            throw error
        }
    }

    private func fileInfo(_ info: LocalStat, path: WorkspacePath) -> FileInfo {
        let type = info.st_mode & S_IFMT
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return FileInfo(
            path: path, kind: type == S_IFLNK ? .symlink : (type == S_IFDIR ? .directory : .file),
            size: UInt64(max(0, info.st_size)), permissions: POSIXPermissions(Int(info.st_mode & 0o7777)),
            modificationDate: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9),
            identity: FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino)),
            linkCount: type == S_IFDIR ? nil : UInt64(info.st_nlink))
    }

    /// Holds only the active directory ancestry, for this read-only call. Descents and
    /// file opens use O_NOFOLLOW; metadata and link targets use the same parent fd.
    nonisolated(nonsending) package func walk(at path: WorkspacePath, skippingUnreadableDirectories: Bool, skippingVanishedEntries: Bool = false,
                      visit: FileSystemWalkVisitor) async throws {
        let entry: Entry
        let info: LocalStat
        do {
            let resolved = try resolve(path, followFinal: false)
            entry = resolved.atPath(path)
            info = try metadata(entry)
        } catch {
            if Snapshot.isMissingEntry(error) { return }
            throw error
        }
        try await walkEntry(entry, info: info, depth: 0, skippingUnreadableDirectories: skippingUnreadableDirectories,
            skippingVanishedEntries: skippingVanishedEntries, visit: visit)
    }

    nonisolated(nonsending) private func walkEntry(_ entry: Entry, info: LocalStat, depth: Int, skippingUnreadableDirectories: Bool,
        skippingVanishedEntries: Bool = false,
                           visit: FileSystemWalkVisitor) async throws {
        try Task.checkCancellation()
        // Bound this call's retained ancestry, leaving room for unrelated operations at
        // the usual 256-descriptor soft limit. The fallback resolves each operation anew.
        if depth == 32 {
            let current: LocalStat
            do { current = try self.metadata(resolve(entry.path, followFinal: false)) }
            catch {
                guard skippingVanishedEntries, Snapshot.isMissingEntry(error) else { throw error }
                return
            }
            guard current.st_dev == info.st_dev, current.st_ino == info.st_ino else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
            }
            try await walkUsingPaths(at: entry.path, skippingUnreadableDirectories: skippingUnreadableDirectories,
                skippingVanishedEntries: skippingVanishedEntries,
                                     requireExisting: true, visit: visit)
            return
        }
        let metadata = fileInfo(info, path: entry.path)
        if metadata.kind == .directory {
            let directory: Descriptor
            let children: [(entry: Entry, info: LocalStat, key: String)]
            do {
                directory = try openEntry(entry, flags: O_RDONLY | O_DIRECTORY)
                children = try names(in: directory, consumingOffset: true).compactMap { name -> (entry: Entry, info: LocalStat, key: String)? in
                    let child = try Entry(parent: directory, storedName: name, path: entry.path.appending(name))
                    let info: LocalStat
                    do { info = try self.metadata(child) }
                    catch {
                        guard skippingVanishedEntries, Snapshot.isMissingEntry(error) else { throw error }
                        return nil
                    }
                    return (child, info, walkSortKey(name: name, isDirectory: info.st_mode & S_IFMT == S_IFDIR))
                }.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            } catch {
                guard skippingUnreadableDirectories, isSkippableWalkError(error, at: entry.path) else { throw error }
                try await visit(metadata, { _ in throw WorkspaceError.unsupported("cannot read a directory") },
                                { throw WorkspaceError.unsupported("not a symlink") })
                return
            }
            for (child, info, _) in children {
                try await walkEntry(child, info: info, depth: depth + 1, skippingUnreadableDirectories: skippingUnreadableDirectories,
                    skippingVanishedEntries: skippingVanishedEntries, visit: visit)
            }
        }
        try await visit(metadata, { length in try self.readEntry(entry, length: length) },
                        { try self.linkTarget(entry) })
    }

    private func openRegularFile(_ entry: Entry) throws -> (Descriptor, LocalStat) {
        let fd = try openEntry(entry, flags: O_RDONLY | O_NONBLOCK)
        var info = LocalStat()
        try check(fstat(fd.value, &info))
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(info.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL))
        }
        return (fd, info)
    }

    private func readEntry(_ entry: Entry, offset: UInt64 = 0, length: Int?) throws -> Data {
        if let length, length < 0 { throw WorkspaceError.unsupported("read length must not be negative") }
        let (fd, info) = try openRegularFile(entry)
        let size = UInt64(max(0, info.st_size))
        if offset > 0 {
            guard offset < size else { return Data() }
            if lseek(fd.value, off_t(offset), SEEK_SET) < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let limit = length ?? Int.max
        // Allocate for the observed size, bounded by the range and a 256 MiB initial
        // allocation ceiling. Read directly into the result, then probe EOF and
        // accommodate concurrent growth (or files larger than the initial allocation).
        var data = Data(count: min(limit, 256 * 1_024 * 1_024, Int(clamping: size - min(offset, size))))
        var filled = 0
        while filled < limit {
            if filled == data.count {
                var extra = [UInt8](repeating: 0, count: min(4_096, limit - filled))
                let count = extra.withUnsafeMutableBytes { read(fd.value, $0.baseAddress!, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if count == 0 { break }
                // Probe EOF before reserving more space, so unchanged small files
                // do not allocate a large spare buffer. Once growth is observed,
                // double the result (at least 1 MiB) and read directly into it.
                let capacity = filled + min(limit - filled, max(1_024 * 1_024, filled))
                data.append(extra, count: count)
                filled += count
                data.count = capacity
            } else {
                let count = data.withUnsafeMutableBytes {
                    read(fd.value, $0.baseAddress!.advanced(by: filled), min($0.count - filled, Int(Int32.max)))
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if count == 0 { break }
                filled += count
            }
        }
        data.count = filled
        return data
    }

    /// See ``FileSystem/stat(path:)``.
    ///
    /// Uses lstat semantics: inspect the link itself, including dangling or external links.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try fileInfo(metadata(resolve(path, followFinal: false)), path: path)
    }

    private func names(in directory: Descriptor, consumingOffset: Bool = false) throws -> [String] {
        // Walks own a fresh descriptor and enumerate it only once. Other callers need
        // an independent offset, especially when their descriptor is the pinned root.
        let fd = consumingOffset ? try duplicateDescriptor(directory.value)
            : openat(directory.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let stream = fdopendir(fd) else {
            let error = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        defer {
            closedir(stream)
        }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw WorkspaceError.invalidPath("non-UTF-8 directory entry") }
            if name != "." && name != ".." {
                result.append(name)
            }
        }
        return consumingOffset ? result : result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let directory = try openEntry(resolve(path, followFinal: true), flags: O_RDONLY | O_DIRECTORY)
        return try names(in: directory).map { name in
            let child = path.appending(name)
            return DirectoryEntry(
                name: name, info: fileInfo(try metadata(Entry(parent: directory, storedName: name, path: child)), path: child)
            )
        }
    }

    private func readHandle(_ path: WorkspacePath) throws -> FileHandle {
        let (fd, _) = try openRegularFile(resolve(path, followFinal: true))
        return FileHandle(fileDescriptor: try duplicateDescriptor(fd.value), closeOnDealloc: true)
    }

    private func duplicateDescriptor(_ fd: Int32) throws -> Int32 {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        try check(copy)
        return copy
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        try readEntry(resolve(path, followFinal: true), length: nil)
    }

    /// See ``FileSystem/readFile(path:offset:length:)``.
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        try readEntry(resolve(path, followFinal: true), offset: offset, length: length)
    }

    private actor ChunkReader {
        private var handle: FileHandle?
        init(_ handle: FileHandle) {
            self.handle = handle
        }
        func next(size: Int) throws -> Data? {
            guard let handle else {
                return nil
            }
            do {
                try Task.checkCancellation()
                if let data = try handle.read(upToCount: size), !data.isEmpty {
                    return data
                }
                try handle.close()
                self.handle = nil
                return nil
            } catch {
                try? handle.close()
                self.handle = nil
                throw error
            }
        }
    }

    /// See ``FileSystem/readFileChunks(path:chunkSize:)``.
    ///
    /// Opens once, then reads at most one chunk per consumer request. No producer or byte queue.
    public func readFileChunks(path: WorkspacePath, chunkSize: Int) async throws -> AsyncThrowingStream<Data, Error> {
        guard chunkSize > 0 else {
            throw WorkspaceError.unsupported("chunk size must be positive")
        }
        let reader = ChunkReader(try readHandle(path))
        return AsyncThrowingStream(unfolding: {
            try await reader.next(size: chunkSize)
        })
    }

    private func write(_ data: Data, to descriptor: Descriptor) throws {
        let handle = FileHandle(fileDescriptor: try duplicateDescriptor(descriptor.value), closeOnDealloc: true)
        defer {
            try? handle.close()
        }
        try handle.write(contentsOf: data)
    }

    /// See ``FileSystem/createFile(path:data:)``.
    public func createFile(path: WorkspacePath, data: Data) async throws {
        let entry = try resolve(path, followFinal: false, createParents: true, creating: true)
        try write(data, to: openEntry(entry, flags: O_WRONLY | O_CREAT | O_EXCL))
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    ///
    /// Replacement writes follow in-root final symlinks and atomically replace the target,
    /// breaking its hard-link sharing. Links that escape the root are rejected.
    /// Appends preserve the opened inode.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let entry = try resolve(path, followFinal: true, createParents: true, creating: true)
        if append {
            try write(data, to: openEntry(entry, flags: O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK))
        } else {
            let existing: LocalStat?
            do {
                existing = try metadata(entry)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                existing = nil
            }
            try replace(entry) { output in
                try self.write(data, to: output)
                if let existing, existing.st_mode & S_IFMT == S_IFREG {
                    try check(fchmod(output.value, existing.st_mode & 0o7777))
                }
            }
        }
    }

    private func replace(_ entry: Entry, body: (Descriptor) throws -> Void) throws {
        try entry.requireVerified()
        let temporary = LocalAtomicTemporaryName.make()
        let temporaryEntry = try verifiedEntry(Entry(parent: entry.parent, name: temporary, path: entry.path), creating: true)
        let fd = try openEntry(temporaryEntry, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer {
            _ = unlinkat(temporaryEntry.parent.value, temporaryEntry.name, 0)
        }
        try body(fd)
        try checkSpelling(entry, creating: true)
        try check(renameat(temporaryEntry.parent.value, temporaryEntry.name, entry.parent.value, entry.name))
        try validateCreated(entry, directory: false)
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let entry = try resolve(path, followFinal: true, createParents: recursive, creating: true)
        let result = mkdirat(entry.parent.value, entry.name, 0o755)
        if result < 0 && errno == EEXIST && recursive {
            _ = try openEntry(entry, flags: Self.searchDirectoryFlags)
            return
        }
        try check(result)
        try validateCreated(entry, directory: true)
    }

    private func removeEntry(_ entry: Entry, recursive: Bool) throws {
        let info: LocalStat
        do {
            info = try metadata(entry)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            if recursive {
                let directory = try openEntry(entry, flags: O_RDONLY | O_DIRECTORY, directoryInfo: info)
                for name in try names(in: directory) {
                    try removeEntry(
                        Entry(parent: directory, storedName: name, path: entry.path.appending(name)), recursive: true)
                }
            }
            try check(unlinkat(entry.parent.value, entry.name, AT_REMOVEDIR))
            spelling.forget(info)
        } else {
            try check(unlinkat(entry.parent.value, entry.name, 0))
        }
    }

    /// See ``FileSystem/remove(path:recursive:)``.
    ///
    /// Unlinks the entry itself; never follows a final symlink, even for recursive removal.
    public func remove(path: WorkspacePath, recursive: Bool) async throws {
        guard !path.isRoot else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        do {
            try removeEntry(resolve(path, followFinal: false), recursive: recursive)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR))
        {
            // A path beneath a regular file can't exist, so removing it is the same no-op as a missing path.
            return
        }
    }

    /// See ``FileSystem/move(from:to:)``.
    ///
    /// Uses exclusive rename where supported. Otherwise, destination checking followed by plain
    /// rename provides best-effort no-clobber behavior: a concurrent creator can still be replaced.
    /// Both paths remain descriptor-pinned in either case.
    public func move(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath) async throws {
        let config = try requireConfiguration()
        let source = try resolve(sourcePath, followFinal: false, configuration: config)
        let destination = try resolve(destinationPath, followFinal: false, createParents: true, creating: true, configuration: config)
        let renameError = exclusiveRename(source.parent.value, source.name, destination.parent.value, destination.name)
        if renameError == 0 {
            try validateMoved(source, to: destination)
            return
        }
        #if canImport(Darwin)
        let requiresFallback = renameError == ENOTSUP || renameError == ENOSYS
        #else
        let requiresFallback = renameError == EINVAL || renameError == ENOSYS
        #endif
        guard requiresFallback else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
        }
        try renameWithoutExclusiveSupport(source, to: destination)
    }

    private func renameWithoutExclusiveSupport(_ source: Entry, to destination: Entry) throws {
        do {
            _ = try metadata(destination)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // Reuse the resolved descriptors. Only no-clobber atomicity is relaxed, not containment.
            try check(renameat(source.parent.value, source.name, destination.parent.value, destination.name))
            try validateMoved(source, to: destination)
            return
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
    }

    private static func renameExclusively(
        sourceFD: Int32, sourceName: String, destinationFD: Int32, destinationName: String
    ) -> Int32 {
        #if canImport(Darwin)
        let result = renameatx_np(sourceFD, sourceName, destinationFD, destinationName, UInt32(RENAME_EXCL))
        let renameError = errno
        return result == 0 ? 0 : renameError
        #else
        // Some Swift Glibc modules omit renameat2. Resolve the libc entry point without an
        // architecture-specific syscall number; a missing symbol is treated like missing kernel support.
        typealias RenameAt2 = @convention(c) (
            Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32
        ) -> Int32
        guard let symbol = dlsym(nil, "renameat2") else {
            return ENOSYS
        }
        let rename = unsafeBitCast(symbol, to: RenameAt2.self)
        return sourceName.withCString { source in
            destinationName.withCString { destination in
                let result = rename(sourceFD, source, destinationFD, destination, 1) // RENAME_NOREPLACE.
                let renameError = errno
                return result == 0 ? 0 : renameError
            }
        }
        #endif
    }

    private func copyEntry(_ source: Entry, to destination: Entry, recursive: Bool) throws {
        let destination = try verifiedEntry(destination, creating: true)
        let info = try metadata(source)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard recursive else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
            }
            let input = try openEntry(source, flags: O_RDONLY | O_DIRECTORY, directoryInfo: info)
            try check(mkdirat(destination.parent.value, destination.name, 0o755))
            try validateCreated(destination, directory: true)
            let output = try openEntry(destination, flags: O_RDONLY | O_DIRECTORY)
            for name in try names(in: input) {
                try copyEntry(
                    Entry(parent: input, storedName: name, path: source.path.appending(name)),
                    to: Entry(parent: output, name: name, path: destination.path.appending(name)), recursive: true)
            }
            try check(fchmod(output.value, info.st_mode & 0o7777))
        case S_IFLNK:
            let target = try linkTarget(source)
            try removeEntry(destination, recursive: false)
            try check(symlinkat(target, destination.parent.value, destination.name))
            try validateCreated(destination, directory: false)
        case S_IFREG:
            let input = try openEntry(source, flags: O_RDONLY | O_NONBLOCK)
            let handle = FileHandle(fileDescriptor: try duplicateDescriptor(input.value), closeOnDealloc: true)
            defer {
                try? handle.close()
            }
            try replace(destination) { output in
                while let data = try handle.read(upToCount: 65536), !data.isEmpty {
                    try write(data, to: output)
                }
                try check(fchmod(output.value, info.st_mode & 0o7777))
            }
        default: throw WorkspaceError.unsupported("copying special files is not supported")
        }
    }

    /// See ``FileSystem/copy(from:to:recursive:)``.
    ///
    /// Copies contents and POSIX mode bits; extended attributes and ACLs are not copied.
    public func copy(from sourcePath: WorkspacePath, to destinationPath: WorkspacePath, recursive: Bool) async throws {
        let config = try requireConfiguration()
        let source = try resolve(sourcePath, followFinal: false, configuration: config)
        let destination = try resolve(destinationPath, followFinal: false, createParents: true, creating: true, configuration: config)
        guard !destination.path.isWithin(source.path)
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        try copyEntry(source, to: destination, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        let entry = try resolve(path, followFinal: false, createParents: true, creating: true)
        try check(symlinkat(target, entry.parent.value, entry.name))
        try validateCreated(entry, directory: false)
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let config = try requireConfiguration()
        let source = try resolve(target, followFinal: true, configuration: config)
        let destination = try resolve(path, followFinal: false, createParents: true, creating: true, configuration: config)
        // No AT_SYMLINK_FOLLOW: a concurrent final-component swap must not dereference a link.
        try check(linkat(source.parent.value, source.name, destination.parent.value, destination.name, 0))
        try validateCreated(destination, directory: false)
    }

    /// See ``FileSystem/readSymlink(path:)``.
    public func readSymlink(path: WorkspacePath) async throws -> String {
        try linkTarget(resolve(path, followFinal: false))
    }

    /// See ``FileSystem/setPermissions(path:permissions:)``.
    ///
    /// Changes the resolved target without following a concurrently substituted final symlink.
    /// On Linux before 6.6, glibc emulates `fchmodat(AT_SYMLINK_NOFOLLOW)` via `/proc/self/fd`;
    /// chmod therefore fails if `/proc` is not mounted.
    public func setPermissions(path: WorkspacePath, permissions: POSIXPermissions) async throws {
        let entry = try resolve(path, followFinal: true)
        try check(fchmodat(entry.parent.value, entry.name, mode_t(permissions.rawValue), AT_SYMLINK_NOFOLLOW))
    }

    /// See ``FileSystem/resolveRealPath(path:)``.
    ///
    /// Returns the resolved virtual path relative to the retained root, never a fallback `/`.
    public func resolveRealPath(path: WorkspacePath) async throws -> WorkspacePath {
        let entry = try resolve(path, followFinal: true)
        _ = try metadata(entry)
        return entry.path
    }

    package func resolvePotentialPath(path: WorkspacePath) async throws -> WorkspacePath {
        try resolve(path, followFinal: true, allowMissingAncestors: true).path
    }

    /// See ``FileSystem/exists(path:)``.
    ///
    /// Uses lstat semantics, so a final dangling symlink still exists.
    public func exists(path: WorkspacePath) async -> Bool {
        (try? metadata(resolve(path, followFinal: false))) != nil
    }

    /// See ``FileSystem/capabilities()``.
    public func capabilities() async -> FileSystemFeatures {
        [.symlinks, .hardLinks, .permissions, .realPathResolution, .replacementFollowsFinalSymlink]
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let pattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(pattern.string) {
            return await exists(path: pattern) ? [pattern] : []
        }
        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(pattern.string))
        var paths: [WorkspacePath] = []
        try await walk(at: .root, skippingUnreadableDirectories: true) { info, _, _ in
            paths.append(info.path)
        }
        return paths.filter {
            regex.firstMatch(in: $0.string, range: NSRange($0.string.startIndex..., in: $0.string)) != nil
        }.sorted()
    }
}

#if os(macOS)
extension LocalFileSystem: FileSystemChangeSource {
    /// See ``FileSystemChangeSource/changes()``.
    public func changes() async throws -> AsyncStream<Void> {
        let root = try requireConfiguration().rootURL
        return try FSEventsChangeStream.observe(root)
    }

    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        let configuration = try requireConfiguration()
        return try FSEventsChangeStream.observeSignals(configuration.rootURL, resolvedRootPath: configuration.resolvedRootPath)
    }
}

enum FSEventsChangeStream {
    // FileEvents supplies item flags; directory metadata/listing changes do not
    // invalidate descendants unless structural or loss/coalescing flags say so.
    static func scope(for flags: FSEventStreamEventFlags) -> FileSystemChangeSignal.Scope? {
        let unknown = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags & unknown != 0 { return nil }
        if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .recursive }
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed)
            return flags & structural != 0 ? .recursive : .shallow
        }
        if flags & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0 { return .entry }
        return nil // No item type: do not assume directory-level coverage is complete.
    }

    /// Stream-local identity distinguishes late item events for the existing root
    /// from replacement of the watched directory. Native names need no spelling lookup.
    struct EventMapper {
        let root: String
        private let initialIdentity: FileIdentity?
        #if DEBUG
        private let trace = ProcessInfo.processInfo.environment["WORKSPACE_FSEVENTS_TRACE"] == "1"
        #endif

        init(root: String) {
            self.root = root
            initialIdentity = Self.identity(at: root)
        }

        private static func identity(at path: String) -> FileIdentity? {
            var info = LocalStat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            return FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
        }

        func signal(for events: [(path: String, flags: FSEventStreamEventFlags)]) -> FileSystemChangeSignal? {
            let currentIdentity = Self.identity(at: root)
            #if DEBUG
            if trace {
                for event in events {
                    let message = "Workspace FSEvents root=\(String(reflecting: root)) path=\(String(reflecting: event.path)) flags=0x\(String(event.flags, radix: 16)) initialIdentity=\(String(describing: initialIdentity)) currentIdentity=\(String(describing: currentIdentity))\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
            #endif
            guard let initialIdentity, currentIdentity == initialIdentity else { return .rescan }
            var changed: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
            for event in events {
                guard var scope = scope(for: event.flags),
                      let path = nativeChangePath(event.path, relativeTo: root) else { return .rescan }
                if path.isRoot {
                    // Coalesced subtree coverage is still mandatory, even for an
                    // unchanged root. Ordinary root item events only affect its listing.
                    if event.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 { return .rescan }
                    scope = .shallow
                }
                if LocalAtomicTemporaryName.matches(path.name) { continue }
                changed[path] = max(changed[path] ?? .entry, scope)
            }
            return changed.isEmpty ? nil : .paths(changed)
        }
    }

    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
        let mapper: EventMapper
        init(_ continuation: AsyncStream<FileSystemChangeSignal>.Continuation, resolvedRootPath: String) {
            self.continuation = continuation
            self.mapper = EventMapper(root: resolvedRootPath)
        }
    }

    private final class Observation: @unchecked Sendable {
        private let stream: FSEventStreamRef
        private let box: Unmanaged<Box>

        init(root: URL, resolvedRootPath: String, continuation: AsyncStream<FileSystemChangeSignal>.Continuation) throws {
            box = .passRetained(Box(continuation, resolvedRootPath: resolvedRootPath))
            var context = FSEventStreamContext(
                version: 0,
                info: box.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
                let events = (0..<count).map { (path: names[$0], flags: flags[$0]) }
                if let signal = box.mapper.signal(for: events) {
                    box.continuation.yield(signal)
                }
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.04,
                flags
            ) else {
                box.release()
                throw WorkspaceError.unsupported("could not create an FSEvents stream")
            }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                box.release()
                throw WorkspaceError.unsupported("could not start an FSEvents stream")
            }
        }

        func cancel() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
        }
    }

    static func observe(_ root: URL) throws -> AsyncStream<Void> {
        let signals = try observeSignals(root)
        return unscopedChanges(signals)
    }

    static func observeSignals(_ root: URL, resolvedRootPath: String? = nil) throws -> AsyncStream<FileSystemChangeSignal> {
        let canonical: String
        if let resolvedRootPath { canonical = resolvedRootPath }
        else if let path = realpath(root.path, nil) {
            canonical = String(cString: path)
            free(path)
        } else { canonical = root.path }
        var failure: Error?
        let stream = AsyncStream<FileSystemChangeSignal> { continuation in
            do {
                let observation = try Observation(root: root, resolvedRootPath: canonical, continuation: continuation)
                continuation.onTermination = { _ in observation.cancel() }
            } catch {
                failure = error
                continuation.finish()
            }
        }
        if let failure { throw failure }
        return stream
    }
}
#elseif os(Linux)
extension LocalFileSystem: FileSystemChangeSource {
    /// See ``FileSystemChangeSource/changes()``.
    public func changes() async throws -> AsyncStream<Void> {
        try DirectoryChangeStream.observe(requireConfiguration().rootURL, recursive: true)
    }

    public func changeSignals() async throws -> AsyncStream<FileSystemChangeSignal> {
        try DirectoryChangeStream.observeSignals(requireConfiguration().rootURL, recursive: true)
    }
}
#endif

extension LocalFileSystem {
    package func previewSemantics(at path: WorkspacePath) async -> FileSystemPreviewSemantics {
        .init(preservesOverwritePermissions: true, followsDirectorySymlinks: true,
              followsPermissionSymlinks: true, createsWriteParents: true)
    }
}
