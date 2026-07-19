import Foundation
import Recognition
import simd

/// The user-confirmed table (Technical design §4.2 corners + §4.3 zones) —
/// what Chunk D's capture loop and the census consume. Anchor-local metres
/// throughout, packed exactly like `Recognition.TableProjection`'s own
/// convention — `SIMD2(x: local x, y: local z)` (see that type's doc) —
/// every 2D point in this file, `TableQuadProposal`, and
/// `TableCalibrationView` shares this packing so they interoperate without
/// any silent axis remapping.
public struct CalibratedTable {
    /// Four corners, anchor-local metres, in `TableQuadProposal.Proposal`'s
    /// winding order: near-left (closest to the user, left), near-right,
    /// far-right, far-left. Exactly four elements by construction — every
    /// initializer/mutator in this type enforces that invariant.
    public private(set) var corners: [SIMD2<Float>]
    /// The calibration UI's user-edge slider (§4.3: "the setup UI lets the
    /// user adjust the user-edge boundary after the four table corners") —
    /// how deep the `mineHand` band reaches into the table, as a fraction of
    /// the near→far extent. Clamped to a sane range by `settingHandBandFraction`.
    public private(set) var handBandFraction: Float
    /// Per-zone polygons (§4.3), re-derived from `corners`/`handBandFraction`
    /// on every mutation — independent shapes, not one shared grid. A zone
    /// absent from this dictionary (currently always `.ignoredWall`, which
    /// §4.3 calls optional and has no canonical default region) has no
    /// coverage claim at all, matching `Recognition.CoverageMask`'s "a set,
    /// not a bounding box" philosophy one level up, at the calibration layer.
    public private(set) var zones: [SemanticZoneID: [SIMD2<Float>]]

    public static let defaultHandBandFraction: Float = 0.22
    public static let handBandFractionRange: ClosedRange<Float> = 0.05...0.60
    public static let meldBandFraction: Float = 0.08
    public static let opponentStripFraction: Float = 0.16
    /// How much of the interior rectangle left over after the hand/meld
    /// band and the three opponent strips are removed the `tablePond`
    /// octagon reaches — `1.0` would touch every remaining edge; `0.85`
    /// leaves a small unassigned (unresolved-by-omission) margin.
    public static let pondInnerRectFraction: Float = 0.85
    private static let pondVertexCount = 8

    /// `nil` unless `corners.count == 4` — the only shape this type accepts.
    /// Zones start from `defaultZones` at `handBandFraction`.
    public init?(corners: [SIMD2<Float>], handBandFraction: Float = defaultHandBandFraction) {
        guard corners.count == 4 else { return nil }
        self.corners = corners
        self.handBandFraction = handBandFraction.clamped(to: Self.handBandFractionRange)
        self.zones = Self.defaultZones(corners: corners, handBandFraction: self.handBandFraction)
    }

    /// Builds directly from a `TableQuadProposal.Proposal` — the common
    /// construction path once the scored proposal exists but before the
    /// user has dragged anything.
    public init?(proposal: TableQuadProposal.Proposal, handBandFraction: Float = defaultHandBandFraction) {
        self.init(corners: proposal.corners, handBandFraction: handBandFraction)
    }

    /// Replaces one corner (0=near-left, 1=near-right, 2=far-right,
    /// 3=far-left — `TableQuadProposal.Proposal`'s order) by index and
    /// re-derives every zone polygon from the new corner set — a corner
    /// drag always keeps the zone layout consistent with the visible
    /// quadrilateral, matching §4.3's "calibration produces polygons ...
    /// derived from the quad." Out-of-range indices are ignored (the
    /// caller, `TableCalibrationView`, only ever drives this with 0...3).
    public mutating func movingCorner(_ index: Int, to point: SIMD2<Float>) {
        guard corners.indices.contains(index) else { return }
        corners[index] = point
        zones = Self.defaultZones(corners: corners, handBandFraction: handBandFraction)
    }

    /// The user-edge slider's setter (see `handBandFraction`'s doc) — clamps
    /// to `handBandFractionRange` and re-derives every zone polygon.
    public mutating func settingHandBandFraction(_ fraction: Float) {
        handBandFraction = fraction.clamped(to: Self.handBandFractionRange)
        zones = Self.defaultZones(corners: corners, handBandFraction: handBandFraction)
    }

    // MARK: - Default zone layout (§4.3)

    /// Builds every §4.3 zone polygon (except the optional `.ignoredWall`)
    /// from the confirmed quad, purely by interpolating along its four
    /// edges — works for ANY (not just axis-aligned/rectangular)
    /// quadrilateral, so a corner drag that skews the shape still produces
    /// sane zones. `nearLeft`/`nearRight`/`farRight`/`farLeft` follow
    /// `TableQuadProposal.Proposal`'s documented corner order.
    public static func defaultZones(corners: [SIMD2<Float>],
                                    handBandFraction: Float = defaultHandBandFraction) -> [SemanticZoneID: [SIMD2<Float>]] {
        guard corners.count == 4 else { return [:] }
        let nearLeft = corners[0], nearRight = corners[1], farRight = corners[2], farLeft = corners[3]
        let hand = handBandFraction.clamped(to: handBandFractionRange)
        let meld = meldBandFraction
        let strip = opponentStripFraction

        func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> { a + (b - a) * t }
        /// A point at fractional position `(u, v)` across the quad: `u` runs
        /// left(0)→right(1) along both the near and far edges, `v` runs
        /// near(0)→far(1) between them. Bilinear, so it stays correct for a
        /// skewed (non-rectangular) confirmed quad.
        func point(_ u: Float, _ v: Float) -> SIMD2<Float> {
            let near = lerp(nearLeft, nearRight, u)
            let far = lerp(farLeft, farRight, u)
            return lerp(near, far, v)
        }
        func polygon(_ points: [(Float, Float)]) -> [SIMD2<Float>] { points.map { point($0.0, $0.1) } }

        var zones: [SemanticZoneID: [SIMD2<Float>]] = [:]

        // mineHand: the full-width band along the near (user) edge.
        zones[.mineHand] = polygon([(0, 0), (1, 0), (1, hand), (0, hand)])

        // mineMeld: a thinner strip just inboard of the hand band, still on
        // the user's side — exposed melds sit between the hand and the pond.
        let meldOuter = min(1, hand + meld)
        zones[.mineMeld] = polygon([(0, hand), (1, hand), (1, meldOuter), (0, meldOuter)])

        // tableRevealedFar/Left/Right: strips along the other three edges.
        // Left/Right run the full length of their own edge, between the
        // meld band and the far strip.
        let innerVLow = meldOuter
        let innerVHigh = max(innerVLow, 1 - strip)
        zones[.tableRevealedFar] = polygon([(0, 1), (1, 1), (1, 1 - strip), (0, 1 - strip)])
        zones[.tableRevealedLeft] = polygon([(0, innerVLow), (strip, innerVLow), (strip, innerVHigh), (0, innerVHigh)])
        zones[.tableRevealedRight] = polygon([(1 - strip, innerVLow), (1, innerVLow), (1, innerVHigh), (1 - strip, innerVHigh)])

        // tablePond: an octagon approximating a disk, inscribed in the
        // interior rectangle left over after every edge strip above. §4.3
        // only requires polygons, not a true circle.
        let innerULow: Float = strip, innerUHigh: Float = 1 - strip
        if innerUHigh > innerULow, innerVHigh > innerVLow {
            let centerU = (innerULow + innerUHigh) / 2
            let centerV = (innerVLow + innerVHigh) / 2
            let halfU = (innerUHigh - innerULow) / 2 * pondInnerRectFraction
            let halfV = (innerVHigh - innerVLow) / 2 * pondInnerRectFraction
            var pond: [SIMD2<Float>] = []
            pond.reserveCapacity(pondVertexCount)
            for k in 0..<pondVertexCount {
                let angle = 2 * Float.pi * Float(k) / Float(pondVertexCount)
                pond.append(point(centerU + halfU * cos(angle), centerV + halfV * sin(angle)))
            }
            zones[.tablePond] = pond
        }

        // boundaryUnresolved: a narrow band straddling the hand/meld
        // ownership boundary — deliberately overlaps `mineHand`/`mineMeld`
        // slightly; resolving that overlap is the census's job (§10.1), not
        // calibration's.
        let boundaryHalf: Float = 0.03
        let boundaryLow = max(0, hand - boundaryHalf)
        let boundaryHigh = min(1, hand + boundaryHalf)
        zones[.boundaryUnresolved] = polygon([(0, boundaryLow), (1, boundaryLow), (1, boundaryHigh), (0, boundaryHigh)])

        return zones
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
