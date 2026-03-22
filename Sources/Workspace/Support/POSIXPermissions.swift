import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// POSIX file mode bits (typically `0o755`-style permissions).
public struct POSIXPermissions: Sendable, Hashable, Codable {
    /// The raw permission bits.
    public var rawValue: mode_t

    /// Creates permissions from a raw mode value, masking to permission bits.
    public init(rawValue: mode_t) {
        self.rawValue = rawValue & 0o7777
    }

    /// Creates permissions from an integer, masking to permission bits.
    public init(_ value: Int) {
        self.init(rawValue: mode_t(truncatingIfNeeded: value) & 0o7777)
    }

    /// Default permissions for a new regular file.
    public static let defaultFile = POSIXPermissions(0o644)

    /// Default permissions for a new directory.
    public static let defaultDirectory = POSIXPermissions(0o755)

    /// Full access for the owner only.
    public static let ownerReadWriteExecute = POSIXPermissions(0o700)
}
