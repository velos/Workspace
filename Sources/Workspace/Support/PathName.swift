/// Byte-exact keys for directory names and host paths. Swift String keys instead
/// merge canonically equivalent UTF-8 spellings, which may name different entries.
struct PathName: Sendable, Hashable, Comparable {
    let string: String

    init(_ string: String) { self.string = string }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    func hash(into hasher: inout Hasher) {
        var contiguous = string
        contiguous.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
    }
}
