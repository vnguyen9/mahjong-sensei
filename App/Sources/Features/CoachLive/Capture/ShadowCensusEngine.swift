import CoreGraphics
import CoreVideo
import Foundation
import Recognition
import simd

/// Coach Live v2.5 Chunk D — the SHADOW census pass
/// (`Planning/Coach-Live-v2-5-Technical-Design.md` §7's recognition flow,
/// run for real, consumed by nothing production yet). One
/// `ShadowCensusEngine` owns its own `Recognition.PhysicalCensus` end to
/// end, entirely independent of `CoachLiveSession`'s v2 `TableTracker` —
/// nothing here ever touches `tracker` or any published production state.
/// `observe(frame:...)` only ever mutates `self` (its own `PhysicalCensus`
/// and `latestSnapshot`); the debug HUD alone reads `latestSnapshot`
/// (`CoachLiveSession.shadowCensusSummary` → `LiveFeedPane.debugHUD`).
///
/// Placeholder-model strategy (parent plan): both the locator and
/// classifier below wrap whatever `Recognizer` the session already resolved
/// for the real v2 loop (`PrototypeLocator`/`PrototypeClassifier`) — no
/// extra model load. Swapping in the release one-class locator / dedicated
/// face classifier later is a one-line change to `init`.
///
/// `observe` runs the whole §7 flow ONCE per call and never throws: every
/// internal stage failure is folded into an `ObservationOutcome` and handed
/// to the owned `PhysicalCensus` (which itself no-ops on anything but
/// `.success` — see that type's doc), so a shadow-pipeline error can never
/// propagate out and disrupt the caller's trusted loop. Meant to be invoked
/// at a low cadence (the caller's full-frame/settle ticks only — see
/// `CoachLiveSession.startARLoop`), not every tick; `maxTilesPerFrame` caps
/// per-call cost on top of that caller-side throttling.
@MainActor
final class ShadowCensusEngine {

    /// The census's current published state, refreshed at the end of every
    /// `observe` call regardless of outcome — `.skipped`/`.failed` can't
    /// have changed the underlying tracks, but the HUD still wants a fresh
    /// read (e.g. an updated `generatedAt`/staleness signal). `nil` until
    /// the first call.
    private(set) var latestSnapshot: CensusSnapshot?

    private let census = PhysicalCensus()
    private var frameIDs = FrameIDGenerator()
    private let cropper = PixelBufferCropper()
    private let locator: TileLocating
    private let classifier: TileClassifying

    // MARK: - Placeholder tuning (starting points, not calibrated — same
    // disclaimer as `Recognition.CensusConfig`'s own thresholds; §6.2 says
    // these "must be calibrated from labeled device frames," which this
    // shadow-only pass deliberately doesn't attempt).
    private static let edgeInset: Double = 0.02
    private static let requiredInsideFraction: Double = 0.95
    private static let minSharpness: Double = 0.02
    private static let minExposureScore: Double = 0.15
    private static let maxClippingFraction: Double = 0.35
    private static let minProjectedPixelsPerTile: Float = 24
    private static let tileFootprintRadius: Float = 0.02
    private static let maxTilesPerFrame = 40
    private static let tileCropPadding = 0.10

    /// `locatorRecognizer` backs Stage 1 (box + confidence only — its face
    /// labels are discarded by `PrototypeLocator`, so a real one-class `tile`
    /// locator model works through it unchanged); `classifierRecognizer` backs
    /// Stage 2's face read. They are usually two different bundled models now —
    /// the single-class `MahjongTileLocatorV3` locator and the 43-class detector
    /// as the placeholder classifier (the dedicated face classifier isn't
    /// trained yet) — but the caller may pass the same instance for both when
    /// the locator model isn't available (mock/unbundled fallback).
    init(locatorRecognizer: Recognizer, classifierRecognizer: Recognizer) {
        locator = PrototypeLocator(recognizer: locatorRecognizer)
        classifier = PrototypeClassifier(recognizer: classifierRecognizer)
    }

    /// Runs one full §7 pass over `frame` and folds the result into the
    /// owned `PhysicalCensus`. `table` is the calibrated quad + zones to
    /// project against (Chunk D's default-square stand-in until the real
    /// Chunk C calibration UX is wired into this loop — see
    /// `CoachLiveSession.makeDefaultShadowCensusTable`); `trackingNormal`
    /// mirrors §6.2's AR-tracking gate.
    func observe(frame: ARTableFrame, planeTransform: simd_float4x4, table: CalibratedTable,
                trackingNormal: Bool, at t: TimeInterval) async {
        let frameID = frameIDs.nextID()
        let zones = table.zones

        // §6.2 / §11.1: non-`.normal` tracking invalidates every new
        // spatial claim outright — never even attempt to project.
        guard trackingNormal else {
            finish(.skipped(.trackingNotNormal), zones: zones, at: t)
            return
        }

        let projection = TableProjection(cameraTransform: frame.cameraTransform,
                                         intrinsics: frame.intrinsics,
                                         imageResolution: SIMD2<Float>(Float(frame.imageResolution.width),
                                                                       Float(frame.imageResolution.height)),
                                         planeTransform: planeTransform)
        let orientedSize = frame.orientedImageSize
        let orientedSizeD = SIMD2<Double>(Double(orientedSize.width), Double(orientedSize.height))

        // Step 2 (§5.2/§7 flow): which calibrated zones actually project
        // into this frame — independent per-zone, never an AABB union.
        struct Zone { var id: SemanticZoneID; var polygonMetres: [SIMD2<Float>]; var imageBounds: TileBoundingBox }
        var observedZones: [Zone] = []
        for (zoneID, polygon) in zones {
            guard let bounds = Self.projectedImageBounds(polygon: polygon, projection: projection,
                                                          orientedImageSize: orientedSizeD) else { continue }
            observedZones.append(Zone(id: zoneID, polygonMetres: polygon, imageBounds: bounds))
        }
        guard !observedZones.isEmpty else {
            finish(.skipped(.zoneOffScreen), zones: zones, at: t)
            return
        }

        // Step 3 (§6.2): frame-level quality proxies — sharpness/exposure/
        // clipping are lighting properties, not zone geometry, so they're
        // computed once per frame (cheap, thermally modest) rather than
        // per zone.
        guard let luma = Self.lumaStats(of: frame.pixelBuffer) else {
            finish(.failed(.pixelCropFailed), zones: zones, at: t)
            return
        }
        let exposureScore = max(0, 1 - abs(luma.meanLuma - 128) / 128)
        var frameRejections: Set<FrameRejectionReason> = []
        if luma.sharpness < Self.minSharpness { frameRejections.insert(.belowSharpnessThreshold) }
        if exposureScore < Self.minExposureScore { frameRejections.insert(.exposureOutOfRange) }
        if luma.clippingFraction > Self.maxClippingFraction { frameRejections.insert(.excessiveClipping) }
        guard frameRejections.isEmpty else {
            finish(.skipped(.qualityRejected(frameRejections)), zones: zones, at: t)
            return
        }

        // Per-zone pixel-density gate — THIS varies meaningfully by zone (a
        // far pond zone projects to far fewer native pixels/tile than the
        // hand zone): a zone failing it is excluded from THIS frame's
        // evidence, but other qualified zones still contribute (§6.2: "if
        // quality too low for a zone, exclude that zone's crop").
        let qualifiedZones = observedZones.filter { zone in
            Self.projectedPixelsPerTile(atTableCentre: Self.centroid(zone.polygonMetres), projection: projection,
                                        orientedImageSize: orientedSizeD) >= Self.minProjectedPixelsPerTile
        }
        guard !qualifiedZones.isEmpty else {
            finish(.skipped(.qualityRejected([.tooFewProjectedPixelsPerTile])), zones: zones, at: t)
            return
        }

        let totalZoneArea = zones.values.reduce(Float(0)) { $0 + Self.polygonArea($1) }
        let observedArea = qualifiedZones.reduce(Float(0)) { $0 + Self.polygonArea($1.polygonMetres) }
        let coverageFraction = totalZoneArea > 0 ? min(1, observedArea / totalZoneArea) : 0
        let avgPixelsPerTile = qualifiedZones.reduce(Float(0)) { total, zone in
            total + Self.projectedPixelsPerTile(atTableCentre: Self.centroid(zone.polygonMetres),
                                                projection: projection, orientedImageSize: orientedSizeD)
        } / Float(qualifiedZones.count)

        let quality = FrameQuality(trackingIsNormal: true, sharpness: Float(luma.sharpness),
                                   exposureScore: Float(exposureScore), clippingFraction: Float(luma.clippingFraction),
                                   projectedPixelsPerTile: avgPixelsPerTile, coverageFraction: coverageFraction,
                                   accepted: true)

        // Step 4 (§7.1/§7.2): native zone crop → locate → map back to full
        // image → native per-tile crop → classify → project to table
        // space. ANY thrown stage aborts the WHOLE batch (§8: a thrown
        // inference must never quietly become an empty-but-successful
        // observation) rather than just excluding one zone/tile.
        var coveragePolygons: [ObservedPolygon] = []
        var observations: [TileObservation] = []
        var tilesSoFar = 0

        for zone in qualifiedZones {
            guard tilesSoFar < Self.maxTilesPerFrame else { break }
            let cropRect = ROICropMapper.cropRect(forZoneImageRect: zone.imageBounds,
                                                  orientedImageSize: orientedSize,
                                                  imageResolution: frame.imageResolution)
            guard cropRect != .zero, let cropBuffer = cropper.crop(frame.pixelBuffer, to: cropRect) else { continue }

            let localizations: [TileLocalization]
            do {
                localizations = try await locator.locate(in: LocatorInput(frame: .buffer(cropBuffer, orientation: .right)))
            } catch {
                finish(.failed(.locatorThrew(String(describing: error))), zones: zones, at: t)
                return
            }

            coveragePolygons.append(ObservedPolygon(zoneID: zone.id, vertices: zone.polygonMetres,
                                                     frameID: frameID, observedAt: t, quality: quality))

            for localization in localizations {
                guard tilesSoFar < Self.maxTilesPerFrame else { break }
                let fullBox = ROICropMapper.fullImageBox(fromCropNormalized: localization.box, cropRect: cropRect,
                                                         imageResolution: frame.imageResolution,
                                                         orientedImageSize: orientedSize)
                guard fullBox.width > 0, fullBox.height > 0 else { continue }
                let tileRect = ROICropMapper.cropRect(forZoneImageRect: fullBox, orientedImageSize: orientedSize,
                                                      imageResolution: frame.imageResolution, padding: Self.tileCropPadding)
                guard tileRect != .zero, let tileBuffer = cropper.crop(frame.pixelBuffer, to: tileRect) else { continue }

                let hypothesis: TileFaceHypothesis
                do {
                    hypothesis = try await classifier.classify(TileCrop(frame: .buffer(tileBuffer, orientation: .right),
                                                                        frameID: frameID))
                } catch {
                    finish(.failed(.classifierThrew(String(describing: error))), zones: zones, at: t)
                    return
                }

                tilesSoFar += 1
                let bottomCentre = SIMD2<Double>(fullBox.centerX, fullBox.y + fullBox.height)
                let anchorCentre = projection.tablePoint(ofNormalizedOrientedPoint: bottomCentre, orientedImageSize: orientedSizeD)
                observations.append(TileObservation(frameID: frameID, box: fullBox, confidence: localization.confidence,
                                                     poseHint: localization.poseHint, faceHypothesis: hypothesis,
                                                     footprintCenter: anchorCentre.map { SIMD2<Float>(Float($0.x), Float($0.y)) },
                                                     footprintRadius: anchorCentre == nil ? nil : Self.tileFootprintRadius))
            }
        }

        guard !coveragePolygons.isEmpty else {
            // Every qualified zone's own native crop failed (degenerate
            // rect / pool exhaustion) — the tooling broke, not "the table
            // was empty."
            finish(.failed(.pixelCropFailed), zones: zones, at: t)
            return
        }

        let batch = ObservationBatch(frameID: frameID, observations: observations,
                                     coverage: CoverageMask(regions: coveragePolygons), quality: quality)
        finish(.success(batch), zones: zones, at: t)
    }

    /// Every exit path funnels through here (§8's outcome contract): feed
    /// the outcome to `PhysicalCensus.ingest` (a no-op for anything but
    /// `.success` — see that type's doc) and refresh the HUD snapshot.
    private func finish(_ outcome: ObservationOutcome, zones: [SemanticZoneID: [SIMD2<Float>]], at t: TimeInterval) {
        census.ingest(outcome, zones: zones, at: t)
        latestSnapshot = census.snapshot(at: t)
    }

    // MARK: - Step 2: per-zone projectability + image bounds

    /// Projects every vertex of `polygon` (anchor-local metres) into
    /// oriented-normalized image space; `nil` if any vertex falls behind
    /// the camera, or fewer than 95% of the projected vertices land inside
    /// the image bounds shrunk by `edgeInset` (§3.2's "≥95% inside the
    /// captured image, excluding a small edge-safety inset"). Otherwise
    /// returns the (image-space) bounding box of the projected vertices —
    /// what `ROICropMapper.cropRect` crops against.
    private static func projectedImageBounds(polygon: [SIMD2<Float>], projection: TableProjection,
                                             orientedImageSize: SIMD2<Double>) -> TileBoundingBox? {
        guard polygon.count >= 3 else { return nil }
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(polygon.count)
        for vertex in polygon {
            guard let p = projection.normalizedOrientedPoint(ofTablePoint: SIMD2<Double>(Double(vertex.x), Double(vertex.y)),
                                                             orientedImageSize: orientedImageSize) else { return nil }
            points.append(p)
        }
        let insideCount = points.filter {
            $0.x >= edgeInset && $0.x <= 1 - edgeInset && $0.y >= edgeInset && $0.y <= 1 - edgeInset
        }.count
        guard Double(insideCount) / Double(points.count) >= requiredInsideFraction else { return nil }

        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = max(0, xs.min() ?? 0), maxX = min(1, xs.max() ?? 0)
        let minY = max(0, ys.min() ?? 0), maxY = min(1, ys.max() ?? 0)
        guard maxX > minX, maxY > minY else { return nil }
        return TileBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func centroid(_ polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !polygon.isEmpty else { return SIMD2<Float>(0, 0) }
        var sum = SIMD2<Float>(0, 0)
        for p in polygon { sum += p }
        return sum / Float(polygon.count)
    }

    /// Native oriented-image pixels spanned by a ~32mm tile at `centre`
    /// (§6.2's `projectedPixelsPerTile`): two table points 32mm apart at
    /// the zone's centre, projected and measured in oriented-image pixels.
    /// `0` when either point can't project (behind the camera).
    private static func projectedPixelsPerTile(atTableCentre centre: SIMD2<Float>, projection: TableProjection,
                                               orientedImageSize: SIMD2<Double>) -> Float {
        let c = SIMD2<Double>(Double(centre.x), Double(centre.y))
        guard let p0 = projection.normalizedOrientedPoint(ofTablePoint: c, orientedImageSize: orientedImageSize),
              let p1 = projection.normalizedOrientedPoint(ofTablePoint: SIMD2(c.x + 0.032, c.y),
                                                          orientedImageSize: orientedImageSize)
        else { return 0 }
        let dx = (p1.x - p0.x) * orientedImageSize.x
        let dy = (p1.y - p0.y) * orientedImageSize.y
        return Float((dx * dx + dy * dy).squareRoot())
    }

    /// Shoelace polygon area — mirrors `PhysicalCensus`'s own private
    /// helper (same formula; duplicated here rather than exposed publicly
    /// from the package for this one debug-only caller).
    private static func polygonArea(_ vertices: [SIMD2<Float>]) -> Float {
        guard vertices.count >= 3 else { return 0 }
        var sum: Float = 0
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            sum += (vertices[j].x + vertices[i].x) * (vertices[j].y - vertices[i].y)
            j = i
        }
        return abs(sum) / 2
    }

    // MARK: - Step 3: cheap luma proxies. ARKit's `capturedImage` is always
    // 420 bi-planar (unlike `Recognition.MotionDetector`'s buffer, which
    // also has to handle the app's own unpinned `BGRA` camera output), so
    // this only needs the one plane-0 path — a direct strided sample, no
    // `vImage` downscale needed at this sample count.

    private static func lumaStats(of buffer: CVPixelBuffer,
                                  samplesPerAxis: Int = 24) -> (meanLuma: Double, clippingFraction: Double, sharpness: Double)? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            break
        default:
            return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 1, height > 1, rowBytes > 0 else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let stepX = max(1, width / samplesPerAxis)
        let stepY = max(1, height / samplesPerAxis)
        var grid = [[UInt8]](repeating: [UInt8](repeating: 0, count: samplesPerAxis), count: samplesPerAxis)
        var sum = 0.0
        var clipped = 0
        var total = 0
        for row in 0..<samplesPerAxis {
            let y = min(height - 1, row * stepY)
            for col in 0..<samplesPerAxis {
                let x = min(width - 1, col * stepX)
                let value = ptr[y * rowBytes + x]
                grid[row][col] = value
                sum += Double(value)
                if value < 8 || value > 247 { clipped += 1 }
                total += 1
            }
        }
        guard total > 0 else { return nil }

        // Cheap gradient-energy sharpness proxy — mean absolute difference
        // between horizontally/vertically adjacent SAMPLED grid points
        // (not full-resolution Laplacian-of-Gaussian; "honest proxy," not
        // a calibrated metric — see §6.2).
        var gradientSum = 0.0
        var gradientCount = 0
        for row in 0..<samplesPerAxis {
            for col in 1..<samplesPerAxis {
                gradientSum += Double(abs(Int(grid[row][col]) - Int(grid[row][col - 1])))
                gradientCount += 1
            }
        }
        for row in 1..<samplesPerAxis {
            for col in 0..<samplesPerAxis {
                gradientSum += Double(abs(Int(grid[row][col]) - Int(grid[row - 1][col])))
                gradientCount += 1
            }
        }
        let sharpness = gradientCount > 0 ? (gradientSum / Double(gradientCount)) / 255 : 0

        return (sum / Double(total), Double(clipped) / Double(total), sharpness)
    }
}
