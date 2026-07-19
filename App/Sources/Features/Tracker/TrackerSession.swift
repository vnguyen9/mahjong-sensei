import Foundation
import Observation
import MahjongCore
import Recognition

/// Manual tile-counter state for Tracker mode (3rd Scan segment, plan §2) — a
/// running 34-tile "seen" count for the current game. The user aims the
/// camera at the discards and hits Record; `recordMaxMerge` folds that shot's
/// detections in. No live/continuous detection — record-triggered only.
/// Optionally paired with the user's own hand for real ukeire/win-odds via
/// the existing engines (`EfficiencyEngine`/`CoachEngine`, wired in a later
/// chunk). Persisted to disk (`TrackerStore`) so counts survive relaunch;
/// `reset()` clears both in-memory state and the file (new game).
@Observable
final class TrackerSession {
    /// 34-slot, classIndex-keyed count of tiles seen on the table (discards +
    /// exposed melds) — same convention as `ScanSession.seenHistogram`
    /// (`ScanFlow.swift:149`), just accumulated across shots instead of
    /// derived from one recognition.
    var seenHistogram: [Int] = [Int](repeating: 0, count: Tile.baseClassCount)
    /// The user's own hand, if they've chosen to enter one. Empty = none.
    var hand: [Tile] = []

    /// Tiles never yet seen anywhere (table + hand) — the rough draw pool,
    /// floored at 1 so a %-based odds calc never divides by zero.
    var unseenCount: Int { max(1, 136 - seenHistogram.reduce(0, +) - hand.count) }
    /// Total tiles counted on the table so far (sum of the histogram).
    var totalCounted: Int { seenHistogram.reduce(0, +) }

    private let store: TrackerStore

    init(store: TrackerStore = .shared) {
        self.store = store
        // Load on init via a Task that sets state on MainActor — mirrors
        // CoachLive's persisted-session load (`CoachLiveSetupView.loadResumable`)
        // being an async fire-and-forget against the same-shaped store actor.
        Task { @MainActor [weak self] in
            guard let persisted = await store.load() else { return }
            self?.seenHistogram = persisted.seen
            self?.hand = persisted.hand
        }
    }

    /// Record = "set to max seen" per capture: build a 34-slot histogram of
    /// this shot's detections (non-bonus only, keyed by `classIndex`), then
    /// raise (never lower) each slot to that shot's count, clamped to 4 —
    /// idempotent-ish across repeated shots of the same discards, no
    /// accumulation double-count. Returns the classIndexes that actually
    /// changed, for the UI's count-up animation.
    @discardableResult
    func recordMaxMerge(_ detections: [DetectedTile]) -> Set<Int> {
        var shot = [Int](repeating: 0, count: Tile.baseClassCount)
        for d in detections where !d.tile.isBonus {
            shot[d.tile.classIndex] += 1
        }
        var changed = Set<Int>()
        for i in 0..<Tile.baseClassCount {
            let merged = min(4, max(seenHistogram[i], shot[i]))
            if merged != seenHistogram[i] {
                seenHistogram[i] = merged
                changed.insert(i)
            }
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    /// Manual correction from the tap-a-tile stepper.
    func setCount(classIndex: Int, count: Int) {
        guard (0..<Tile.baseClassCount).contains(classIndex) else { return }
        let clamped = min(4, max(0, count))
        guard seenHistogram[classIndex] != clamped else { return }
        seenHistogram[classIndex] = clamped
        persist()
    }

    func setHand(_ tiles: [Tile]) {
        hand = tiles
        persist()
    }

    /// New game: zero the histogram, clear the hand, delete the on-disk file.
    func reset() {
        seenHistogram = [Int](repeating: 0, count: Tile.baseClassCount)
        hand = []
        Task { await store.clear() }
    }

    /// A debounced Task per mutation is fine here — Record is user-triggered
    /// and low frequency, unlike Coach Live's continuous tracking loop.
    private func persist() {
        let snapshot = TrackerStore.Persisted(seen: seenHistogram, hand: hand)
        let store = store
        Task { await store.save(snapshot) }
    }
}
