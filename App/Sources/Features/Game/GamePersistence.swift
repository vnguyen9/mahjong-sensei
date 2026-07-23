import Foundation
import MahjongGameEngine

/// The small, versioned envelope saved for the single resumable local match.
///
/// The replay is the source of truth: loading it must pass the engine's strict
/// replay validation before it is ever used to construct a `GameSession`.
struct PersistedMahjongMatchV1: Codable, Sendable, Hashable {
    static let schema = "PersistedMahjongMatchV1"

    let schemaVersion: String
    let savedAt: Date
    let replay: MatchReplayV1

    init(replay: MatchReplayV1, savedAt: Date = .now) {
        schemaVersion = Self.schema
        self.savedAt = savedAt
        self.replay = replay
    }

    var isCompatible: Bool {
        schemaVersion == Self.schema && replay.schemaVersion == MatchReplayV1.schema
    }
}

/// Serializes access to the one local match archive. A failed decode or a
/// retired schema is removed immediately, so an unusable archive never blocks
/// starting a new game.
actor MahjongMatchStore {
    static let shared = MahjongMatchStore()

    private let fileManager: FileManager
    private let archiveURL: URL

    init(fileManager: FileManager = .default, archiveURL: URL? = nil) {
        self.fileManager = fileManager
        self.archiveURL = archiveURL ?? Self.defaultArchiveURL(fileManager: fileManager)
    }

    func load() -> PersistedMahjongMatchV1? {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: archiveURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(PersistedMahjongMatchV1.self, from: data)
            guard archive.isCompatible else {
                removeArchive()
                return nil
            }
            let rebuilt = try MatchState.replay(archive.replay)
            guard !rebuilt.isMatchComplete else {
                removeArchive()
                return nil
            }
            return archive
        } catch {
            removeArchive()
            return nil
        }
    }

    func save(_ persisted: PersistedMahjongMatchV1) {
        guard persisted.isCompatible else {
            removeArchive()
            return
        }

        do {
            let rebuilt = try MatchState.replay(persisted.replay)
            guard !rebuilt.isMatchComplete else {
                removeArchive()
                return
            }
            try fileManager.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: archiveURL, options: .atomic)
        } catch {
            // Persistence must never interrupt play. The previous atomic archive,
            // if any, remains intact when this write fails.
        }
    }

    func clear() {
        removeArchive()
    }

    private func removeArchive() {
        guard fileManager.fileExists(atPath: archiveURL.path) else { return }
        try? fileManager.removeItem(at: archiveURL)
    }

    private static func defaultArchiveURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("MahjongSensei", isDirectory: true)
            .appendingPathComponent("PersistedMahjongMatchV1.json", isDirectory: false)
    }
}
