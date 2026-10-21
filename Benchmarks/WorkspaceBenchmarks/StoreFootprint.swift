#if os(macOS) || os(Linux)
import Foundation

/// Logical persistence writes estimated outside timing. Appends count growth;
/// replaced/new files count their final size. This cannot see overwritten bytes
/// beyond the final extent, deleted/transient files, or filesystem write amplification.
struct StoreFootprint {
    struct File {
        var size: Int64
        var modificationDate: Date?
        var inode: UInt64?
    }
    var files: [String: File] = [:]

    static func capture(_ directory: URL) throws -> StoreFootprint {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return StoreFootprint() }
        guard let enumerator = manager.enumerator(atPath: directory.path) else {
            throw BenchmarkError.message("cannot enumerate checkpoint store")
        }
        var result = StoreFootprint()
        for case let path as String in enumerator {
            let attributes = try manager.attributesOfItem(
                atPath: directory.appendingPathComponent(path).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            result.files[path] = File(
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            )
        }
        return result
    }

    func written(since before: StoreFootprint) -> (bytes: Int64, files: Int64) {
        var bytes: Int64 = 0
        var count: Int64 = 0
        for (path, file) in files {
            if let old = before.files[path] {
                // Acquiring a store lock can touch an unchanged empty lock file.
                // This is metadata activity, not a content write.
                if old.size == 0, file.size == 0, old.inode == file.inode { continue }
                guard
                    old.size != file.size || old.modificationDate != file.modificationDate
                        || old.inode != file.inode
                else { continue }
                bytes +=
                    old.inode == file.inode && file.size > old.size ? file.size - old.size : file.size
            } else {
                bytes += file.size
            }
            count += 1
        }
        return (bytes, count)
    }
}

#endif
