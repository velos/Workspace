import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native notifications already carry stored spellings. Parse and rebase their
/// UTF-8 components without a second filesystem lookup (the entry may be gone).
func nativeChangePath(_ name: String, relativeTo root: String) -> WorkspacePath? {
    guard let absolute = try? WorkspacePath(name), let root = try? WorkspacePath(root),
          absolute.isWithin(root) else { return nil }
    return WorkspacePath(normalizing: absolute.components.dropFirst(root.components.count).joined(separator: "/"))
}

enum DirectoryChangeStream {
    static func observe(_ directory: URL, recursive: Bool = false) throws -> AsyncStream<Void> {
        #if os(macOS)
        return try FSEventsChangeStream.observe(directory)
        #elseif canImport(Darwin)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return AsyncStream { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [source] in
                _ = source
                continuation.yield()
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
        #elseif canImport(Glibc)
        return unscopedChanges(try observeSignals(directory, recursive: recursive))
        #else
        throw WorkspaceError.unsupported("filesystem change streams are not supported on this platform")
        #endif
    }

    static func observeSignals(_ directory: URL, recursive: Bool = false) throws -> AsyncStream<FileSystemChangeSignal> {
        #if os(macOS)
        return try FSEventsChangeStream.observeSignals(directory)
        #elseif canImport(Glibc)
        var failure: Error?
        let stream = AsyncStream<FileSystemChangeSignal> { continuation in
            do {
                let observation = try LinuxDirectoryObservation(directory: directory, recursive: recursive, continuation: continuation)
                continuation.onTermination = { _ in observation.cancel() }
            } catch {
                failure = error
                continuation.finish()
            }
        }
        if let failure { throw failure }
        return stream
        #else
        let stream = try observe(directory, recursive: recursive)
        return AsyncStream { continuation in
            let task = Task {
                for await _ in stream where !Task.isCancelled { continuation.yield(.rescan) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
    }

}

#if canImport(Glibc)
private final class LinuxDirectoryObservation: @unchecked Sendable {
    private let directory: URL
    private let recursive: Bool
    private let continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var pathsByWatch: [Int32: Set<PathName>] = [:]
    // Keep the root's parent watched so recreating the root can restore coverage even
    // when it was absent during the IN_DELETE_SELF/IN_MOVE_SELF rescan.
    private var parentWatch: Int32?
    private var pendingIgnored: Set<Int32> = []

    private func removeWatch(_ watch: Int32) {
        if inotify_rm_watch(descriptor, watch) == 0 { pendingIgnored.insert(watch) }
    }

    init(
        directory: URL,
        recursive: Bool,
        continuation: AsyncStream<FileSystemChangeSignal>.Continuation
    ) throws {
        self.directory = directory
        self.recursive = recursive
        self.continuation = continuation
        descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: DispatchQueue(label: "Workspace.inotify", qos: .utility)
        )
        source.setCancelHandler { [descriptor] in close(descriptor) }
        do {
            try addMissingWatches(requireRoot: true)
        } catch {
            // A dispatch source must be resumed before destruction, even on setup failure.
            source.cancel()
            source.resume()
            throw error
        }
        source.setEventHandler { [weak self] in self?.handleEvents() }
        source.resume()
    }

    func cancel() { source.cancel() }

    private func handleEvents() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var received = false
        var retired = Set<Int32>()
        var ignored = Set<Int32>()
        var overflow = false
        var reconcile = false
        var unknown = false
        var changed: [WorkspacePath: FileSystemChangeSignal.Scope] = [:]
        // Drain first, retire each descriptor once, then reconcile against the live tree.
        // No event performs a scan of the path cache or a scan of descendant prefixes.
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.withUnsafeBytes { bytes in
                var offset = 0
                let headerSize = MemoryLayout<inotify_event>.size
                while offset + headerSize <= count {
                    let event = bytes.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                    let recordSize = headerSize + Int(event.len)
                    guard recordSize <= count - offset else { break }
                    defer { offset += recordSize }
                    if event.mask & UInt32(IN_IGNORED) != 0, pendingIgnored.remove(event.wd) != nil { continue }
                    if event.wd == parentWatch {
                        if event.mask & UInt32(IN_IGNORED) != 0 {
                            parentWatch = nil
                            received = true
                        } else {
                            let nameBytes = bytes[(offset + headerSize)..<(offset + recordSize)].prefix { $0 != 0 }
                            guard nameBytes.elementsEqual(directory.lastPathComponent.utf8) else { continue }
                        }
                    }
                    received = true
                    let nameBytes = bytes[(offset + headerSize)..<(offset + recordSize)].prefix { $0 != 0 }
                    guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                        unknown = true
                        continue
                    }
                    if LocalAtomicTemporaryName.matches(name) { continue }
                    let structural = event.mask & UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED) != 0
                    let isDirectory = name.isEmpty || event.mask & UInt32(IN_ISDIR) != 0
                    let scope: FileSystemChangeSignal.Scope = isDirectory ? (structural ? .recursive : .shallow) : .entry
                    if let watched = pathsByWatch[event.wd] {
                        for parent in watched {
                            let absolute = name.isEmpty ? parent.string : parent.string + "/" + name
                            if let path = nativeChangePath(absolute, relativeTo: directory.path) {
                                changed[path] = max(changed[path] ?? .entry, scope)
                            } else { unknown = true }
                        }
                    } else { reconcile = true; unknown = true }
                    // A directory can become watchable after a permission change.
                    if isDirectory && (structural || event.mask & UInt32(IN_ATTRIB) != 0) {
                        reconcile = true
                    }
                    if event.mask & UInt32(IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF) != 0 {
                        retired.insert(event.wd)
                        if event.mask & UInt32(IN_IGNORED) != 0 { ignored.insert(event.wd) }
                    }
                    if event.mask & UInt32(IN_Q_OVERFLOW) != 0 { overflow = true }
                }
            }
        }
        guard received else { return }
        if overflow {
            var watches = Set(pathsByWatch.keys)
            if let parentWatch { watches.insert(parentWatch) }
            for watch in watches where !ignored.contains(watch) { removeWatch(watch) }
            pathsByWatch.removeAll(keepingCapacity: true)
            parentWatch = nil
        } else {
            for watch in retired {
                if pathsByWatch.removeValue(forKey: watch) != nil {
                    if !ignored.contains(watch) { removeWatch(watch) }
                }
            }
        }
        do {
            if reconcile || overflow { try addMissingWatches(requireRoot: false) }
        } catch {
            continuation.finish()
            cancel()
            return
        }
        if overflow || unknown { continuation.yield(.rescan) }
        else if !changed.isEmpty { continuation.yield(.paths(changed)) }
    }

    private func addMissingWatches(requireRoot: Bool) throws {
        let paths: [String]
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [],
                errorHandler: { _, _ in true }
            )
            var discovered = [directory.path]
            while let url = enumerator?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    discovered.append(url.path)
                }
            }
            paths = discovered
        } else {
            paths = [directory.path]
        }
        let mask = UInt32(
            IN_CREATE | IN_DELETE | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB
                | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR
        )
        var nextByWatch: [Int32: Set<PathName>] = [:]
        for path in paths {
            // The kernel returns the current wd for the same inode and a new wd for a
            // replacement. Re-register every discovered path, rather than trusting its name.
            let watch = path.withCString { inotify_add_watch(descriptor, $0, mask) }
            if watch < 0 {
                let code = errno
                // Resource exhaustion means coverage is incomplete, even if the root
                // watch succeeded. End observation so accounting falls back to walks.
                if code == ENOSPC || code == EMFILE || code == ENFILE || code == ENOMEM {
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                if path.utf8.elementsEqual(directory.path.utf8), requireRoot || (code != ENOENT && code != ENOTDIR) {
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                // Children can disappear, become files, or deny reads during enumeration.
                // Skip them and keep registering later siblings; future events will retry.
                continue
            }
            nextByWatch[watch, default: []].insert(PathName(path))
        }
        // A descriptor can serve multiple paths. Remove it only after every live path has
        // been registered, and only if the new reverse map no longer references that wd.
        for watch in pathsByWatch.keys where nextByWatch[watch] == nil {
            removeWatch(watch)
        }
        pathsByWatch = nextByWatch
        if parentWatch == nil, directory.path != "/" {
            let watch = directory.deletingLastPathComponent().path.withCString {
                inotify_add_watch(descriptor, $0, UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ONLYDIR))
            }
            // The parent may grant traversal without read access (for example 0711).
            // Its watch improves root-recreation coverage but cannot disable a valid root.
            if watch >= 0 { parentWatch = watch }
            else if errno == ENOSPC || errno == EMFILE || errno == ENFILE || errno == ENOMEM {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }
}
#endif

/// Retains compatibility for checkpoint stores and callers of the original Void stream.
func unscopedChanges(_ stream: AsyncStream<FileSystemChangeSignal>) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task {
            for await _ in stream where !Task.isCancelled { continuation.yield() }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
