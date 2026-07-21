import Foundation

/// Identity-only fairness policy for spatial ROI work. Geometry remains in the
/// app, while this deterministic queue guarantees that deferred/offscreen work
/// is retained and that repeatedly available work cannot starve.
public struct DeferredRegionWorkQueue<ID: Hashable & Sendable>: Sendable {
    private struct Entry: Sendable {
        var age: Int
        var sequence: Int
        var isAvailable: Bool
    }

    private var entries: [ID: Entry] = [:]
    private var nextSequence = 0

    public init() {}

    public mutating func enqueue(_ id: ID, isAvailable: Bool = true) {
        if var existing = entries[id] {
            existing.isAvailable = isAvailable
            entries[id] = existing
        } else {
            entries[id] = Entry(
                age: 0,
                sequence: nextSequence,
                isAvailable: isAvailable
            )
            nextSequence += 1
        }
    }

    public mutating func setAvailable(_ isAvailable: Bool, for id: ID) {
        guard var entry = entries[id] else { return }
        entry.isAvailable = isAvailable
        entries[id] = entry
    }

    public mutating func select(
        maximum: Int,
        priority: ID? = nil,
        preferred: ID? = nil
    ) -> [ID] {
        guard maximum > 0 else { return [] }
        let ordered = entries.keys.filter {
            entries[$0]?.isAvailable == true
        }.sorted { lhs, rhs in
            if lhs == priority { return rhs != priority }
            if rhs == priority { return false }
            let left = entries[lhs]!
            let right = entries[rhs]!
            if left.age != right.age { return left.age > right.age }
            if lhs == preferred { return rhs != preferred }
            if rhs == preferred { return false }
            return left.sequence < right.sequence
        }
        let selected = Array(ordered.prefix(maximum))
        let selectedSet = Set(selected)
        for id in entries.keys {
            guard var entry = entries[id] else { continue }
            entry.age = selectedSet.contains(id) ? 0 : min(10_000, entry.age + 1)
            entries[id] = entry
        }
        return selected
    }

    public mutating func complete(_ id: ID) {
        entries.removeValue(forKey: id)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public var pendingIDs: Set<ID> { Set(entries.keys) }
}

/// Ordered bounded verification independent of recognition or ARKit. A region
/// finishes after `maximumReads` successes, or earlier when the census reports
/// stable identities and faces.
public struct BoundedRegionVerificationQueue<ID: Hashable & Sendable>: Sendable {
    private var order: [ID] = []
    private var reads: [ID: Int] = [:]
    private var hasBegun = false

    public init() {}

    public mutating func begin(order: [ID]) {
        self.order = order
        reads = [:]
        hasBegun = true
    }

    public var current: ID? { order.first }
    public var successfulReadsForCurrent: Int {
        current.map { reads[$0, default: 0] } ?? 0
    }
    public var isComplete: Bool { hasBegun && order.isEmpty }

    public mutating func recordSuccessfulRead(
        for id: ID,
        stabilized: Bool,
        maximumReads: Int = 3
    ) {
        guard order.first == id else { return }
        let count = reads[id, default: 0] + 1
        reads[id] = count
        if stabilized || count >= maximumReads {
            order.removeFirst()
        }
    }
}
