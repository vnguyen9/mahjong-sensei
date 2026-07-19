import Foundation

/// A deterministic, monotonic frame identifier — a plain counter, never a
/// `Date` or `UUID` (§8: observation semantics must be reproducible in tests
/// and logs, not wall-clock- or randomness-derived).
public struct FrameID: Sendable, Hashable, Comparable, Codable {
    public var value: Int

    public init(_ value: Int) { self.value = value }

    public static func < (lhs: FrameID, rhs: FrameID) -> Bool { lhs.value < rhs.value }
}

/// Hands out strictly increasing ``FrameID``s for one capture session. Not
/// thread-safe by design — the capture loop owns a single instance and calls
/// it from one place (an actor or serial queue).
public struct FrameIDGenerator: Sendable {
    private var next: Int

    public init(startingAt first: Int = 0) { next = first }

    public mutating func nextID() -> FrameID {
        defer { next += 1 }
        return FrameID(next)
    }
}
