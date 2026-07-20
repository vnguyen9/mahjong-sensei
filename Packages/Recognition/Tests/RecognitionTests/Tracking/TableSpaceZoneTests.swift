import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Lane B chunk C coverage: `ZoneModel`'s `.tableSpace` branch — fixed-geometry
/// zoning that replaces the image-space parser + learned calibration when the
/// boxes are normalized table-plane coordinates (`DetectionProjector` output:
/// plane anchor at (0.5, 0.5), larger y toward me).
///
/// All frames here are hand-built, deterministic table-space `DetectedTile`s
/// (the plan explicitly allows this over routing through `DetectionProjector`)
/// so each threshold — my-edge hand band, central pond disk, edge-hugging
/// meld — is exercised in isolation. Boxes use a realistic table-space tile
/// footprint (~24×32mm over a 0.9m extent → ~0.027×0.036 normalized).
///
/// The whole point of the branch is that only the vote *source* changes: the
/// ledger/hysteresis/resolve machinery is shared with image space, so the
/// hysteresis test below mirrors `ZoneModelTests`' image-space one, and the
/// last test confirms the default (`.imageSpace`, no `tableGeometry`) path is
/// wholly untouched.
final class TableSpaceZoneTests: XCTestCase {

    // MARK: - Fixtures

    /// A table-space (or, with explicit `w`/`h`, image-space) box centered at
    /// `(cx, cy)`. Table-space default footprint ≈ a 24×32mm tile / 0.9m extent.
    private func box(_ cx: Double, _ cy: Double, w: Double = 0.027, h: Double = 0.036) -> TileBoundingBox {
        TileBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func det(_ tile: Tile, _ box: TileBoundingBox, _ conf: Double = 0.9) -> DetectedTile {
        DetectedTile(tile: tile, confidence: conf, box: box)
    }

    /// A `.tableSpace` config with the given (defaulted) geometry.
    private func tableConfig(handBandDepth: Double = 0.18, pondRadius: Double = 0.30) -> TrackerConfig {
        var config = TrackerConfig()
        config.coordinateSpace = .tableSpace
        config.tableGeometry = TrackerConfig.TableGeometry(handBandDepth: handBandDepth, pondRadius: pondRadius)
        return config
    }

    /// One settled ingest with no motion — the direct-drive equivalent of one
    /// `TrackerHarness` settle, exactly like `ZoneModelTests.ingest`.
    private func ingest(_ dets: [DetectedTile], _ store: TrackStore, _ zone: ZoneModel, at t: TimeInterval) {
        let outcome = store.associate(dets, at: t)
        zone.ingestSettled(detections: dets, outcome: outcome, store: store, at: t)
    }

    private func dealHand() -> [Tile] {
        [.m(1), .m(2), .m(3), .m(4), .m(5), .p(2), .p(3), .p(4), .s(6), .s(7), .s(8), .east, .west]
    }

    private func zoneSummary(_ tracks: [TrackedTile]) -> String {
        tracks.sorted { $0.id < $1.id }.map { "\($0.face)@\($0.zone.rawValue)" }.joined(separator: ",")
    }

    // MARK: - 1. My-edge row vs the same row in the pond

    func testRowAtMyEdgeIsMyHandButSameRowAtCenterIsPond() {
        let faces = dealHand()   // 13, none bonus
        // 13-tile row centered on x=0.5, spacing 0.04 → x ∈ [0.26, 0.74]; that
        // span fits inside pondRadius (0.30) when centered vertically, so the
        // *identical* x-layout is a hand at my edge and a pond spread at center.
        func row(atY y: Double) -> [DetectedTile] {
            faces.enumerated().map { i, f in det(f, box(0.5 + Double(i - 6) * 0.04, y)) }
        }

        // y ≈ 0.9: within handBandDepth of my (high-y) edge → myHand.
        let cfgHand = tableConfig()
        let storeHand = TrackStore(config: cfgHand), zoneHand = ZoneModel(config: cfgHand)
        for i in 0..<8 { ingest(row(atY: 0.9), storeHand, zoneHand, at: Double(i) * 0.2) }
        let handTracks = storeHand.tracks
        XCTAssertEqual(handTracks.count, 13)
        XCTAssertTrue(handTracks.allSatisfy { $0.zone == .myHand },
                      "a ≥3-tile row hugging my edge resolves myHand: \(zoneSummary(handTracks))")

        // y ≈ 0.5: the same row now sits in the central pond disk → pond.
        let cfgPond = tableConfig()
        let storePond = TrackStore(config: cfgPond), zonePond = ZoneModel(config: cfgPond)
        for i in 0..<8 { ingest(row(atY: 0.5), storePond, zonePond, at: Double(i) * 0.2) }
        let pondTracks = storePond.tracks
        XCTAssertEqual(pondTracks.count, 13)
        XCTAssertTrue(pondTracks.allSatisfy { $0.zone == .pond },
                      "the same row centered on the table resolves pond: \(zoneSummary(pondTracks))")
    }

    // MARK: - 1b. A meld separated from the hand row is myMeld, not myHand

    func testSeparatedPungAtMyEdgeIsMyMeldNotMyHand() {
        let config = tableConfig()
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        let faces = dealHand()   // 13-tile row, none bonus
        let row = faces.enumerated().map { i, f in det(f, box(0.5 + Double(i - 6) * 0.04, 0.90)) }
        // A separated pung well clear of the row (x ≈ 0.85 vs the row's
        // x ≤ 0.74) but still hugging my edge — same union-find neighbor
        // rule as the row, just a physically distinct cluster.
        let pung = [det(.whiteDragon, box(0.85, 0.84)),
                    det(.whiteDragon, box(0.85, 0.90)),
                    det(.whiteDragon, box(0.85, 0.96))]

        for i in 0..<8 { ingest(row + pung, store, zone, at: Double(i) * 0.2) }

        let rowTracks = store.tracks.filter { faces.contains($0.face) }
        XCTAssertEqual(rowTracks.count, 13)
        XCTAssertTrue(rowTracks.allSatisfy { $0.zone == .myHand },
                      "the 13-tile row stays myHand: \(zoneSummary(store.tracks))")

        let pungTracks = store.tracks.filter { $0.face == .whiteDragon }
        XCTAssertEqual(pungTracks.count, 3)
        XCTAssertTrue(pungTracks.allSatisfy { $0.zone == .myMeld },
                      "a separated pung at my edge is my exposed meld, not my hand: \(zoneSummary(store.tracks))")
    }

    // MARK: - 2. Pond disk vs scattered edge singles

    func testCentralTilesArePondScatteredLeftEdgeSinglesAreNot() {
        let config = tableConfig()
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        // Three tiles clustered near the anchor → all inside the pond disk.
        let pond = [det(.m(9), box(0.50, 0.50)),
                    det(.p(1), box(0.55, 0.52)),
                    det(.s(3), box(0.47, 0.55))]
        // Two singles hugging the left edge, far apart so they never cluster
        // (and far outside the pond disk) — must NOT read as pond.
        let leftSingles = [det(.east, box(0.05, 0.20)),
                           det(.west, box(0.05, 0.80))]

        for i in 0..<7 { ingest(pond + leftSingles, store, zone, at: Double(i) * 0.2) }

        for face in [Tile.m(9), .p(1), .s(3)] {
            XCTAssertEqual(store.tracks.first { $0.face == face }?.zone, .pond,
                           "\(face) is within pondRadius → pond")
        }
        for face in [Tile.east, .west] {
            let z = store.tracks.first { $0.face == face }?.zone
            XCTAssertNotEqual(z, .pond, "a scattered left-edge single is never pond (got \(String(describing: z)))")
            XCTAssertEqual(z, .unresolved, "an isolated non-meld edge tile falls through to unresolved")
        }
    }

    // MARK: - 3. Edge-hugging melds carry the edge's seat

    func testPungClusterSeatComesFromTheEdgeItHugs() {
        // Left edge (low x): a vertical stack of 3 identical faces → pung.
        let cfgLeft = tableConfig()
        let storeLeft = TrackStore(config: cfgLeft), zoneLeft = ZoneModel(config: cfgLeft)
        let leftPung = [det(.whiteDragon, box(0.08, 0.44)),
                        det(.whiteDragon, box(0.08, 0.50)),
                        det(.whiteDragon, box(0.08, 0.56))]
        for i in 0..<6 { ingest(leftPung, storeLeft, zoneLeft, at: Double(i) * 0.2) }
        let leftMeld = storeLeft.tracks.filter { $0.zone == .opponentMeld }
        XCTAssertEqual(leftMeld.count, 3, "a pung at the left edge is an opponent meld: \(zoneSummary(storeLeft.tracks))")
        XCTAssertTrue(leftMeld.allSatisfy { $0.seat == .left }, "left edge → seat .left")

        // Far edge (low y): the same pung, horizontal, hugging y = 0 → .across.
        let cfgFar = tableConfig()
        let storeFar = TrackStore(config: cfgFar), zoneFar = ZoneModel(config: cfgFar)
        let farPung = [det(.whiteDragon, box(0.44, 0.08)),
                       det(.whiteDragon, box(0.50, 0.08)),
                       det(.whiteDragon, box(0.56, 0.08))]
        for i in 0..<6 { ingest(farPung, storeFar, zoneFar, at: Double(i) * 0.2) }
        let farMeld = storeFar.tracks.filter { $0.zone == .opponentMeld }
        XCTAssertEqual(farMeld.count, 3, "a pung at the far edge is an opponent meld: \(zoneSummary(storeFar.tracks))")
        XCTAssertTrue(farMeld.allSatisfy { $0.seat == .across }, "far/low-y edge → seat .across")
    }

    // MARK: - 4. Hysteresis survives pond-vote flickers (mirrors ZoneModelTests)

    func testEstablishedMyHandSurvivesPondVoteFlickers() {
        // handBandDepth 0.30 and pondRadius 0.40 deliberately OVERLAP near
        // x = 0.5: a tile at (0.5, 0.75) is inside my edge band (y > 0.70) as
        // part of a ≥3 row, yet inside the pond disk (distance 0.25 < 0.40)
        // once it's a lone tile. That overlap is the only way a genuine POND
        // vote can ever land on a hand-band track — with the default disjoint
        // geometry a hand tile physically can't be in the pond — so it's what
        // lets this test flicker the exact zone the plan names.
        let config = tableConfig(handBandDepth: 0.30, pondRadius: 0.40)
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        let target = box(0.50, 0.75)
        let row = [det(.m(1), box(0.45, 0.75)), det(.m(2), target), det(.m(3), box(0.55, 0.75))]

        // Establish the target track as myHand over several settled frames.
        for i in 0..<7 { ingest(row, store, zone, at: Double(i) * 0.2) }
        XCTAssertEqual(store.tracks.first { $0.face == .m(2) }?.zone, .myHand,
                       "target settles as myHand first")

        // Two flicker frames: only the target present → a lone tile in the pond
        // disk → pond votes. The switch margin must hold the established zone.
        ingest([det(.m(2), target)], store, zone, at: 1.6)
        ingest([det(.m(2), target)], store, zone, at: 1.8)
        XCTAssertEqual(store.tracks.first { $0.face == .m(2) }?.zone, .myHand,
                       "1–2 pond-vote flickers never overcome an established myHand")
    }

    // MARK: - 5. Bonus faces in the hand band split to myBonus

    func testBonusFaceInHandBandIsMyBonus() {
        let config = tableConfig()
        let store = TrackStore(config: config), zone = ZoneModel(config: config)

        // A 4-tile hand row at my edge; one tile is a flower (bonus face).
        let row = [det(.m(1), box(0.44, 0.90)),
                   det(.flower(.plum), box(0.48, 0.90)),
                   det(.m(2), box(0.52, 0.90)),
                   det(.m(3), box(0.56, 0.90))]
        for i in 0..<7 { ingest(row, store, zone, at: Double(i) * 0.2) }

        XCTAssertEqual(store.tracks.first { $0.face == .flower(.plum) }?.zone, .myBonus,
                       "a bonus face in the hand band splits to myBonus: \(zoneSummary(store.tracks))")
        XCTAssertTrue(store.tracks.filter { $0.face != .flower(.plum) }.allSatisfy { $0.zone == .myHand },
                      "the non-bonus tiles in the same row stay myHand: \(zoneSummary(store.tracks))")
    }

    // MARK: - 6. Image-space default path is wholly untouched

    func testImageSpaceDefaultRoutesThroughParserUnchanged() {
        // Default `TrackerConfig()`: coordinateSpace == .imageSpace, no
        // tableGeometry. The image-space path must be intact — reproduce the
        // canonical right-edge opponent-pung case (image-scale boxes), the same
        // scenario `ZoneModelTests` asserts, so a regression in the shared
        // `zoneVotes` branch would surface here too.
        let store = TrackStore(), zone = ZoneModel()
        let boxes = [box(0.94, 0.44, w: 0.047, h: 0.075),
                     box(0.94, 0.50, w: 0.047, h: 0.075),
                     box(0.94, 0.56, w: 0.047, h: 0.075)]
        for i in 0..<6 { ingest(boxes.map { det(.whiteDragon, $0) }, store, zone, at: Double(i) * 0.2) }

        let meld = store.tracks.filter { $0.zone == .opponentMeld }
        XCTAssertEqual(meld.count, 3, "image-space default still splits the right-edge cluster out of pond")
        XCTAssertTrue(meld.allSatisfy { $0.seat == .right }, "image-space displacement owner = .right")
    }

    // MARK: - 7. Whole-table auto-partition (the AR default) — no gaps

    /// A `.tableSpace` config with the gapless whole-table auto-partition.
    private func partitionConfig() -> TrackerConfig {
        var config = TrackerConfig()
        config.coordinateSpace = .tableSpace
        config.tableGeometry = TableCalibrationGeometry.autoPartition(extentMetres: 0.9, mySeatWind: .east)
        return config
    }

    func testPartitionAssignsEveryTileToPondOrNearestEdge() {
        let cfg = partitionConfig()
        let store = TrackStore(config: cfg), zone = ZoneModel(config: cfg)
        // One well-separated tile per region — plus a "moat" tile between the
        // pond and the left edge that the legacy thin bands would have dropped
        // to `.unresolved` (the exact bug this layout fixes).
        let dets = [det(.m(1), box(0.50, 0.50)),   // centre        → pond
                    det(.m(2), box(0.50, 0.95)),   // my (high-y) edge → myHand
                    det(.m(3), box(0.50, 0.05)),   // far (low-y) edge → across
                    det(.m(4), box(0.05, 0.50)),   // left edge       → left
                    det(.m(5), box(0.95, 0.50)),   // right edge      → right
                    det(.m(6), box(0.15, 0.50))]   // moat (x<0.28)   → nearest = left
        for i in 0..<8 { ingest(dets, store, zone, at: Double(i) * 0.2) }

        let byFace = Dictionary(store.tracks.map { ($0.face, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byFace[.m(1)]?.zone, .pond)
        XCTAssertEqual(byFace[.m(2)]?.zone, .myHand)
        XCTAssertEqual(byFace[.m(3)]?.zone, .opponentMeld); XCTAssertEqual(byFace[.m(3)]?.seat, .across)
        XCTAssertEqual(byFace[.m(4)]?.zone, .opponentMeld); XCTAssertEqual(byFace[.m(4)]?.seat, .left)
        XCTAssertEqual(byFace[.m(5)]?.zone, .opponentMeld); XCTAssertEqual(byFace[.m(5)]?.seat, .right)
        // The moat tile is claimed (nearest = left), NOT left unresolved.
        XCTAssertEqual(byFace[.m(6)]?.zone, .opponentMeld); XCTAssertEqual(byFace[.m(6)]?.seat, .left)
        XCTAssertFalse(store.tracks.contains { $0.zone == .unresolved },
                       "partition tiles the whole table — nothing is unresolved: \(zoneSummary(store.tracks))")
    }
}
