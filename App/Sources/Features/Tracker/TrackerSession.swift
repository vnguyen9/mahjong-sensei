import Foundation
import Observation
import MahjongCore
import Recognition

/// Manual tile-counter state for Tracker mode — table histogram + optional hand.
/// Record replaces table counts only; hand edits stay independent but count toward
/// totals / display pips.
@Observable
final class TrackerSession {
    static let maxHandSize = 18

    /// 34-slot, classIndex-keyed count of tiles seen on the **table** (discards +
    /// exposed melds). Whole-table Record replaces this from one shot.
    var seenHistogram: [Int] = [Int](repeating: 0, count: Tile.baseClassCount)
    /// The user's own hand tiles.
    var hand: [Tile] = []

    /// Tiles never yet seen anywhere (table + hand) — the rough draw pool,
    /// floored at 1 so a %-based odds calc never divides by zero.
    var unseenCount: Int { max(1, 136 - seenHistogram.reduce(0, +) - hand.count) }
    /// Table + hand accounted for.
    var totalCounted: Int { seenHistogram.reduce(0, +) + hand.count }

    /// Per-face display counts for the grid: `min(4, table + hand)`.
    var displayHistogram: [Int] {
        (0..<Tile.baseClassCount).map { i in
            let face = Tile(classIndex: i)!
            return min(4, tableSeen(face) + handCount(face))
        }
    }

    /// Per-face hand-only counts for split-color pips on the grid.
    var handHistogram: [Int] {
        (0..<Tile.baseClassCount).map { i in
            handCount(Tile(classIndex: i)!)
        }
    }

    private let store: TrackerStore

    init(store: TrackerStore = .shared) {
        self.store = store
        Task { @MainActor [weak self] in
            guard let persisted = await store.load() else { return }
            self?.seenHistogram = persisted.seen
            self?.hand = persisted.hand
        }
    }

    // MARK: - Face accounting

    func tableSeen(_ tile: Tile) -> Int {
        guard (0..<Tile.baseClassCount).contains(tile.classIndex) else { return 0 }
        return seenHistogram.indices.contains(tile.classIndex) ? seenHistogram[tile.classIndex] : 0
    }

    func handCount(_ tile: Tile) -> Int { hand.filter { $0 == tile }.count }

    func remainingForFace(_ tile: Tile) -> Int {
        max(0, 4 - tableSeen(tile) - handCount(tile))
    }

    func canAddToHand(_ tile: Tile) -> Bool {
        remainingForFace(tile) > 0 && hand.count < Self.maxHandSize
    }

    // MARK: - Record / mutations

    /// Record = trust this frame: replace table histogram (hand untouched).
    @discardableResult
    func recordReplaceFromShot(_ detections: [DetectedTile]) -> Set<Int> {
        var shot = [Int](repeating: 0, count: Tile.baseClassCount)
        for d in detections where !d.tile.isBonus {
            shot[d.tile.classIndex] += 1
        }
        var changed = Set<Int>()
        for i in 0..<Tile.baseClassCount {
            let face = Tile(classIndex: i)!
            let held = handCount(face)
            let next = min(4 - held, max(0, shot[i]))
            if next != seenHistogram[i] {
                seenHistogram[i] = next
                changed.insert(i)
            }
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    /// Table count stepper — clamped so table + hand ≤ 4.
    func setCount(classIndex: Int, count: Int) {
        guard (0..<Tile.baseClassCount).contains(classIndex),
              let tile = Tile(classIndex: classIndex) else { return }
        let held = handCount(tile)
        let clamped = min(4 - held, max(0, count))
        guard seenHistogram[classIndex] != clamped else { return }
        seenHistogram[classIndex] = clamped
        persist()
    }

    func setHand(_ tiles: [Tile]) {
        hand = tiles
        persist()
    }

    /// Rewrite this face in the hand to exactly `count` copies (clamped by
    /// remaining table room and soft hand length).
    func setHandCount(classIndex: Int, count: Int) {
        guard (0..<Tile.baseClassCount).contains(classIndex),
              let tile = Tile(classIndex: classIndex) else { return }
        let table = tableSeen(tile)
        let current = handCount(tile)
        var target = min(4 - table, max(0, count))
        if target > current {
            let room = Self.maxHandSize - hand.count
            target = current + min(target - current, max(0, room))
        }
        guard target != current else { return }
        var next = hand.filter { $0 != tile }
        next.append(contentsOf: Array(repeating: tile, count: target))
        hand = next
        persist()
    }

    /// New game: zero the histogram, clear the hand, delete the on-disk file.
    func reset() {
        seenHistogram = [Int](repeating: 0, count: Tile.baseClassCount)
        hand = []
        Task { await store.clear() }
    }

    private func persist() {
        let snapshot = TrackerStore.Persisted(seen: seenHistogram, hand: hand)
        let store = store
        Task { await store.save(snapshot) }
    }
}
