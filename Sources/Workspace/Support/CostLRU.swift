/// A byte-budgeted LRU. Dictionary links make lookup, promotion and eviction O(1).
/// Costs include estimated decoded storage and bookkeeping, not encoded JSON sizes.
struct CostLRU<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    enum Eviction { case leastRecent, mostRecent }

    private struct Entry: Sendable {
        var value: Value
        var cost: Int
        var previous: Key?
        var next: Key?
    }

    let limit: Int
    private var entries: [Key: Entry] = [:]
    private var oldest: Key?
    private var newest: Key?
    private(set) var cost = 0
    var count: Int { entries.count }

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        promote(key)
        return entry.value
    }

    /// MRU eviction lets a whole-tree scan retain most of the resident set.
    /// Lookup promotion and the decoded-storage bound are the same for both policies.
    mutating func insert(_ value: Value, for key: Key, cost entryCost: Int, evicting eviction: Eviction = .leastRecent) {
        remove(key)
        guard entryCost >= 0, entryCost <= limit else { return }
        while cost > limit - entryCost, let key = (eviction == .mostRecent ? newest : oldest) { remove(key) }
        entries[key] = Entry(value: value, cost: entryCost, previous: newest)
        if let newest { entries[newest]?.next = key } else { oldest = key }
        newest = key
        cost += entryCost
    }

    private mutating func promote(_ key: Key) {
        guard newest != key, let entry = entries[key] else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next } else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        entries[key]?.previous = newest
        entries[key]?.next = nil
        if let newest { entries[newest]?.next = key }
        newest = key
    }

    private mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next } else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous } else { newest = entry.previous }
        cost -= entry.cost
    }

    mutating func removeAll() {
        entries.removeAll()
        oldest = nil
        newest = nil
        cost = 0
    }
}
