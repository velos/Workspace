import Foundation

/// A process-private namespace prevents filtering user files with the historical
/// `.workspace-<uuid>` spelling, or similar prefixes. Only our nonce plus a complete
/// canonical UUID is recognized; no filesystem lookup is needed after rename.
enum LocalAtomicTemporaryName {
    private static let prefix = ".workspace-atomic-" + UUID().uuidString + "-"

    static func make() -> String { prefix + UUID().uuidString }

    static func matches(_ name: String) -> Bool {
        guard name.utf8.starts(with: prefix.utf8) else { return false }
        let suffix = String(decoding: name.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return UUID(uuidString: suffix)?.uuidString.utf8.elementsEqual(suffix.utf8) == true
    }
}
