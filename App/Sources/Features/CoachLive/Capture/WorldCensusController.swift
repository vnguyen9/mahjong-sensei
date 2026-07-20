import Foundation
import QuartzCore
import MahjongCore
import Recognition
import simd

struct WorldCensusDiagnostics {
    var depthRejections: [DepthSampleRejection: Int] = [:]
    var recognizerFailures = 0
    var lastIngestMilliseconds: Double = 0
}

/// App-side AR/depth policy around the platform-pure `PhysicalCensus`.
/// Receives the detections Coach Live already produced; it never owns or
/// invokes a recognizer.
@MainActor
final class WorldCensusController {
    private var frameIDs = FrameIDGenerator()
    private(set) var census = PhysicalCensus()
    private(set) var diagnostics = WorldCensusDiagnostics()
    private(set) var revision = 0
    private(set) var worldToTable: simd_float4x4
    private(set) var zones: [SemanticZoneID: [SIMD2<Float>]]
    private(set) var tableOrigin: TableOriginState

    init(lockedPlaneTransform: simd_float4x4,
         lockedExtent: Float,
         cameraPosition: SIMD3<Float>,
         at time: TimeInterval) {
        let origin = TableOriginState(
            lockedPlaneTransform: lockedPlaneTransform,
            lockedExtent: lockedExtent,
            cameraPosition: cameraPosition,
            at: time
        )
        self.tableOrigin = origin
        self.worldToTable = origin.worldToTable
        self.zones = Self.semanticZones(extent: origin.extent)
    }

    init(restoredTableToWorld: simd_float4x4,
         extent: SIMD2<Float>,
         at time: TimeInterval) {
        let origin = TableOriginState(
            restoredTableToWorld: restoredTableToWorld,
            extent: extent,
            at: time
        )
        self.tableOrigin = origin
        self.worldToTable = origin.worldToTable
        self.zones = Self.semanticZones(extent: origin.extent)
    }

    var snapshot: CensusSnapshot {
        census.snapshot(at: CACurrentMediaTime())
    }

    func updateTableSpace(worldToTable: simd_float4x4,
                          extent: SIMD2<Float>) {
        self.worldToTable = worldToTable
        zones = Self.semanticZones(extent: extent)
        census.reassignZones(zones, worldToTable: worldToTable)
        revision += 1
    }

    func ingest(
        detections: [DetectedTile],
        frame: ARTableFrame,
        projection: TableProjection,
        coverageRects: [TileBoundingBox],
        recognizerSucceeded: Bool,
        trackingIsNormal: Bool,
        at time: TimeInterval
    ) {
        let started = CACurrentMediaTime()
        defer {
            diagnostics.lastIngestMilliseconds = (CACurrentMediaTime() - started) * 1_000
        }

        guard recognizerSucceeded else {
            diagnostics.recognizerFailures += 1
            census.ingest(
                .failed(.locatorThrew("existing Coach Live recognizer failed")),
                zones: zones,
                at: time
            )
            return
        }
        guard trackingIsNormal else {
            census.ingest(.skipped(.trackingNotNormal), zones: zones, at: time)
            return
        }

        let frameID = frameIDs.nextID()
        let imageResolution = SIMD2<Double>(
            Double(frame.imageResolution.width),
            Double(frame.imageResolution.height)
        )
        let orientedSize = SIMD2<Double>(
            Double(frame.orientedImageSize.width),
            Double(frame.orientedImageSize.height)
        )

        let observations = detections.compactMap { detection -> TileObservation? in
            let point = SIMD2<Double>(detection.box.centerX, detection.box.centerY)
            let sample = DepthSampler.inspect(
                atOrientedNormalized: point,
                imageResolution: imageResolution,
                orientedImageSize: orientedSize,
                depthMap: frame.depthMap,
                confidenceMap: frame.depthConfidence
            )
            guard let depth = sample.depthMeters else {
                if let rejection = sample.rejection {
                    diagnostics.depthRejections[rejection, default: 0] += 1
                }
                return nil
            }
            guard let world = projection.worldPoint(
                ofNormalizedOrientedPoint: point,
                orientedImageSize: orientedSize,
                depthMeters: Double(depth)
            ) else {
                diagnostics.depthRejections[.invalidGeometry, default: 0] += 1
                return nil
            }
            let tablePoint = projection.tablePoint(
                ofNormalizedOrientedPoint: point,
                orientedImageSize: orientedSize
            )
            let face = TileFace.tile(detection.tile)
            let confidence = Float(detection.confidence)
            return TileObservation(
                frameID: frameID,
                box: detection.box,
                confidence: confidence,
                poseHint: .unknown,
                faceHypothesis: TileFaceHypothesis(
                    probabilities: [face: confidence],
                    topFace: face,
                    confidence: confidence,
                    margin: confidence,
                    rejectionScore: max(0, 1 - confidence)
                ),
                footprintCenter: tablePoint.map {
                    SIMD2<Float>(Float($0.x), Float($0.y))
                },
                footprintRadius: 0.012,
                worldPosition: SIMD3<Float>(
                    Float(world.x), Float(world.y), Float(world.z)
                )
            )
        }

        let visibleIDs = Set(census.anchors.compactMap { anchor -> CensusTrackID? in
            guard let point = projection.normalizedOrientedPoint(
                ofWorldPoint: SIMD3<Double>(
                    Double(anchor.worldPosition.x),
                    Double(anchor.worldPosition.y),
                    Double(anchor.worldPosition.z)
                ),
                orientedImageSize: orientedSize
            ), coverageRects.contains(where: { Self.contains(point, rect: $0) }),
            let expectedDepth = projection.cameraAxisDepth(
                ofWorldPoint: SIMD3<Double>(
                    Double(anchor.worldPosition.x),
                    Double(anchor.worldPosition.y),
                    Double(anchor.worldPosition.z)
                )
            ) else { return nil }

            let sample = DepthSampler.inspect(
                atOrientedNormalized: point,
                imageResolution: imageResolution,
                orientedImageSize: orientedSize,
                depthMap: frame.depthMap,
                confidenceMap: frame.depthConfidence
            )
            guard let sampledDepth = sample.depthMeters else {
                if let rejection = sample.rejection {
                    diagnostics.depthRejections[rejection, default: 0] += 1
                }
                return nil
            }
            // Geometry >40 mm closer than the expected tile point is an
            // occluder (typically a hand), never visible-empty evidence.
            guard Double(sampledDepth) >= expectedDepth - 0.040 else { return nil }
            return anchor.id
        })

        let quality = FrameQuality(
            trackingIsNormal: true,
            sharpness: 1,
            exposureScore: 1,
            clippingFraction: 0,
            projectedPixelsPerTile: 1,
            coverageFraction: 1,
            accepted: true
        )
        let batch = ObservationBatch(
            frameID: frameID,
            observations: observations,
            coverage: CoverageMask(),
            quality: quality
        )
        census.ingest(
            .success(batch),
            zones: zones,
            context: CensusFrameContext(
                worldToTable: worldToTable,
                visibleTrackIDs: visibleIDs
            ),
            at: time
        )
        let confirmedWorld = census.snapshot(at: time).tracks.compactMap {
            track -> SIMD3<Float>? in
            guard track.lifecycle == .confirmed else { return nil }
            return track.worldPosition
        }
        if tableOrigin.updateAutoFit(
            confirmedWorldPositions: confirmedWorld,
            at: time
        ) {
            updateTableSpace(
                worldToTable: tableOrigin.worldToTable,
                extent: tableOrigin.extent
            )
        }
        revision += 1
    }

    func recenterPond(at worldPosition: SIMD3<Float>) {
        tableOrigin.recenterPond(at: worldPosition)
        updateTableSpace(
            worldToTable: tableOrigin.worldToTable,
            extent: tableOrigin.extent
        )
    }

    func pinFace(_ tile: MahjongCore.Tile, trackID: TrackID) {
        census.pinFace(.tile(tile), trackID: CensusTrackID(trackID.raw))
        revision += 1
    }

    func overrideZone(_ zone: SemanticZoneID, trackID: TrackID) {
        census.overrideSemanticZone(zone, trackID: CensusTrackID(trackID.raw))
        revision += 1
    }

    func remove(trackID: TrackID) {
        census.removeTrack(id: CensusTrackID(trackID.raw))
        revision += 1
    }

    func resetTiles() {
        census.resetTiles()
        revision += 1
    }

    private static func contains(_ point: SIMD2<Double>,
                                 rect: TileBoundingBox) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width
            && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    /// Non-overlapping physical-metre zones centered on the fitted table
    /// origin. Boundary gaps deliberately remain unresolved rather than
    /// being guessed into an owner.
    static func semanticZones(extent: SIMD2<Float>)
        -> [SemanticZoneID: [SIMD2<Float>]] {
        let hx = extent.x / 2
        let hz = extent.y / 2
        func rect(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float)
            -> [SIMD2<Float>] {
            [SIMD2(x0, z0), SIMD2(x1, z0), SIMD2(x1, z1), SIMD2(x0, z1)]
        }
        return [
            .tablePond: rect(-0.30 * hx, -0.30 * hz, 0.30 * hx, 0.30 * hz),
            .mineMeld: rect(-hx, 0.30 * hz, hx, 0.55 * hz),
            .mineHand: rect(-hx, 0.55 * hz, hx, hz),
            .tableRevealedLeft: rect(-hx, -0.55 * hz, -0.30 * hx, 0.30 * hz),
            .tableRevealedFar: rect(-hx, -hz, hx, -0.55 * hz),
            .tableRevealedRight: rect(0.30 * hx, -0.55 * hz, hx, 0.30 * hz),
        ]
    }
}
