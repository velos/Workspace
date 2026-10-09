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
public final class LocalFileSystem: FileSystem, @unchecked Sendable {
    /// Returns zero on success or a captured POSIX errno on failure. Injection is per-instance
    /// so unsupported filesystem behavior can be tested without mounts or global syscall hooks.
    typealias ExclusiveRename = @Sendable (Int32, String, Int32, String) -> Int32

    private let fileManager: FileManager
    private let exclusiveRename: ExclusiveRename
    private let stateLock = NSLock()
    private var configuration: ConfigurationSnapshot?

    private final class Descriptor: @unchecked Sendable {
        let value: Int32
        init(_ value: Int32) {
            self.value = value
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
    }

    // Glibc does not expose O_PATH without _GNU_SOURCE.
    private static var searchDirectoryFlags: Int32 {
        #if canImport(Darwin)
        O_SEARCH | O_DIRECTORY
        #else
        0x0020_0000 | O_DIRECTORY  // Linux O_PATH, from asm-generic/fcntl.h.
        #endif
    }

    private struct Entry {
        let parent: Descriptor
        let name: String
        let path: WorkspacePath
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
        let root = Descriptor(rootFD)
        stateLock.lock()
        defer {
            stateLock.unlock()
        }
        configuration = ConfigurationSnapshot(
            rootURL: url,
            resolvedRootPath: canonical,
            foundationRootPath: url.resolvingSymlinksInPath().standardizedFileURL.path,
            root: root
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

    private func metadata(_ entry: Entry) throws -> LocalStat {
        var value = LocalStat()
        try check(fstatat(entry.parent.value, entry.name, &value, AT_SYMLINK_NOFOLLOW))
        return value
    }

    private func linkTarget(_ entry: Entry) throws -> String {
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
                return String(decoding: bytes.prefix(count), as: UTF8.self)
            }
            bytes = [UInt8](repeating: 0, count: bytes.count * 2)
        }
    }

    /// Absolute disk symlink targets are host paths. Accept physical, Foundation-resolved, and
    /// configured root spellings, mapping each to the retained descriptor with exact boundaries.
    private func absoluteComponents(_ target: String, configuration: ConfigurationSnapshot) throws -> [String] {
        for root in [configuration.resolvedRootPath, configuration.foundationRootPath, configuration.rootURL.path] {
            if target == root {
                return []
            }
            let prefix = root == "/" ? "/" : root + "/"
            if target.hasPrefix(prefix) {
                return String(target.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            }
        }
        throw WorkspaceError.invalidPath(target)
    }

    private func resolve(
        _ path: WorkspacePath, followFinal: Bool, createParents: Bool = false,
        configuration: ConfigurationSnapshot? = nil
    ) throws -> Entry {
        let config = try configuration ?? requireConfiguration()
        guard !path.string.contains("\u{0}") else {
            throw WorkspaceError.invalidPath(path.string)
        }
        var pending = path.components
        var current = config.root
        var names: [String] = []
        var hops = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." || name.isEmpty {
                continue
            }
            if name == ".." {
                guard !names.isEmpty else {
                    throw WorkspaceError.invalidPath(path.string)
                }
                names.removeLast()
                current = config.root
                for ancestor in names {
                    let entry = Entry(parent: current, name: ancestor, path: .root)
                    current = try openEntry(entry, flags: Self.searchDirectoryFlags)
                }
                continue
            }
            let final = pending.isEmpty
            let entry = Entry(
                parent: current, name: name,
                path: WorkspacePath(unchecked: "/" + (names + [name]).joined(separator: "/")))
            if final && !followFinal {
                return entry
            }
            var info: LocalStat
            do {
                info = try metadata(entry)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                if final {
                    return entry
                }
                guard createParents else {
                    throw error
                }
                let result = mkdirat(entry.parent.value, name, 0o755)
                if result < 0 && errno != EEXIST {
                    try check(result)
                }
                info = try metadata(entry)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= 40 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
                }
                let target = try linkTarget(entry)
                if target.hasPrefix("/") {
                    pending = try absoluteComponents(target, configuration: config) + pending
                    current = config.root
                    names = []
                } else {
                    pending = target.split(separator: "/").map(String.init) + pending
                }
                continue
            }
            if final {
                return entry
            }
            current = try openEntry(entry, flags: Self.searchDirectoryFlags)
            names.append(name)
        }
        return Entry(parent: current, name: ".", path: WorkspacePath(unchecked: "/" + names.joined(separator: "/")))
    }

    private func openEntry(_ entry: Entry, flags: Int32, mode: mode_t = 0o666) throws -> Descriptor {
        let fd = openat(entry.parent.value, entry.name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        let openError = errno
        try check(fd, errorCode: openError)
        return Descriptor(fd)
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
            modificationDate: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9))
    }

    /// See ``FileSystem/stat(path:)``.
    ///
    /// Uses lstat semantics: inspect the link itself, including dangling or external links.
    public func stat(path: WorkspacePath) async throws -> FileInfo {
        try fileInfo(metadata(resolve(path, followFinal: false)), path: path)
    }

    private func names(in directory: Descriptor) throws -> [String] {
        // openat(".") gives an independent directory offset; dup would share it.
        let fd = openat(directory.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
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
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                result.append(name)
            }
        }
        return result.sorted()
    }

    /// See ``FileSystem/listDirectory(path:)``.
    public func listDirectory(path: WorkspacePath) async throws -> [DirectoryEntry] {
        let directory = try openEntry(resolve(path, followFinal: true), flags: O_RDONLY | O_DIRECTORY)
        return try names(in: directory).map { name in
            let child = path.appending(name)
            return DirectoryEntry(
                name: name, info: fileInfo(try metadata(Entry(parent: directory, name: name, path: child)), path: child)
            )
        }
    }

    private func readHandle(_ path: WorkspacePath) throws -> FileHandle {
        let fd = try openEntry(resolve(path, followFinal: true), flags: O_RDONLY | O_NONBLOCK)
        var info = LocalStat()
        try check(fstat(fd.value, &info))
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(info.st_mode & S_IFMT == S_IFDIR ? EISDIR : EINVAL))
        }
        return FileHandle(fileDescriptor: try duplicateDescriptor(fd.value), closeOnDealloc: true)
    }

    private func duplicateDescriptor(_ fd: Int32) throws -> Int32 {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        try check(copy)
        return copy
    }

    /// See ``FileSystem/readFile(path:)``.
    public func readFile(path: WorkspacePath) async throws -> Data {
        let handle = try readHandle(path)
        defer {
            try? handle.close()
        }
        return try handle.readToEnd() ?? Data()
    }

    /// See ``FileSystem/readFile(path:offset:length:)``.
    public func readFile(path: WorkspacePath, offset: UInt64, length: Int?) async throws -> Data {
        if let length, length < 0 {
            throw WorkspaceError.unsupported("read length must not be negative")
        }
        let handle = try readHandle(path)
        defer {
            try? handle.close()
        }
        let size = try handle.seekToEnd()
        guard offset < size else {
            return Data()
        }
        try handle.seek(toOffset: offset)
        if let length {
            return try handle.read(upToCount: length) ?? Data()
        }
        return try handle.readToEnd() ?? Data()
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
        let entry = try resolve(path, followFinal: false, createParents: true)
        try write(data, to: openEntry(entry, flags: O_WRONLY | O_CREAT | O_EXCL))
    }

    /// See ``FileSystem/writeFile(path:data:append:)``.
    ///
    /// Replacement is atomic and breaks hard-link sharing; append preserves the opened inode.
    /// Symlink targets are resolved explicitly before either operation.
    public func writeFile(path: WorkspacePath, data: Data, append: Bool) async throws {
        let entry = try resolve(path, followFinal: true, createParents: true)
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
        let temporary = ".workspace-" + UUID().uuidString
        let temporaryEntry = Entry(parent: entry.parent, name: temporary, path: entry.path)
        let fd = try openEntry(temporaryEntry, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer {
            _ = unlinkat(entry.parent.value, temporary, 0)
        }
        try body(fd)
        try check(renameat(entry.parent.value, temporary, entry.parent.value, entry.name))
    }

    /// See ``FileSystem/createDirectory(path:recursive:)``.
    public func createDirectory(path: WorkspacePath, recursive: Bool) async throws {
        let entry = try resolve(path, followFinal: true, createParents: recursive)
        let result = mkdirat(entry.parent.value, entry.name, 0o755)
        if result < 0 && errno == EEXIST && recursive {
            _ = try openEntry(entry, flags: Self.searchDirectoryFlags)
            return
        }
        try check(result)
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
                let directory = try openEntry(entry, flags: O_RDONLY | O_DIRECTORY)
                for name in try names(in: directory) {
                    try removeEntry(
                        Entry(parent: directory, name: name, path: entry.path.appending(name)), recursive: true)
                }
            }
            try check(unlinkat(entry.parent.value, entry.name, AT_REMOVEDIR))
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
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
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
        let destination = try resolve(destinationPath, followFinal: false, createParents: true, configuration: config)
        let renameError = exclusiveRename(source.parent.value, source.name, destination.parent.value, destination.name)
        if renameError == 0 {
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
        let info = try metadata(source)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard recursive else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EISDIR))
            }
            let input = try openEntry(source, flags: O_RDONLY | O_DIRECTORY)
            try check(mkdirat(destination.parent.value, destination.name, 0o755))
            let output = try openEntry(destination, flags: O_RDONLY | O_DIRECTORY)
            for name in try names(in: input) {
                try copyEntry(
                    Entry(parent: input, name: name, path: source.path.appending(name)),
                    to: Entry(parent: output, name: name, path: destination.path.appending(name)), recursive: true)
            }
            try check(fchmod(output.value, info.st_mode & 0o7777))
        case S_IFLNK:
            let target = try linkTarget(source)
            try removeEntry(destination, recursive: false)
            try check(symlinkat(target, destination.parent.value, destination.name))
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
        let destination = try resolve(destinationPath, followFinal: false, createParents: true, configuration: config)
        guard source.path != destination.path,
            !(destination.path.string.hasPrefix(source.path.string + "/")) && !source.path.isRoot
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        try copyEntry(source, to: destination, recursive: recursive)
    }

    /// See ``FileSystem/createSymlink(path:target:)``.
    public func createSymlink(path: WorkspacePath, target: String) async throws {
        _ = try WorkspacePath(validating: target, relativeTo: path.dirname)
        let entry = try resolve(path, followFinal: false, createParents: true)
        try check(symlinkat(target, entry.parent.value, entry.name))
    }

    /// See ``FileSystem/createHardLink(path:target:)``.
    public func createHardLink(path: WorkspacePath, target: WorkspacePath) async throws {
        let config = try requireConfiguration()
        let source = try resolve(target, followFinal: true, configuration: config)
        let destination = try resolve(path, followFinal: false, createParents: true, configuration: config)
        // No AT_SYMLINK_FOLLOW: a concurrent final-component swap must not dereference a link.
        try check(linkat(source.parent.value, source.name, destination.parent.value, destination.name, 0))
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

    /// See ``FileSystem/exists(path:)``.
    ///
    /// Uses lstat semantics, so a final dangling symlink still exists.
    public func exists(path: WorkspacePath) async -> Bool {
        (try? metadata(resolve(path, followFinal: false))) != nil
    }

    /// See ``FileSystem/capabilities()``.
    public func capabilities() async -> FileSystemFeatures {
        [.symlinks, .hardLinks, .permissions, .realPathResolution]
    }

    /// See ``FileSystem/glob(pattern:currentDirectory:)``.
    public func glob(pattern: String, currentDirectory: WorkspacePath) async throws -> [WorkspacePath] {
        let pattern = try WorkspacePath(validating: pattern, relativeTo: currentDirectory)
        if !WorkspacePath.containsGlob(pattern.string) {
            return await exists(path: pattern) ? [pattern] : []
        }
        let regex = try NSRegularExpression(pattern: WorkspacePath.globToRegex(pattern.string))
        var paths: [WorkspacePath] = [.root]
        var queue: [WorkspacePath] = [.root]
        while !queue.isEmpty {
            let directory = queue.removeFirst()
            let entries: [DirectoryEntry]
            do {
                entries = try await listDirectory(path: directory)
            } catch let error as NSError
                where !directory.isRoot
                && error.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(ENOENT), Int(ENOTDIR)].contains(error.code)
            {
                continue
            }
            for entry in entries {
                paths.append(entry.info.path)
                if entry.info.kind == .directory {
                    queue.append(entry.info.path)
                }
            }
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
}

enum FSEventsChangeStream {
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    private final class Observation: @unchecked Sendable {
        private let stream: FSEventStreamRef
        private let box: Unmanaged<Box>

        init(root: URL, continuation: AsyncStream<Void>.Continuation) throws {
            box = .passRetained(Box(continuation))
            var context = FSEventStreamContext(
                version: 0,
                info: box.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().continuation.yield()
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
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
        var failure: Error?
        let stream = AsyncStream<Void> { continuation in
            do {
                let observation = try Observation(root: root, continuation: continuation)
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
}
#endif
