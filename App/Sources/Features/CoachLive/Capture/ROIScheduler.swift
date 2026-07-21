import CoreGraphics
import Foundation
import ImageIO
import Recognition
import simd

/// Stable identity for the five table-space regions
/// `ROIScheduler.projectedZoneRects` reports — shared by explicit recount
/// requests and the per-zone staleness/rescan-prompt tracker.
enum TableZoneID: CaseIterable, Hashable, Sendable {
    case hand, pond, meldLeft, meldRight, meldFar

    /// The rescan-prompt chip's zone name ("Pan left to check ___ ←").
    var displayName: String {
        switch self {
        case .hand:      return "your hand"
        case .pond:      return "the pond"
        case .meldLeft:  return "the tiles on your left"
        case .meldRight: return "the tiles on your right"
        case .meldFar:   return "the far side"
        }
    }

    /// Compact, stable name for diagnostics. Keep this distinct from the
    /// customer-facing `displayName`: it is a machine-auditable account of
    /// work that really reached the recognizer.
    var debugLabel: String {
        switch self {
        case .hand: return "hand"
        case .pond: return "pond"
        case .meldLeft: return "left"
        case .meldRight: return "right"
        case .meldFar: return "far"
        }
    }
}

/// Decides, per still-tick of the AR loop, whether to run a full-frame
/// recognize pass or crop down to just the table regions that visibly
/// changed (Lane B chunk E). Pure + deterministic given its inputs; the only
/// mutable state is `lastFullFrameAt` (the periodic safety-net clock) plus
/// `lastPlanLabels` (a debug-only breadcrumb for `LiveFeedPane`'s HUD — see
/// its own doc).
///
/// Two phases, cleanly separated:
/// 1. `projectedZoneRects` — pure, given a `TableProjection` (injected
///    matrices) — turns the tracker's FIXED table-space zone geometry
///    (`TrackerConfig.TableGeometry`: the hand band, the central pond disk,
///    the other three edges' meld strips) into oriented-image rects, the
///    same corners-then-bounding-box recipe
///    `CoachLiveSession.projectedTableRect` uses for the bracket overlay.
///    Using the GEOMETRIC regions (not currently-tracked tile boxes) means
///    the scheduler always knows roughly where to look even before any tile
///    has actually been detected there.
/// 2. `decide` — given those rects plus a `MotionField` (which cells
///    changed, in the RAW/un-rotated grid `MotionDetector` builds), the
///    my-turn flag, and whether the camera just settled — picks a plan.
struct ROIScheduler {

    /// The one-at-a-time first pass after calibration. It deliberately lives
    /// in the scheduler (rather than in a second recognizer loop), so it
    /// shares the normal thermal budget and cannot starve a region forever.
    enum VerificationStatus: Equatable {
        case inactive
        case verifying(zone: TableZoneID, successfulReads: Int)
        case complete

        var debugLabel: String {
            switch self {
            case .inactive: return "—"
            case let .verifying(zone, reads):
                return "verifying \(zone.debugLabel) \(reads)/3"
            case .complete: return "verified"
            }
        }
    }

    /// One named zone's oriented-image rect (or `nil` if it didn't project
    /// onto this frame at all — see `projectedZoneRects`). The three meld
    /// edges are kept as separate named fields (rather than the flat array
    /// this type shipped with pre-chunk-H) so callers that need to know
    /// WHICH edge — explicit recounts and the per-zone staleness tracker — can
    /// address them individually; `melds` stays as a computed convenience
    /// for `decide`, which never cared which edge, only "is any meld zone
    /// dirty."
    struct ZoneRects {
        var hand: TileBoundingBox?
        var pond: TileBoundingBox?
        var meldLeft: TileBoundingBox?
        var meldRight: TileBoundingBox?
        var meldFar: TileBoundingBox?

        /// Priority order matches `projectedZoneRects`'s original
        /// left→right→far construction.
        var melds: [TileBoundingBox] { [meldLeft, meldRight, meldFar].compactMap { $0 } }

        init(hand: TileBoundingBox? = nil, pond: TileBoundingBox? = nil,
             meldLeft: TileBoundingBox? = nil, meldRight: TileBoundingBox? = nil, meldFar: TileBoundingBox? = nil) {
            self.hand = hand
            self.pond = pond
            self.meldLeft = meldLeft
            self.meldRight = meldRight
            self.meldFar = meldFar
        }

        /// Every zone that actually projected onto this frame, paired with
        /// its stable identity for staleness and explicit recount requests.
        var identified: [(id: TableZoneID, rect: TileBoundingBox)] {
            var out: [(TableZoneID, TileBoundingBox)] = []
            if let hand { out.append((.hand, hand)) }
            if let pond { out.append((.pond, pond)) }
            if let meldLeft { out.append((.meldLeft, meldLeft)) }
            if let meldRight { out.append((.meldRight, meldRight)) }
            if let meldFar { out.append((.meldFar, meldFar)) }
            return out
        }
    }

    enum InferencePlan: Equatable {
        case fullFrame
        /// NATIVE pixel rects (already padded/clamped/even-snapped by
        /// `ROICropMapper.cropRect`) — one crop per dirty zone, in priority
        /// order (hand first when it's my turn).
        case crops([CGRect])
        case none
    }

    /// Safety-net cadence: infer the FULL frame at least this often even if
    /// nothing looks dirty, so a change the change-grid missed (a very slow
    /// fade, or a zone the grid's coarse 32×18 resolution straddles badly)
    /// still gets caught eventually.
    var fullFrameInterval: TimeInterval = 20

    /// The only crop budget. Call sites must execute every crop returned by
    /// `decide`; keeping this cap here means a third planned crop can never
    /// silently disappear in the AR loop.
    var maximumCropsPerTick = 2

    private var lastFullFrameAt: TimeInterval?
    /// Debug-only breadcrumb (Lane B chunk E's HUD requirement) — which
    /// named zones the most recent `.crops` plan targeted, in priority
    /// order; `["full"]` after `.fullFrame`, `[]` after `.none`. Never read
    /// by `decide` itself — purely for `LiveFeedPane`'s triple-tap HUD.
    private(set) var lastPlanLabels: [String] = []

    /// Labels for work that has been selected but has not reached the
    /// recognizer yet. They are intentionally private: the production HUD
    /// reports `lastPlanLabels`, which is updated only by
    /// `recordCropExecution` / `recordFullFrameExecution`.
    private var plannedZoneIDs: [TableZoneID] = []
    private var pending: [TableZoneID: PendingCrop] = [:]
    private var fairQueue = DeferredRegionWorkQueue<TableZoneID>()
    private var verificationQueue = BoundedRegionVerificationQueue<TableZoneID>()

    private struct PendingCrop {
        var rect: TileBoundingBox
        /// A deferred crop may outlive a camera pan. Keep it queued, but do
        /// not execute its stale image-space rectangle until it projects on
        /// the current frame again.
        var isProjected: Bool
    }

    init(fullFrameInterval: TimeInterval = 20) {
        self.fullFrameInterval = fullFrameInterval
    }

    /// Starts the non-blocking confirmation pass. It does not run a model and
    /// it does not bypass cadence; the next normal inference opportunities
    /// consume the queue in the requested physical order.
    mutating func beginPostCalibrationVerification() {
        verificationQueue.begin(
            order: [.hand, .pond, .meldLeft, .meldFar, .meldRight]
        )
    }

    var verificationStatus: VerificationStatus {
        guard let zone = verificationQueue.current else {
            return verificationQueue.isComplete ? .complete : .inactive
        }
        return .verifying(
            zone: zone,
            successfulReads: verificationQueue.successfulReadsForCurrent
        )
    }

    /// Reports that selected crop work reached the recognizer. Failed crop
    /// plumbing deliberately remains pending. `stabilizedZoneIDs` is optional
    /// because face/anchor stability belongs to the census layer, not this
    /// scheduler; passing it allows that layer to end a zone before its third
    /// successful read.
    mutating func recordCropExecution(
        executedIndices: [Int],
        recognizerSucceeded: Bool,
        stabilizedZoneIDs: Set<TableZoneID> = []
    ) {
        let executed = executedIndices.compactMap { index in
            plannedZoneIDs.indices.contains(index) ? plannedZoneIDs[index] : nil
        }
        guard !executed.isEmpty else {
            lastPlanLabels = []
            return
        }

        // It was an actual recognizer invocation even if Vision returned an
        // error, so it belongs in the HUD. It stays queued on failure.
        lastPlanLabels = executed.map(\.debugLabel)
        guard recognizerSucceeded else { return }

        // Keep confirmation genuinely ordered. A second crop can still do
        // useful normal tracking work, but it cannot advance the next region
        // until the head has received its bounded reads.
        let verificationHead = verificationQueue.current
        for zone in executed {
            pending.removeValue(forKey: zone)
            fairQueue.complete(zone)
            if zone == verificationHead {
                recordSuccessfulVerificationRead(for: zone,
                                                 stabilized: stabilizedZoneIDs.contains(zone))
            }
        }
    }

    /// A successful tiled full-frame read advances only the queue head. The
    /// recognizer has looked at everything, but maintaining the requested
    /// hand → pond → left → far → right order keeps the status honest.
    mutating func recordFullFrameExecution(
        recognizerSucceeded: Bool,
        stabilizedZoneIDs: Set<TableZoneID> = []
    ) {
        lastPlanLabels = ["full"]
        guard recognizerSucceeded else { return }
        for zone in plannedZoneIDs {
            pending.removeValue(forKey: zone)
            fairQueue.complete(zone)
        }
        if let zone = verificationQueue.current,
           plannedZoneIDs.contains(zone) {
            recordSuccessfulVerificationRead(for: zone,
                                             stabilized: stabilizedZoneIDs.contains(zone))
        }
    }

    /// Region identities paired with the most recently returned crop/full
    /// plan. The session uses this only to calculate census stabilization for
    /// the exact work that reached Vision.
    var plannedRegions: [TableZoneID] { plannedZoneIDs }

    /// Projects the tracker's fixed table-space zone geometry into
    /// oriented-normalized image rects — see the type doc's phase 1. A
    /// region's rect is `nil` exactly when every one of its corners fails to
    /// project (off-screen this frame), matching `projectedTableRect`'s own
    /// contract.
    static func projectedZoneRects(geometry: TrackerConfig.TableGeometry,
                                    projection: TableProjection,
                                    orientedImageSize: CGSize,
                                    imageTransform: FrameImageTransform? = nil) -> ZoneRects {
        guard geometry.extent > 0 else { return ZoneRects() }
        let extent = geometry.extent
        let orientedSize = SIMD2<Double>(Double(orientedImageSize.width), Double(orientedImageSize.height))

        func local(_ n: Double) -> Double { (n - 0.5) * extent }
        func rect(_ corners: [SIMD2<Double>]) -> TileBoundingBox? {
            let localCorners = corners.map { SIMD2<Double>(local($0.x), local($0.y)) }
            let projected = localCorners.compactMap {
                if let imageTransform {
                    return projection.normalizedOrientedPoint(
                        ofTablePoint: $0,
                        imageTransform: imageTransform
                    )
                }
                return projection.normalizedOrientedPoint(
                    ofTablePoint: $0,
                    orientedImageSize: orientedSize
                )
            }
            guard !projected.isEmpty else { return nil }
            let xs = projected.map(\.x), ys = projected.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            return TileBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        // Table-space normalized [0,1], plane anchor (0.5,0.5), larger y toward
        // me. The hand + opponent-meld regions are oriented bands (their
        // bounding box, possibly tilted); the pond is a disk or a rect — its
        // own bounding-box corners either way.
        let hand = rect(geometry.handBand.corners)
        let pond = rect(geometry.pond.corners)
        let left = geometry.meldBands[.left].flatMap { rect($0.corners) }
        let right = geometry.meldBands[.right].flatMap { rect($0.corners) }
        let far = geometry.meldBands[.across].flatMap { rect($0.corners) }

        return ZoneRects(hand: hand, pond: pond, meldLeft: left, meldRight: right, meldFar: far)
    }

    /// Projects the exact polygons captured by guided calibration. This is
    /// the authoritative AR-mode geometry path; it deliberately does not
    /// reconstruct square bands from a scalar extent.
    static func projectedZoneRects(
        calibration: WorldTableCalibration,
        projection: TableProjection,
        imageTransform: FrameImageTransform
    ) -> ZoneRects {
        func rect(_ corners: [SIMD2<Float>]) -> TileBoundingBox? {
            let projected = corners.compactMap {
                projection.normalizedOrientedPoint(
                    ofTablePoint: SIMD2(Double($0.x), Double($0.y)),
                    imageTransform: imageTransform
                )
            }
            guard !projected.isEmpty else { return nil }
            let xs = projected.map(\.x)
            let ys = projected.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else {
                return nil
            }
            return TileBoundingBox(
                x: minX, y: minY,
                width: maxX - minX, height: maxY - minY
            )
        }

        return ZoneRects(
            hand: rect(calibration.handPolygon),
            pond: rect(calibration.pondPolygon),
            meldLeft: calibration.revealedZonePolygons[.tableRevealedLeft]
                .flatMap(rect),
            meldRight: calibration.revealedZonePolygons[.tableRevealedRight]
                .flatMap(rect),
            meldFar: calibration.revealedZonePolygons[.tableRevealedFar]
                .flatMap(rect)
        )
    }

    /// The five zones' TABLE-space centers — fixed, camera-pose-independent
    /// points using the exact same corner geometry `projectedZoneRects`
    /// builds its rects from (Lane B chunk H). The per-zone staleness/
    /// rescan-prompt tracker projects these through the CURRENT camera pose
    /// to find which off-screen direction points at a stale zone: a zone's
    /// projected RECT goes `nil` once every corner fails to project (fully
    /// off-screen), but its single center point still projects to an
    /// unclamped — possibly outside `[0,1]` — coordinate as long as it's in
    /// front of the camera, which is exactly the signed "how far off left/
    /// right/up/down" reading a prompt needs.
    static func zoneCenters(geometry: TrackerConfig.TableGeometry) -> [TableZoneID: SIMD2<Double>] {
        guard geometry.extent > 0 else { return [:] }
        let extent = geometry.extent
        func local(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2((p.x - 0.5) * extent, (p.y - 0.5) * extent) }
        var out: [TableZoneID: SIMD2<Double>] = [
            .hand: local(geometry.handBand.center),
            .pond: local(geometry.pond.center),
        ]
        if let l = geometry.meldBands[.left] { out[.meldLeft] = local(l.center) }
        if let r = geometry.meldBands[.right] { out[.meldRight] = local(r.center) }
        if let f = geometry.meldBands[.across] { out[.meldFar] = local(f.center) }
        return out
    }

    static func zoneCenters(
        calibration: WorldTableCalibration
    ) -> [TableZoneID: SIMD2<Double>] {
        func center(_ polygon: [SIMD2<Float>]) -> SIMD2<Double>? {
            guard !polygon.isEmpty else { return nil }
            let sum = polygon.reduce(SIMD2<Float>.zero, +)
            let value = sum / Float(polygon.count)
            return SIMD2(Double(value.x), Double(value.y))
        }

        var result: [TableZoneID: SIMD2<Double>] = [:]
        result[.hand] = center(calibration.handPolygon)
        result[.pond] = center(calibration.pondPolygon)
        result[.meldLeft] = calibration.revealedZonePolygons[
            .tableRevealedLeft
        ].flatMap(center)
        result[.meldRight] = calibration.revealedZonePolygons[
            .tableRevealedRight
        ].flatMap(center)
        result[.meldFar] = calibration.revealedZonePolygons[
            .tableRevealedFar
        ].flatMap(center)
        return result
    }

    /// Fraction of `rect`'s own area that falls inside the visible
    /// `[0,1]x[0,1]` oriented-normalized frame — Lane B chunk H's shared
    /// "is this zone actually on screen enough to trust" bar (≥0.6), used
    /// by the per-zone staleness tracker.
    static func fractionInsideFrame(_ rect: TileBoundingBox) -> Double {
        guard rect.width > 0, rect.height > 0 else { return 0 }
        let minX = max(0, rect.x), minY = max(0, rect.y)
        let maxX = min(1, rect.x + rect.width), maxY = min(1, rect.y + rect.height)
        let interW = max(0, maxX - minX), interH = max(0, maxY - minY)
        return (interW * interH) / (rect.width * rect.height)
    }

    /// Phase 2 — see the type doc. Rules: on the moving→still edge or every
    /// `fullFrameInterval`, always full-frame (the existing safety-net
    /// behavior). Otherwise, a zone is "dirty" when at least one changed
    /// `MotionField` cell falls inside it; dirty zones become crops (hand
    /// first when it's my turn, else after pond/melds); no dirty zone at all
    /// (or no `motionField` to judge by) is `.none` — nothing to infer this
    /// tick.
    mutating func decide(motionField: MotionField?,
                          zones: ZoneRects,
                          myTurn: Bool,
                          justSettled: Bool,
                          orientedImageSize: CGSize,
                          imageResolution: CGSize,
                          imageOrientation: CGImagePropertyOrientation = .right,
                          at t: TimeInterval) -> InferencePlan {
        let dueForFullFrame = justSettled || lastFullFrameAt == nil || t - lastFullFrameAt! >= fullFrameInterval
        if dueForFullFrame {
            lastFullFrameAt = t
            // The HUD becomes "full" only after the recognizer actually
            // runs; this plan can still be abandoned by a later guard.
            plannedZoneIDs = zones.identified.map(\.id)
            lastPlanLabels = []
            return .fullFrame
        }

        func dirty(_ rect: TileBoundingBox) -> Bool {
            guard let motionField else { return false }
            return isDirty(
                rect,
                motionField: motionField,
                imageResolution: imageResolution,
                orientedImageSize: orientedImageSize,
                imageOrientation: imageOrientation
            )
        }

        // A dirty region is retained until a recognizer invocation succeeds.
        // This is the key difference from the old `prefix(2)` call-site cap:
        // a third region is deferred, not forgotten.
        let projected = Dictionary(uniqueKeysWithValues: zones.identified)
        for id in pending.keys {
            guard var old = pending[id] else { continue }
            if let current = projected[id] {
                old.rect = current
                old.isProjected = true
                fairQueue.setAvailable(true, for: id)
            } else {
                old.isProjected = false
                fairQueue.setAvailable(false, for: id)
            }
            pending[id] = old
        }
        for (id, rect) in zones.identified where dirty(rect) {
            if var old = pending[id] {
                old.rect = rect
                pending[id] = old
            } else {
                pending[id] = PendingCrop(rect: rect, isProjected: true)
                fairQueue.enqueue(id)
            }
        }

        // The verification queue is allowed to request an otherwise-still
        // region. If it is offscreen, do not manufacture a crop; it remains
        // queued until its exact calibrated polygon projects again.
        if let verificationZone = verificationQueue.current,
           let rect = projected[verificationZone] {
            if var old = pending[verificationZone] {
                old.rect = rect
                pending[verificationZone] = old
            } else {
                pending[verificationZone] = PendingCrop(rect: rect, isProjected: true)
                fairQueue.enqueue(verificationZone)
            }
        }

        guard !pending.isEmpty else {
            plannedZoneIDs = []
            lastPlanLabels = []
            return .none
        }

        let orderedIDs = fairQueue.select(
            maximum: maximumCropsPerTick,
            priority: verificationQueue.current,
            preferred: myTurn ? .hand : nil
        )

        var selected: [(TableZoneID, CGRect)] = []
        for id in orderedIDs {
            guard let pendingCrop = pending[id] else { continue }
            guard pendingCrop.isProjected else { continue }
            let cropRect = ROICropMapper.cropRect(forZoneImageRect: pendingCrop.rect,
                                                  orientedImageSize: orientedImageSize,
                                                  imageResolution: imageResolution,
                                                  imageOrientation: imageOrientation)
            guard cropRect.width >= 2, cropRect.height >= 2 else { continue }
            selected.append((id, cropRect))
        }

        guard !selected.isEmpty else {
            plannedZoneIDs = []
            lastPlanLabels = []
            return .none
        }

        plannedZoneIDs = selected.map(\.0)
        // Do not claim a crop in diagnostics before it ran.
        lastPlanLabels = []
        return .crops(selected.map(\.1))
    }

    private mutating func recordSuccessfulVerificationRead(
        for zone: TableZoneID,
        stabilized: Bool
    ) {
        verificationQueue.recordSuccessfulRead(
            for: zone,
            stabilized: stabilized,
            maximumReads: 3
        )
    }

    /// Whether any changed `MotionField` cell (native/raw grid space)
    /// overlaps `zoneRect` (oriented-image space) — each candidate cell is
    /// mapped forward via `ROICropMapper.orientedNormalizedRect` before the
    /// AABB test, so the comparison always happens in the same space.
    private func isDirty(_ zoneRect: TileBoundingBox, motionField: MotionField,
                          imageResolution: CGSize, orientedImageSize: CGSize,
                          imageOrientation: CGImagePropertyOrientation) -> Bool {
        guard imageResolution.width > 0, imageResolution.height > 0 else { return false }
        let cols = MotionField.gridWidth, rows = MotionField.gridHeight
        let cellW = imageResolution.width / CGFloat(cols)
        let cellH = imageResolution.height / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let idx = row * cols + col
                guard motionField.changed[idx] else { continue }
                let rawRect = CGRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
                let orientedRect = ROICropMapper.orientedNormalizedRect(fromRawRect: rawRect, rawSize: imageResolution,
                                                                        orientedSize: orientedImageSize,
                                                                        imageOrientation: imageOrientation)
                if boxesIntersect(orientedRect, zoneRect) { return true }
            }
        }
        return false
    }
}

/// AABB overlap test — App-side counterpart to `Recognition`'s own
/// (internal, cross-module-invisible) `boxesIntersect`; small enough that a
/// second copy here beats exposing a new public API for one call site.
private func boxesIntersect(_ a: TileBoundingBox, _ b: TileBoundingBox) -> Bool {
    a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
}
