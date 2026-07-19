import Foundation
import Recognition

/// On-disk persistence for Coach Live (plan A6: survive relaunch). Wraps the
/// package's state-EXPORT `TrackerSnapshot` with the one thing the tracker
/// itself is forbidden from touching — a wall-clock `savedAt` — so a later
/// resume can tell how long ago the session was saved and remap every
/// monotonic timestamp accordingly (`remapped(toNowMono:)`).
struct PersistedCoachLiveSession: Codable, Sendable {
    var snapshot: TrackerSnapshot
    var savedAt: Date
    /// Which coordinate space `snapshot.tiles[].box` lives in — set at
    /// persist time from the live tracker's `TrackerConfig.coordinateSpace`
    /// (Lane B chunk D). `TrackerConfig.CoordinateSpace` itself isn't
    /// `Codable`, hence this small app-side mirror. A resume whose marker
    /// doesn't match the CURRENT capture mode (AR vs the image-space
    /// fallback) has boxes in the wrong units for the tracker it would
    /// restore onto (table-plane metres vs oriented-image fractions) —
    /// `CoachLiveSession.resume(from:)` checks this and degrades to a fresh
    /// start (logged) instead of restoring nonsense geometry.
    var coordinateSpace: CoordinateSpaceMarker

    enum CoordinateSpaceMarker: String, Codable, Sendable { case imageSpace, tableSpace }

    init(snapshot: TrackerSnapshot, savedAt: Date, coordinateSpace: CoordinateSpaceMarker = .imageSpace) {
        self.snapshot = snapshot
        self.savedAt = savedAt
        self.coordinateSpace = coordinateSpace
    }

    private enum CodingKeys: String, CodingKey { case snapshot, savedAt, coordinateSpace }

    /// Explicit `CodingKeys` + a hand-written `init(from:)` (paired with the
    /// still-synthesized `encode(to:)`) so `coordinateSpace` decodes
    /// tolerantly — mirrors `Recognition.MotionSample`'s own
    /// `decodeIfPresent` pattern: every pre-Lane-B on-disk archive predates
    /// this field and simply won't have it, defaulting to `.imageSpace` (the
    /// only space that existed before this chunk) rather than failing the
    /// decode outright.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(TrackerSnapshot.self, forKey: .snapshot)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        coordinateSpace = try container.decodeIfPresent(CoordinateSpaceMarker.self, forKey: .coordinateSpace) ?? .imageSpace
    }
}

extension PersistedCoachLiveSession {
    /// Remaps every monotonic timestamp in `snapshot` from the OLD process's
    /// `CACurrentMediaTime()` origin to the NEW process's — required because
    /// that clock resets to near-zero across a relaunch, but the tracker's
    /// events/tiles carry it as their only notion of "when".
    ///
    /// **Derivation.** An event recorded at old-mono time `e` occurred
    /// `savedAtMono - e` mono-seconds before save — and since mono time only
    /// ever advances at the same rate as the wall clock, that's also its age
    /// in wall-clock seconds AS OF SAVE. Wall time keeps ticking across the
    /// relaunch, so as of THIS call the event is
    /// `(savedAtMono - e) + wallElapsed` seconds old, where
    /// `wallElapsed = Date().timeIntervalSince(savedAt)` is how long it's
    /// been since save. We want a new-mono value `e'` such that
    /// `nowMono - e'` equals exactly that age:
    ///
    ///     nowMono - e' = (savedAtMono - e) + wallElapsed
    ///     e' = e + (nowMono - savedAtMono - wallElapsed)
    ///     e' = e + shift,  shift = nowMono - savedAtMono - wallElapsed
    ///
    /// i.e. an event that happened 5 wall-minutes ago (as of THIS call)
    /// reads as `nowMono - 300`, regardless of how the mono clock itself
    /// restarted. Every timestamp in the snapshot (`savedAtMono`,
    /// `events[].at`, `tiles[].firstSeen`/`.lastSeen`) shifts by the same
    /// constant, so relative ordering/durations are preserved exactly.
    func remapped(toNowMono nowMono: TimeInterval) -> TrackerSnapshot {
        let wallElapsed = Date().timeIntervalSince(savedAt)
        let shift = nowMono - snapshot.savedAtMono - wallElapsed

        var remapped = snapshot
        remapped.savedAtMono += shift
        remapped.events = snapshot.events.map { event in
            var e = event
            e.at += shift
            return e
        }
        remapped.tiles = snapshot.tiles.map { tile in
            var t = tile
            t.firstSeen += shift
            t.lastSeen += shift
            return t
        }
        return remapped
    }
}

/// Actor-isolated JSON persistence for the one in-flight Coach Live session —
/// mirrors `RecognizerLoader`'s "cache behind an actor" shape (`ScanFlow.swift`).
/// A single well-known file under Application Support; `save`/`clear` are
/// best-effort (a failed write just means no resume offer next launch, never
/// a crash), and `loadIfFresh` deletes a stale archive on read so a >12h-old
/// session never lingers to be offered (or re-checked) again.
actor CoachLiveSessionStore {
    static let shared = CoachLiveSessionStore()

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("coach-live-session.json")
    }()

    func save(_ persisted: PersistedCoachLiveSession) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence — see the type doc.
        }
    }

    /// A fresh (< `maxAge`, default 12h) archive, or nil — an absent/corrupt/
    /// stale file all read as nil. A stale file is deleted here (not just
    /// ignored) so it can't keep being read as "present but too old" forever.
    func loadIfFresh(maxAge: TimeInterval = 12 * 3600) -> PersistedCoachLiveSession? {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(PersistedCoachLiveSession.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(persisted.savedAt) <= maxAge else {
            clear()
            return nil
        }
        return persisted
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
