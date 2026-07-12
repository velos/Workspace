import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        return AsyncStream { continuation in
            do {
                let observation = try LinuxDirectoryObservation(
                    directory: directory,
                    recursive: recursive,
                    continuation: continuation
                )
                continuation.onTermination = { _ in observation.cancel() }
            } catch {
                continuation.finish()
            }
        }
        #else
        throw WorkspaceError.unsupported("filesystem change streams are not supported on this platform")
        #endif
    }
}

#if canImport(Glibc)
private final class LinuxDirectoryObservation: @unchecked Sendable {
    private let directory: URL
    private let recursive: Bool
    private let continuation: AsyncStream<Void>.Continuation
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private var watchesByPath: [String: Int32] = [:]

    init(
        directory: URL,
        recursive: Bool,
        continuation: AsyncStream<Void>.Continuation
    ) throws {
        self.directory = directory
        self.recursive = recursive
        self.continuation = continuation
        descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        do {
            try addMissingWatches()
        } catch {
            close(descriptor)
            throw error
        }
        source.setEventHandler { [weak self] in self?.handleEvents() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }

    private func handleEvents() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var received = false
        while read(descriptor, &buffer, buffer.count) > 0 { received = true }
        guard received else { return }
        try? addMissingWatches()
        continuation.yield()
    }

    private func addMissingWatches() throws {
        let paths: [String]
        if recursive {
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
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
        watchesByPath = watchesByPath.filter { FileManager.default.fileExists(atPath: $0.key) }
        let mask = UInt32(
            IN_CREATE | IN_DELETE | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB
                | IN_DELETE_SELF | IN_MOVE_SELF
        )
        for path in paths where watchesByPath[path] == nil {
            let watch = path.withCString { inotify_add_watch(descriptor, $0, mask) }
            guard watch >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            watchesByPath[path] = watch
        }
    }
}
#endif
