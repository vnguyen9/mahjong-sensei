import ARKit
import Foundation
import Recognition
import simd

struct RestoredTableCalibration {
    var worldMap: ARWorldMap
    var calibration: WorldTableCalibration
}

/// One atomic Application Support archive containing ARKit's secure world-map
/// bytes and the small, versioned table-calibration sidecar.
enum ARWorldMapStore {
    static let tableOriginAnchorName = "mahjong-sensei.table-origin"

    private struct Envelope: Codable {
        var metadata: WorldMapCalibrationMetadata
        var worldMapData: Data
    }

    static func load() -> RestoredTableCalibration? {
        do {
            let data = try Data(contentsOf: archiveURL())
            let envelope = try PropertyListDecoder().decode(
                Envelope.self,
                from: data
            )
            guard let map = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: ARWorldMap.self,
                    from: envelope.worldMapData
                  ),
                  let origin = map.anchors.first(where: {
                      $0.name == tableOriginAnchorName
                  }),
                  let calibration = envelope.metadata.validatedCalibration(
                    tableToWorld: origin.transform,
                    sourceOverride: .restoredWorldMap
                  ) else {
                discard()
                return nil
            }
            return RestoredTableCalibration(
                worldMap: map,
                calibration: calibration
            )
        } catch {
            discard()
            return nil
        }
    }

    static func save(
        worldMap: ARWorldMap,
        calibration: WorldTableCalibration
    ) throws {
        let mapData = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap,
            requiringSecureCoding: true
        )
        let envelope = Envelope(
            metadata: WorldMapCalibrationMetadata(
                calibration: calibration
            ),
            worldMapData: mapData
        )
        let data = try PropertyListEncoder().encode(envelope)
        let url = try archiveURL(creatingDirectory: true)
        try data.write(to: url, options: .atomic)
    }

    static func discard() {
        try? FileManager.default.removeItem(at: archiveURL())
    }

    private static func archiveURL(
        creatingDirectory: Bool = false
    ) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: creatingDirectory
        )
        let directory = base.appendingPathComponent(
            "CoachLive",
            isDirectory: true
        )
        if creatingDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent("TableWorldMap.plist")
    }
}
