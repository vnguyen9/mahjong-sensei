import Foundation
import QuartzCore
import MahjongCore
import Recognition
import simd

struct WorldCensusDiagnostics {
    var depthRejections: [DepthSampleRejection: Int] = [:]
    var depthSamplesAttempted = 0
    var depthSamplesAccepted = 0
    var recognizerFailures = 0
    var lastIngestMilliseconds: Double = 0
    var anchorReprojectionErrorPixels: Double = 0

    var depthAcceptanceRate: Double {
        guard depthSamplesAttempted > 0 else { return 0 }
        return Double(depthSamplesAccepted) / Double(depthSamplesAttempted)
    }
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
    private(set) var calibration: WorldTableCalibration?

    init(calibration: WorldTableCalibration, at time: TimeInterval) {
        self.calibration = calibration
        let origin = TableOriginState(
            guidedTableToWorld: calibration.tableToWorld,
            extent: calibration.extent,
            at: time
        )
        self.tableOrigin = origin
        self.worldToTable = origin.worldToTable
        self.zones = calibration.semanticZones
    }

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
        self.calibration = nil
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
        self.calibration = nil
    }

    var snapshot: CensusSnapshot {
        census.snapshot(at: CACurrentMediaTime())
    }

    func recordOrientationTransition() {
        diagnostics.depthRejections[.orientationTransition, default: 0] += 1
    }

    func updateTableSpace(worldToTable: simd_float4x4,
                          extent: SIMD2<Float>) {
        self.worldToTable = worldToTable
        if var calibration {
            calibration.tableToWorld = simd_inverse(worldToTable)
            calibration.extent = extent
            self.calibration = calibration
            zones = calibration.semanticZones
        } else {
            zones = Self.semanticZones(extent: extent)
        }
        census.reassignZones(zones, worldToTable: worldToTable)
        revision += 1
    }

    func apply(_ calibration: WorldTableCalibration, at time: TimeInterval) {
        self.calibration = calibration
        tableOrigin = TableOriginState(
            guidedTableToWorld: calibration.tableToWorld,
            extent: calibration.extent,
            at: time
        )
        worldToTable = tableOrigin.worldToTable
        zones = calibration.semanticZones
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
        let observations = detections.compactMap { detection -> TileObservation? in
            let points = Self.spatialSamplePoints(for: detection.box)
            var localPoints: [SIMD2<Float>] = []
            var surfaceDepths: [Float] = []
            for point in points {
                diagnostics.depthSamplesAttempted += 1
                let sample = DepthSampler.inspect(
                    atOrientedNormalized: point,
                    imageTransform: frame.imageTransform,
                    depthMap: frame.depthMap,
                    confidenceMap: frame.depthConfidence
                )
                guard let depth = sample.depthMeters else {
                    if let rejection = sample.rejection {
                        diagnostics.depthRejections[rejection, default: 0] += 1
                    }
                    continue
                }
                guard let measuredWorld = projection.worldPoint(
                    ofNormalizedOrientedPoint: point,
                    imageTransform: frame.imageTransform,
                    depthMeters: Double(depth)
                ) else {
                    diagnostics.depthRejections[.invalidGeometry, default: 0] += 1
                    continue
                }
                let local4 = simd_inverse(projection.planeTransform) * SIMD4(
                    measuredWorld.x, measuredWorld.y, measuredWorld.z, 1
                )
                guard local4.y >= -0.010, local4.y <= 0.060 else {
                    diagnostics.depthRejections[.heightOutOfRange, default: 0] += 1
                    continue
                }
                diagnostics.depthSamplesAccepted += 1
                localPoints.append(SIMD2(Float(local4.x), Float(local4.z)))
                surfaceDepths.append(depth)
            }
            guard !localPoints.isEmpty else { return nil }
            let tablePoint = SIMD2<Float>(
                Self.median(localPoints.map(\.x)),
                Self.median(localPoints.map(\.y))
            )
            let planeWorld4 = projection.planeTransform * SIMD4<Double>(
                Double(tablePoint.x), 0, Double(tablePoint.y), 1
            )
            if let reprojected = projection.normalizedOrientedPoint(
                ofWorldPoint: SIMD3(planeWorld4.x, planeWorld4.y, planeWorld4.z),
                imageTransform: frame.imageTransform
            ) {
                let dx = (reprojected.x - detection.box.centerX)
                    * frame.orientedImageSize.width
                let dy = (reprojected.y - detection.box.centerY)
                    * frame.orientedImageSize.height
                let error = hypot(dx, dy)
                diagnostics.anchorReprojectionErrorPixels =
                    diagnostics.anchorReprojectionErrorPixels == 0
                    ? error
                    : diagnostics.anchorReprojectionErrorPixels * 0.9
                        + error * 0.1
            }
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
                footprintCenter: tablePoint,
                footprintRadius: 0.012,
                worldPosition: SIMD3<Float>(
                    Float(planeWorld4.x), Float(planeWorld4.y), Float(planeWorld4.z)
                ),
                measuredSurfaceDepth: Self.median(surfaceDepths)
            )
        }

        let visibleIDs = Set(census.anchors.compactMap { anchor -> CensusTrackID? in
            guard let point = projection.normalizedOrientedPoint(
                ofWorldPoint: SIMD3<Double>(
                    Double(anchor.worldPosition.x),
                    Double(anchor.worldPosition.y),
                    Double(anchor.worldPosition.z)
                ),
                imageTransform: frame.imageTransform
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
                imageTransform: frame.imageTransform,
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
            guard Double(sampledDepth) >= expectedDepth - 0.040 else {
                diagnostics.depthRejections[.occluded, default: 0] += 1
                return nil
            }
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

    private static func spatialSamplePoints(
        for box: TileBoundingBox
    ) -> [SIMD2<Double>] {
        let cx = box.centerX
        let cy = box.centerY
        return [
            SIMD2(cx, cy),
            SIMD2(cx, cy - box.height * 0.20),
            SIMD2(cx, cy + box.height * 0.20),
            SIMD2(cx - box.width * 0.15, cy),
            SIMD2(cx + box.width * 0.15, cy),
        ].map {
            SIMD2(min(1, max(0, $0.x)), min(1, max(0, $0.y)))
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) * 0.5
            : sorted[middle]
    }

    func recenterPond(at worldPosition: SIMD3<Float>) {
        tableOrigin.recenterPond(at: worldPosition)
        if var calibration {
            calibration.tableToWorld = tableOrigin.tableToWorld
            calibration.source = .manualRecenter
            self.calibration = calibration
        }
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

    func setSeenCount(classIndex: Int, desiredCount: Int, at time: TimeInterval) {
        guard let tile = MahjongCore.Tile(classIndex: classIndex) else { return }
        let target = max(0, min(4, desiredCount))
        let eligibleZones: Set<SemanticZoneID> = [
            .tablePond,
            .tableRevealedLeft,
            .tableRevealedFar,
            .tableRevealedRight,
        ]
        let matching = census.snapshot(at: time).tracks.filter {
            guard $0.lifecycle != .tentative,
                  $0.lifecycle != .retired,
                  eligibleZones.contains($0.semanticZone),
                  case .tile(let face)? = $0.face else {
                return false
            }
            return face.classIndex == classIndex
        }.sorted { $0.id < $1.id }

        if matching.count > target {
            for track in matching.suffix(matching.count - target) {
                census.removeTrack(id: track.id)
            }
        } else if matching.count < target {
            let center = Self.polygonCenter(
                calibration?.pondPolygon ?? zones[.tablePond] ?? []
            )
            for ordinal in matching.count..<target {
                let point = Self.manualCorrectionPoint(
                    center: center,
                    classIndex: classIndex,
                    ordinal: ordinal
                )
                let world4 = tableOrigin.tableToWorld
                    * SIMD4<Float>(point.x, 0, point.y, 1)
                census.insertConfirmedTrack(
                    face: .tile(tile),
                    semanticZone: .tablePond,
                    tablePoint: point,
                    worldPosition: SIMD3(world4.x, world4.y, world4.z),
                    at: time
                )
            }
        }
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

    private static func polygonCenter(
        _ polygon: [SIMD2<Float>]
    ) -> SIMD2<Float> {
        guard !polygon.isEmpty else { return .zero }
        return polygon.reduce(.zero, +) / Float(polygon.count)
    }

    private static func manualCorrectionPoint(
        center: SIMD2<Float>,
        classIndex: Int,
        ordinal: Int
    ) -> SIMD2<Float> {
        // Stable 24 mm lattice: deterministic snapshots and no random UUID
        // geometry. The correction remains a census track and can later be
        // reconciled with an observed physical position.
        let slot = classIndex * 4 + ordinal
        let column = Float(slot % 9) - 4
        let row = Float((slot / 9) % 5) - 2
        return center + SIMD2(column * 0.024, row * 0.032)
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
