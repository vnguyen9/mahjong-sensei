/// A small memoizing front door to ``CoachAdvisor/advise(_:)`` (plan §5).
///
/// The tracker re-fires a near-identical ``TableState`` on every camera frame;
/// most are byte-for-byte the previous one. This actor keeps the last few
/// answers in an LRU so those repeats cost a dictionary probe instead of a full
/// (2–5 ms) re-derivation. `advise` itself is pure, so a hit returns a value
/// equal in every field to a fresh computation — the cache changes latency, not
/// answers.
///
/// Renamed from the plan's "CoachSession": that name is already taken by an
/// app-side object. Keyed by the whole ``TableState`` (it is `Hashable`), so a
/// hit requires exact equality — no hash-collision surprises.
public actor AdvisorCache {

    private let capacity: Int
    /// Least-recently-used first, most-recently-used last.
    private var entries: [(key: TableState, value: CoachAdvice)] = []

    /// - Parameter cacheSize: number of distinct states to retain (default 8,
    ///   floored at 1).
    public init(cacheSize: Int = 8) {
        self.capacity = max(1, cacheSize)
    }

    /// Advice for `table`, served from cache when the exact state was seen
    /// recently, else computed and memoized.
    public func advice(for table: TableState) -> CoachAdvice {
        if let index = entries.firstIndex(where: { $0.key == table }) {
            let hit = entries.remove(at: index)
            entries.append(hit)                     // promote to most-recently-used
            return hit.value
        }
        let advice = CoachAdvisor.advise(table)
        entries.append((table, advice))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)   // evict least-recently-used
        }
        return advice
    }

    /// Current number of cached entries (for tests / diagnostics).
    public var count: Int { entries.count }
}
