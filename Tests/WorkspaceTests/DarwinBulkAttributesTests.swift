#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import Workspace

struct DarwinBulkAttributesTests {
    private func root() throws -> URL {
        let parent = ProcessInfo.processInfo.environment["WORKSPACE_TEST_VOLUME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/private/tmp")
        let root = parent.appendingPathComponent("WorkspaceBulkParity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func infos(_ fs: LocalFileSystem, skipUnreadable: Bool = true, skipVanished: Bool = false) async throws -> [FileInfo] {
        var result: [FileInfo] = []
        try await fs.walk(at: .root, skippingUnreadableDirectories: skipUnreadable,
                          skippingVanishedEntries: skipVanished) { info, _, readLink in
            result.append(info)
            if info.kind == .symlink { _ = try await readLink() }
        }
        return result
    }

    private func equal(_ actual: [FileInfo], _ expected: [FileInfo]) throws {
        #expect(actual.count == expected.count, "visit count: bulk=\(actual.count), stat=\(expected.count)")
        for (index, pair) in zip(actual, expected).enumerated() {
            let (bulk, stat) = pair
            // Evaluate and format outside #expect so failures never hide values
            // behind a throwing expression's <not evaluated> diagnostic.
            var differences: [String] = []
            func compare<T: Equatable>(_ field: String, _ a: T, _ b: T) {
                if a != b { differences.append("\(field): bulk=\(a), stat=\(b)") }
            }
            compare("path UTF-8/order", Array(bulk.path.string.utf8), Array(stat.path.string.utf8))
            compare("kind", bulk.kind, stat.kind)
            compare("size", bulk.size, stat.size)
            compare("permissions (octal)", String(bulk.permissions.rawValue, radix: 8), String(stat.permissions.rawValue, radix: 8))
            compare("modificationDate", bulk.modificationDate?.timeIntervalSinceReferenceDate, stat.modificationDate?.timeIntervalSinceReferenceDate)
            compare("identity", bulk.identity, stat.identity)
            compare("linkCount", bulk.linkCount, stat.linkCount)
            let detail = "visit \(index) \(stat.path): " + differences.joined(separator: "; ")
            #expect(differences.isEmpty, Comment(rawValue: detail))
        }
    }

    @Test func metadataAndStoredNamesMatchStat() async throws {
        let root = try root()
        defer { TestSupport.remove(root) }
        let manager = FileManager.default
        let nativeVolume = ProcessInfo.processInfo.environment["WORKSPACE_TEST_VOLUME"] != nil
        func report(_ name: String, result: Int32) {
            let code = errno
            if result == 0 { print("CASE \(name): ran") }
            else {
                print("CASE \(name): SKIPPED (errno \(code): \(String(cString: strerror(code))))")
                #expect(nativeVolume, "Default fixture must support \(name)")
            }
        }
        for name in ["empty", "nested", "unreadable"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let files: [(String, mode_t)] = [
            ("regular", 0o640), ("nested/file", 0o755), ("NFC-é", 0o444), ("NFD-e\u{301}", 0o600),
            ("mode-special", 0o6751), ("mode-setuid", 0o4751), ("mode-setgid", 0o2751),
            ("mode-sticky", 0o1751), ("mode-all-special", 0o7751),
        ]
        // POSIX creation preserves supplied Unicode bytes on APFS; Foundation
        // URLs can decompose them before creation. HFS+ rewrites them on disk.
        for (index, file) in files.enumerated() {
            let (name, mode) = file
            let path = root.path + "/" + name
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            try #require(fd >= 0)
            defer { close(fd) }
            let data = Data(repeating: UInt8(index), count: index * 17 + 1)
            #expect(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count)
            let changed = fchmod(fd, mode)
            let chmodError = errno
            var status = stat()
            #expect(fstat(fd, &status) == 0)
            let actualMode = status.st_mode & 0o7777
            let supported = changed == 0 && actualMode == mode
            print("CASE \(name) mode: \(supported ? "ran" : "SKIPPED requested mode") requested=\(String(mode, radix: 8)) stat=\(String(actualMode, radix: 8)) chmodErrno=\(changed == 0 ? 0 : chmodError)")
            #expect(nativeVolume || (changed == 0 && actualMode & 0o1777 == mode & 0o1777),
                    "Default fixture must retain ordinary and sticky mode bits for \(name)")
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789),
                         timespec(tv_sec: 1_700_000_000, tv_nsec: 987_654_321)]
            #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
        }
        try Data().write(to: root.appendingPathComponent("zero-bytes"))
        print("CASE empty/nested directories, zero-byte file, Unicode spellings, fractional mtime: ran")
        // Probe each feature independently: a lack of hard links says nothing
        // about whether symlinks, FIFOs, or sockets can be represented.
        report("hard link", result: link(root.appendingPathComponent("regular").path, root.appendingPathComponent("hard").path))
        for (name, target) in [("dangling", "missing"), ("cycle", "cycle"), ("escape", "/etc/passwd"),
                               ("dir-link", "nested"), ("file-link", "regular")] {
            report("symlink \(name)", result: symlink(target, root.appendingPathComponent(name).path))
        }
        report("FIFO", result: mkfifo(root.appendingPathComponent("fifo").path, 0o620))
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(socketFD >= 0)
        defer { close(socketFD) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = Array(root.appendingPathComponent("socket").path.utf8CString)
        if socketPath.count <= MemoryLayout.size(ofValue: address.sun_path) {
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (index, byte) in socketPath.enumerated() { bytes[index] = UInt8(bitPattern: byte) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            report("socket", result: result)
        } else { print("CASE socket: SKIPPED (volume path exceeds sockaddr_un capacity)") }
        let unreadable = root.appendingPathComponent("unreadable")
        #expect(chmod(unreadable.path, 0) == 0)
        defer { _ = chmod(unreadable.path, 0o700) }
        print("CASE unreadable directory: \(access(unreadable.path, R_OK) == 0 ? "SKIPPED denial (still readable)" : "ran")")
        for alias in ["REGULAR", "NFC-e\u{301}", "NFD-é"] {
            var status = stat()
            _ = lstat(root.appendingPathComponent(alias).path, &status)
        }
        let bulk = try LocalFileSystem(root: root, bulkAttributes: DarwinBulkAttributes())
        let reference = try LocalFileSystem(root: root, bulkAttributes: nil)
        try equal(await infos(bulk), await infos(reference))
        let fd = open(root.path, O_RDONLY | O_DIRECTORY)
        try #require(fd >= 0)
        defer { close(fd) }
        var status = stat()
        #expect(fstat(fd, &status) == 0)
        var volume = statfs()
        #expect(fstatfs(fd, &volume) == 0)
        let typeCapacity = MemoryLayout.size(ofValue: volume.f_fstypename)
        let type = withUnsafePointer(to: &volume.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: typeCapacity) { String(cString: $0) }
        }
        let listed = try await reference.listDirectory(path: .root)
        let names = Set(listed.map { Data($0.name.utf8) })
        if type == "apfs" {
            #expect(names.contains(Data("NFC-é".utf8)))
            #expect(names.contains(Data("NFD-e\u{301}".utf8)))
        } else if type == "hfs" {
            #expect(names.contains(Data("NFC-e\u{301}".utf8)))
        }
        print("Volume type: \(type), flags: 0x\(String(volume.f_flags, radix: 16))")
        let records = try DarwinBulkAttributes().entries(in: fd, device: status.st_dev)
        let nativeNames = type == "apfs" || type == "hfs"
        print("Production route: \(nativeNames && records != nil ? "bulk" : "readdir + fstatat (mount flags, filesystem, or unsupported attributes)")")
        if !nativeVolume { #expect(records != nil) }
        // Diagnostic only: explicitly bypass mount eligibility on a fresh fd to
        // show what the kernel masks, without feeding raw metadata to a walk.
        let rawFD = openat(fd, ".", O_RDONLY | O_DIRECTORY)
        try #require(rawFD >= 0)
        defer { close(rawFD) }
        let raw = try DarwinBulkAttributes(mountFlags: { _ in 0 }).entries(in: rawFD, device: status.st_dev)
        if let raw {
            #expect(Set(raw.map { Data($0.name.utf8) }) == names)
            #expect(raw.first { $0.name == "regular" }?.info != nil)
            for record in raw {
                if record.name.hasPrefix("NFC-") || record.name.hasPrefix("NFD-") {
                    print("Bulk/readdir stored bytes: \(Array(record.name.utf8))")
                }
                if record.name.hasPrefix("mode-"), let info = record.info {
                    var expected = stat()
                    #expect(fstatat(fd, record.name, &expected, AT_SYMLINK_NOFOLLOW) == 0)
                    let a = info.st_mode & 0o7777, b = expected.st_mode & 0o7777
                    print("RAW \(record.name): bulk=\(String(a, radix: 8)) stat=\(String(b, radix: 8)) differingBits=\(String(a ^ b, radix: 8))")
                }
            }
        } else { print("RAW bulk probe: unavailable; fallback parity only") }
        for fs in [bulk, reference] {
            do {
                _ = try await infos(fs, skipUnreadable: false)
                #expect(geteuid() == 0 || access(unreadable.path, R_OK) == 0)
            } catch { #expect((error as NSError).code == Int(EACCES)) }
        }
    }

    @Test(arguments: [UInt32(0), UInt32(MNT_NODEV | MNT_NOEXEC | MNT_RDONLY | MNT_DONTBROWSE),
                      UInt32(MNT_NOSUID), UInt32(MNT_IGNORE_OWNERSHIP), UInt32(MNT_QUARANTINE),
                      UInt32(MNT_NOSUID | MNT_NODEV | MNT_IGNORE_OWNERSHIP | MNT_DONTBROWSE), nil])
    func mountFlagsPreserveStoredModes(flags: UInt32?) async throws {
        let root = try root()
        defer { TestSupport.remove(root) }
        try Data([1]).write(to: root.appendingPathComponent("mode-special"))
        #expect(chmod(root.appendingPathComponent("mode-special").path, 0o7751) == 0)
        // The sandbox silently strips set-ID bits even after successful chmod.
        // Inject loss of all special bits, including the retained sticky bit,
        // so a missed gate corrupts FileInfo even here, not just a call count.
        let allowed = flags == 0 || flags == UInt32(MNT_NODEV | MNT_NOEXEC | MNT_RDONLY | MNT_DONTBROWSE)
        let probe = MountFlagProbe(flags: flags, stripSpecialBits: !allowed)
        let bulk = try LocalFileSystem(root: root, bulkAttributes: DarwinBulkAttributes(read: probe.read, mountFlags: probe.flags))
        let reference = try LocalFileSystem(root: root, bulkAttributes: nil)
        let expected = try await infos(reference)
        let storedMode = try #require(expected.first { $0.path.string == "/mode-special" }).permissions.rawValue
        try #require(storedMode & 0o1000 != 0)
        for _ in 0..<2 { try equal(await infos(bulk), expected) }
        #expect(allowed ? probe.reads > 0 : probe.reads == 0)
        // Unsafe devices remain excluded; failed flag queries retry next time.
        #expect(flags != nil && !allowed ? probe.queries == 1 : probe.queries == 2)
    }

    @Test(arguments: ["io", "unsupported", "missing", "malformed", "vanishedStrict", "vanishedSkip"])
    func discardsPartialBatchesAndPreservesFallback(failure: String) async throws {
        let root = try root()
        defer { TestSupport.remove(root) }
        for index in 0..<900 {
            try Data([1]).write(to: root.appendingPathComponent("file-\(index)"))
        }
        let probe = FailingBulkRead(failure)
        let bulk = try LocalFileSystem(root: root, bulkAttributes: DarwinBulkAttributes(read: probe.read))
        let reference = try LocalFileSystem(root: root, bulkAttributes: nil)
        let expected: [FileInfo]
        if failure.hasPrefix("vanished") {
            if failure == "vanishedStrict" {
                do {
                    _ = try await infos(bulk)
                    Issue.record("A child listed by bulk enumeration disappeared before metadata")
                } catch { #expect((error as NSError).code == Int(ENOENT)) }
                expected = try await infos(reference)
            } else {
                let initialRoot = try await reference.stat(path: .root)
                let actual = try await infos(bulk, skipVanished: true)
                expected = try await infos(reference)
                // The root was inspected before the injected deletion; its size
                // and mtime legitimately precede the surviving child metadata.
                var duringDeletion = expected
                duringDeletion[duringDeletion.count - 1] = initialRoot
                try equal(actual, duringDeletion)
            }
            #expect(expected.count == 900) // 899 surviving files and the root
        } else {
            expected = try await infos(reference)
            try equal(await infos(bulk), expected)
        }
        let firstCalls = probe.calls
        #expect(firstCalls >= 2) // one real, nonempty batch before failure
        try equal(await infos(bulk), expected)
        if failure == "unsupported" || failure == "missing" { #expect(probe.calls == firstCalls) }
        else { #expect(probe.calls > firstCalls) }
    }
}

private final class MountFlagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private var queryCount = 0
    private let value: UInt32?
    private let stripSpecialBits: Bool
    init(flags: UInt32?, stripSpecialBits: Bool) { value = flags; self.stripSpecialBits = stripSpecialBits }
    var reads: Int { lock.withLock { readCount } }
    var queries: Int { lock.withLock { queryCount } }
    func flags(_ fd: Int32) -> UInt32? {
        lock.withLock { queryCount += 1 }
        return value
    }
    func read(_ fd: Int32, _ attributes: UnsafeMutablePointer<attrlist>, _ buffer: UnsafeMutableRawPointer,
              _ size: Int, _ options: UInt64) -> Int32 {
        lock.withLock { readCount += 1 }
        let count = getattrlistbulk(fd, attributes, buffer, size, options)
        if stripSpecialBits, count > 0 {
            var offset = 0
            for _ in 0..<count {
                // length, returned attrs, error, name ref, device, type, mtime
                let modeOffset = offset + 4 + MemoryLayout<attribute_set_t>.size + 4 + MemoryLayout<attrreference_t>.size
                    + MemoryLayout<dev_t>.size + 4 + MemoryLayout<timespec>.size
                let mode = buffer.loadUnaligned(fromByteOffset: modeOffset, as: UInt32.self)
                buffer.storeBytes(of: mode & ~UInt32(S_ISUID | S_ISGID | S_ISVTX), toByteOffset: modeOffset, as: UInt32.self)
                offset += Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        return count
    }
}

private final class FailingBulkRead: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failure: String
    init(_ failure: String) { self.failure = failure }
    var calls: Int { lock.withLock { count } }
    func read(_ fd: Int32, _ attributes: UnsafeMutablePointer<attrlist>, _ buffer: UnsafeMutableRawPointer,
              _ size: Int, _ options: UInt64) -> Int32 {
        let call = lock.withLock { count += 1; return count }
        if call == 2 {
            if failure == "io" || failure == "unsupported" {
                errno = failure == "io" ? EIO : ENOTSUP
                return -1
            }
            let result = getattrlistbulk(fd, attributes, buffer, size, options)
            if result > 0 {
                if failure.hasPrefix("vanished") {
                    // ATTR_CMN_ERROR follows the returned-attribute set; the next
                    // field is the name reference. Remove the actual listed child.
                    let referenceOffset = 4 + MemoryLayout<attribute_set_t>.size + 4
                    let reference = buffer.loadUnaligned(fromByteOffset: referenceOffset, as: attrreference_t.self)
                    let name = buffer.advanced(by: referenceOffset + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    #expect(unlinkat(fd, name, 0) == 0)
                    buffer.storeBytes(of: UInt32(ENOENT), toByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: UInt32.self)
                } else if failure == "malformed" { buffer.storeBytes(of: UInt32.max, as: UInt32.self) }
                else {
                    var returned = buffer.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                    returned.commonattr &= ~UInt32(ATTR_CMN_FILEID)
                    buffer.storeBytes(of: returned, toByteOffset: 4, as: attribute_set_t.self)
                }
            }
            return result
        }
        return getattrlistbulk(fd, attributes, buffer, size, options)
    }
}
#endif
