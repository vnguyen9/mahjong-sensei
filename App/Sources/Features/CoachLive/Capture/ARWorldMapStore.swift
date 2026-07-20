import ARKit
import Foundation
import Recognition
import simd

struct RestoredTableCalibration {
    var worldMap: ARWorldMap
    var tableToWorld: simd_float4x4
    var extent: SIMD2<Float>
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
            guard let extent = envelope.metadata.validatedExtent,
                  let map = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: ARWorldMap.self,
                    from: envelope.worldMapData
                  ),
                  let origin = map.anchors.first(where: {
                      $0.name == tableOriginAnchorName
                  }) else {
                discard()
                return nil
            }
            return RestoredTableCalibration(
                worldMap: map,
                tableToWorld: origin.transform,
                extent: extent
            )
        } catch {
            discard()
            return nil
        }
    }

    static func save(
        worldMap: ARWorldMap,
        extent: SIMD2<Float>
    ) throws {
        let mapData = try NSKeyedArchiver.archivedData(
            withRootObject: worldMap,
            requiringSecureCoding: true
        )
        let envelope = Envelope(
            metadata: WorldMapCalibrationMetadata(extent: extent),
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
