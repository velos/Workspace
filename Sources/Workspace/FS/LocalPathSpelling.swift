import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import WorkspacePOSIX
#endif

/// Volume properties and Linux directory flags are stable under the documented
/// exclusion of concurrent host namespace/flag changes. Listings are never cached.
final class LocalPathSpelling: @unchecked Sendable {
    enum Policy {
        case exact, darwin, hfs, verifyByListing

        var verifiesCreation: Bool { self == .hfs || self == .verifyByListing }
    }
    private enum Volume { case policy(Policy), linuxFlags }
    private struct DirectoryID: Hashable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }
    private let lock = NSLock()
    private var volumes: [UInt64: Volume] = [:]
    private var directories: [DirectoryID: Policy] = [:]

    func forget(_ info: stat) {
        lock.lock()
        directories.removeValue(forKey: DirectoryID(info))
        lock.unlock()
    }

    func policy(for directory: Int32, info suppliedInfo: stat? = nil) throws -> Policy {
        var info = suppliedInfo ?? stat()
        if suppliedInfo == nil, fstat(directory, &info) != 0 { throw posix(errno) }
        let id = DirectoryID(info)
        lock.lock()
        let cached = volumes[id.device]
        let directoryPolicy = directories[id]
        lock.unlock()
        if let directoryPolicy { return directoryPolicy }
        let volume: Volume
        if let cached { volume = cached } else {
            volume = classify(directory)
            lock.lock()
            volumes[id.device] = volume
            lock.unlock()
        }
        switch volume {
        case let .policy(policy): return policy
        case .linuxFlags:
            #if canImport(Glibc)
            // O_PATH cannot service FS_IOC_GETFLAGS. Reopen the pinned directory
            // once per inode, not once per operation. Unavailable flags use listing.
            let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return .verifyByListing }
            defer { close(fd) }
            var flags: UInt32 = 0
            guard workspace_directory_flags(fd, &flags) == 0 else { return .verifyByListing }
            let policy: Policy = flags & 0x4000_0000 == 0 ? .exact : .verifyByListing // FS_CASEFOLD_FL
            lock.lock()
            // Bound memory on long-lived workspaces traversing many directories.
            // Eviction is safe: the next access simply inspects the flags again.
            if directories.count >= 4_096, directories[id] == nil {
                directories.removeAll(keepingCapacity: true)
            }
            directories[id] = policy
            lock.unlock()
            return policy
            #else
            return .verifyByListing
            #endif
        }
    }

    private func classify(_ fd: Int32) -> Volume {
        #if canImport(Darwin)
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { return .policy(.verifyByListing) }
        let capacity = MemoryLayout.size(ofValue: info.f_fstypename)
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        if type == "apfs" { return .policy(.darwin) }
        if type == "hfs" { return .policy(.hfs) }
        // In particular, exFAT/FSKit getattrlistat may report a primed lookup
        // alias, not the stored name. Only APFS and HFS use that API as evidence.
        return .policy(.verifyByListing)
        #else
        var type: UInt64 = 0
        guard workspace_filesystem_type(fd, &type) == 0 else { return .policy(.verifyByListing) }
        switch type {
        case 0xEF53, 0xF2F5_2010, 0xCA45_1A4E, 0x794C_7630, 0x0102_1994:
            return .linuxFlags // ext*, f2fs, bcachefs, overlayfs, tmpfs (casefold since 6.13)
        case 0x9123_683E, 0x8584_58F6:
            return .policy(.exact) // btrfs, ramfs
        case 0x5846_5342: // XFS ascii-ci is a volume property, not a directory flag.
            let readable = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard readable >= 0 else { return .policy(.verifyByListing) }
            defer { close(readable) }
            var insensitive: Int32 = 0
            guard workspace_xfs_case_insensitive(readable, &insensitive) == 0 else {
                return .policy(.verifyByListing)
            }
            return .policy(insensitive == 0 ? .exact : .verifyByListing)
        default: return .policy(.verifyByListing)
        }
        #endif
    }

    /// Aliases are ENOENT on lookup and EEXIST at mutation destinations. Never
    /// include the stored spelling in errors: authorization may have denied it.
    func check(parent: Int32, name: String, policy: Policy, creating: Bool, afterCreate: Bool = false) throws {
        guard name != "." else { return } // trusted resolved-directory sentinel
        switch policy {
        case .exact: return
        case .verifyByListing:
            var info = stat()
            let result = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW)
            if result < 0 && errno != ENOENT { throw posix(errno) }
            try Self.checkListing(name: name, exists: result == 0, creating: creating, afterCreate: afterCreate) {
                try Self.listNames(parent)
            }
        case .darwin, .hfs:
            #if canImport(Darwin)
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_NAME)
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 2048) { buffer in
                let result = getattrlistat(parent, name, &attributes, buffer.baseAddress!, buffer.count, UInt(FSOPT_NOFOLLOW))
                if result < 0 {
                    if errno == ENOENT && !afterCreate { return }
                    throw posix(errno)
                }
                let bytes = UnsafeRawBufferPointer(buffer)
                let length = Int(bytes.loadUnaligned(as: UInt32.self))
                let ref = bytes.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
                let start = 4 + Int(ref.attr_dataoffset)
                let count = Int(ref.attr_length)
                guard length <= buffer.count, start >= 12, count > 0,
                      start <= length, count <= length - start, buffer[start + count - 1] == 0 else {
                    throw posix(EIO)
                }
                guard bytes[start..<(start + count - 1)].elementsEqual(name.utf8) else {
                    throw Self.spellingMismatch(creating: creating, afterCreate: afterCreate)
                }
            }
            #else
            throw posix(ENOTSUP)
            #endif
        }
    }

    /// Shared by the real directory stream and fake listing sources in tests.
    /// An existing kernel lookup is not spelling evidence: its dentry may be an alias.
    static func checkListing(
        name: String, exists: Bool, creating: Bool, afterCreate: Bool = false,
        list: () throws -> [String]
    ) throws {
        guard exists else {
            if afterCreate { throw posix(ENOENT) }
            return // The caller uses O_EXCL (or the lookup syscall's ENOENT).
        }
        guard try list().contains(where: { $0.utf8.elementsEqual(name.utf8) }) else {
            throw spellingMismatch(creating: creating, afterCreate: afterCreate)
        }
    }

    private static func spellingMismatch(creating: Bool, afterCreate: Bool) -> NSError {
        guard afterCreate else { return posix(creating ? EEXIST : ENOENT) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(EILSEQ), userInfo: [
            NSLocalizedDescriptionKey:
                "This filesystem rewrites the requested name; use decomposed Unicode (NFD) on HFS+ or macOS exFAT.",
            NSLocalizedRecoverySuggestionErrorKey:
                "Use the exact spelling reported by directory listings.",
        ])
    }

    private static func listNames(_ parent: Int32) throws -> [String] {
        let fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix(errno) }
        guard let stream = fdopendir(fd) else {
            let error = errno
            close(fd)
            throw posix(error)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw posix(errno) }
                return names
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            // Unrepresentable entries cannot byte-match a valid Swift String.
            if let name { names.append(name) }
        }
    }

    private func posix(_ code: Int32) -> NSError { Self.posix(code) }
    private static func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
