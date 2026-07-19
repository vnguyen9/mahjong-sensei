import Foundation
import MahjongCore

/// Actor-isolated JSON persistence for the Tracker's running tile count —
/// mirrors `CoachLiveSessionStore`'s shape (`CoachLiveSessionPersistence.swift`)
/// but far simpler: no resume-freshness window, no monotonic-clock remapping —
/// just "what was counted last time". A single well-known file under
/// Application Support; `save`/`clear` are best-effort (a failed write just
/// means counts don't survive relaunch, never a crash).
actor TrackerStore {
    static let shared = TrackerStore()

    /// On-disk shape: the 34-slot seen histogram plus the optional hand.
    struct Persisted: Codable, Sendable {
        var seen: [Int]
        var hand: [Tile]
    }

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tracker-session.json")
    }()

    func load() -> Persisted? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    func save(_ persisted: Persisted) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence — see the type doc.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
