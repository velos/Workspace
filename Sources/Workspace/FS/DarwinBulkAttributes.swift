#if canImport(Darwin)
import Darwin
import Foundation

/// A directory's records are committed only after the complete enumeration succeeds.
/// Unsupported devices are remembered per LocalFileSystem; transient errors only
/// abandon this directory. No descriptors or entry metadata survive a walk.
final class DarwinBulkAttributes: @unchecked Sendable {
    typealias Read = @Sendable (Int32, UnsafeMutablePointer<attrlist>, UnsafeMutableRawPointer, Int, UInt64) -> Int32
    typealias MountFlags = @Sendable (Int32) -> UInt32?
    private let read: Read
    private let mountFlags: MountFlags
    private let lock = NSLock()
    private var unsupported: Set<dev_t> = []

    init(read: @escaping Read = { getattrlistbulk($0, $1, $2, $3, $4) },
         mountFlags: @escaping MountFlags = { fd in
             var volume = statfs()
             return fstatfs(fd, &volume) == 0 ? volume.f_flags : nil
         }) {
        self.read = read
        self.mountFlags = mountFlags
    }

    struct Record {
        let name: String
        // Directories (including mount points) and special files retain lstat.
        let info: stat?
    }

    private enum Failure: Error { case malformed, missingAttributes }
    private struct VanishedEntry: Error { let code: Int }

    func entries(in fd: Int32, device: dev_t, skippingVanishedEntries: Bool = false) throws -> [Record]? {
        lock.lock()
        let disabled = unsupported.contains(device)
        lock.unlock()
        if disabled { return nil }
        // ATTR_CMN_ACCESSMASK can describe effective rather than stored mode:
        // set-ID bits are dropped when the reported owner is unknown, observed
        // on APFS mounts with nosuid/noowners. Unknown owners on eligible mounts
        // fall back per entry in parse(_:request:).
        // Also exclude ownership overrides and quarantine conservatively. nodev
        // only affects special-file operations (those entries already use stat).
        // Cache exclusions, never eligibility: a later remount must be rechecked.
        guard let flags = mountFlags(fd) else { return nil }
        if flags & UInt32(MNT_NOSUID | MNT_IGNORE_OWNERSHIP | MNT_QUARANTINE) != 0 {
            lock.lock()
            unsupported.insert(device)
            lock.unlock()
            return nil
        }
        do { return try enumerate(fd) }
        catch {
            // A bulk record already listed this child. Restarting a strict walk
            // could hide its disappearance, unlike the original readdir + lstat.
            if let vanished = error as? VanishedEntry, !skippingVanishedEntries {
                throw NSError(domain: NSPOSIXErrorDomain, code: vanished.code)
            }
            let code = (error as NSError).code
            if error as? Failure == .missingAttributes ||
                ((error as NSError).domain == NSPOSIXErrorDomain &&
                 [Int(ENOTSUP), Int(ENOSYS), Int(EINVAL)].contains(code)) {
                lock.lock()
                unsupported.insert(device)
                lock.unlock()
            }
            return nil
        }
    }

    private func enumerate(_ fd: Int32) throws -> [Record] {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME)
        request.commonattr |= UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
        request.commonattr |= UInt32(ATTR_CMN_OWNERID | ATTR_CMN_ACCESSMASK | ATTR_CMN_FILEID)
        request.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)
        defer { buffer.deallocate() }
        var records: [Record] = []
        while true {
            let count = read(fd, &request, buffer, 64 * 1024, UInt64(FSOPT_PACK_INVAL_ATTRS))
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { return records }
            var offset = 0
            for _ in 0..<count {
                guard offset <= 64 * 1024 - 4 else { throw Failure.malformed }
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 4, length <= 64 * 1024 - offset else { throw Failure.malformed }
                let bytes = UnsafeRawBufferPointer(start: buffer.advanced(by: offset), count: length)
                records.append(try parse(bytes, request: request))
                offset += length
            }
        }
    }

    private func parse(_ bytes: UnsafeRawBufferPointer, request: attrlist) throws -> Record {
        // attrlist fields are packed on 4-byte boundaries, even for 64-bit values.
        var cursor = 4
        func take<T>(_ type: T.Type) throws -> T {
            guard MemoryLayout<T>.size <= bytes.count - cursor else { throw Failure.malformed }
            defer { cursor += MemoryLayout<T>.size }
            return bytes.loadUnaligned(fromByteOffset: cursor, as: T.self)
        }
        let returned = try take(attribute_set_t.self)
        let error = try take(UInt32.self)
        guard returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 else { throw Failure.missingAttributes }
        if error == UInt32(ENOENT) || error == UInt32(ENOTDIR) { throw VanishedEntry(code: Int(error)) }
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        guard returned.commonattr & request.commonattr == request.commonattr else { throw Failure.missingAttributes }
        let referenceOffset = cursor
        let reference = try take(attrreference_t.self)
        let device = try take(dev_t.self)
        let type = try take(UInt32.self)
        let modified = try take(timespec.self)
        let owner = try take(uid_t.self)
        let mode = try take(UInt32.self)
        let inode = try take(UInt64.self)
        // File-group fields are absent for directories even with PACK_INVAL_ATTRS.
        let links = type == 2 ? 0 : try take(UInt32.self)
        let size = type == 2 ? 0 : try take(off_t.self)
        let start = referenceOffset + Int(reference.attr_dataoffset)
        let length = Int(reference.attr_length)
        guard start >= cursor, length > 1, start <= bytes.count,
              length <= bytes.count - start, bytes[start + length - 1] == 0 else { throw Failure.malformed }
        let nameBytes = bytes[start..<(start + length - 1)]
        guard !nameBytes.contains(0), !nameBytes.contains(47),
              let name = String(bytes: nameBytes, encoding: .utf8), name != ".", name != ".." else {
            throw Failure.malformed
        }
        // VREG=1, VDIR=2, VLNK=5 (sys/vnode.h). Other types have different
        // size semantics, and bulk mount-point attributes describe the covered inode.
        guard type == 1 || type == 5 else { return Record(name: name, info: nil) }
        // KAUTH_UID_UNKNOWN (99): the access mask may omit stored set-ID bits.
        guard owner != 99 else { return Record(name: name, info: nil) }
        guard returned.fileattr & request.fileattr == request.fileattr,
              let linkCount = nlink_t(exactly: links), modified.tv_nsec >= 0,
              modified.tv_nsec < 1_000_000_000 else { throw Failure.missingAttributes }
        var info = stat()
        info.st_dev = device
        info.st_ino = ino_t(inode)
        info.st_mode = mode_t(mode & 0o7777) | (type == 1 ? S_IFREG : S_IFLNK)
        info.st_mtimespec = modified
        info.st_nlink = linkCount
        info.st_size = size
        return Record(name: name, info: info)
    }
}
#endif
