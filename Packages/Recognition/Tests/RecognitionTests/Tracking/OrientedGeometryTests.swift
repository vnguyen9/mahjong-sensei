import XCTest
import simd
@testable import Recognition
import MahjongCore

/// Workstream A coverage: the oriented `TableGeometry` model — `OrientedBand`
/// membership at angles, the two-post producer (tilt + seats/winds), `Codable`
/// round-trip, and an end-to-end `ZoneModel` case where a tilted hand row is
/// classified `myHand` while the old axis-aligned band would reject it. The
/// axis-aligned regression cases live in `TableSpaceZoneTests` /
/// `TableCalibrationGeometryTests` (all still green via the legacy init).
final class OrientedGeometryTests: XCTestCase {
    typealias Band = TrackerConfig.OrientedBand

    // MARK: - OrientedBand math

    func testAxisAlignedBandReproducesLegacyMyEdgeDistances() {
        let b = Band(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: 0.2)   // my edge, inward
        XCTAssertTrue(b.contains(SIMD2(0.5, 0.95)))                 // 0.05 inward
        XCTAssertTrue(b.contains(SIMD2(0.5, 0.81)))                 // 0.19 < 0.2
        XCTAssertFalse(b.contains(SIMD2(0.5, 0.75)))               // 0.25 > 0.2
        // penetration == the old nearestEdge distance (1 - cy) for my edge.
        XCTAssertEqual(b.penetration(SIMD2(0.5, 0.85)), 0.15, accuracy: 1e-9)
    }

    func testTiltedBandAcceptsWhatAxisAlignedRejects() {
        // Near edge from (0,1.0) to (1,0.6): steeply tilted, depth 0.25.
        let tilted = Band(a: SIMD2(0, 1.0), b: SIMD2(1, 0.6), depth: 0.25)
        let p = SIMD2(0.9, 0.60)   // follows the row angle (near-edge z(0.9)=0.64)
        XCTAssertTrue(tilted.contains(p), "tilted band contains a point that follows the row angle")
        let axis = Band(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: 0.25)   // covers nz∈[0.75,1]
        XCTAssertFalse(axis.contains(p), "an axis-aligned band of the same depth rejects it (0.4 inward)")
    }

    func testBandCornersAndCenterAreConsistent() {
        let b = Band(a: SIMD2(0, 1), b: SIMD2(1, 1), depth: 0.2)
        XCTAssertEqual(b.corners.count, 4)
        // Center sits half a depth inward of the a→b midpoint (0.5, 1).
        XCTAssertEqual(b.center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b.center.y, 0.9, accuracy: 1e-9)
    }

    // MARK: - Producer

    func testProducerTiltsBandFromUnevenPosts() {
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 0.9,
            handPostA: SIMD2(-0.3, 0.30),   // left end,  local z 0.30
            handPostB: SIMD2(0.3, 0.18),    // right end, deeper z 0.18
            pondCornerA: nil, pondCornerB: nil)
        XCTAssertGreaterThan(abs(g.handBand.a.y - g.handBand.b.y), 0.01,
                             "uneven posts produce a tilted near edge")
        XCTAssertGreaterThan(g.handBand.depth, 0)
    }

    func testProducerAssignsSeatsAndWinds() throws {
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 0.9, handPostA: nil, handPostB: nil,
            pondCornerA: nil, pondCornerB: nil, mySeatWind: .south)
        let bySeat = Dictionary(uniqueKeysWithValues: g.seats.map { ($0.seat, $0) })
        XCTAssertEqual(bySeat[.me]?.wind, .south)
        XCTAssertEqual(bySeat[.right]?.wind, .west)    // south + 1
        XCTAssertEqual(bySeat[.across]?.wind, .north)  // south + 2
        XCTAssertEqual(bySeat[.left]?.wind, .east)     // south + 3
        let me = try XCTUnwrap(bySeat[.me])
        XCTAssertEqual(me.edgeMidpoint.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(me.edgeMidpoint.y, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g.meldBands.count, 3, "three opponent meld bands")
    }

    func testTableGeometryCodableRoundTrip() {
        let g = TableCalibrationGeometry.geometry(
            extentMetres: 1.0,
            handPostA: SIMD2(-0.2, 0.20), handPostB: SIMD2(0.2, 0.15),
            pondCornerA: SIMD2(-0.15, -0.15), pondCornerB: SIMD2(0.15, 0.15),
            mySeatWind: .west)
        let data = try! JSONEncoder().encode(g)
        let d = try! JSONDecoder().decode(TrackerConfig.TableGeometry.self, from: data)
        XCTAssertEqual(d.version, TrackerConfig.TableGeometry.currentVersion)
        XCTAssertEqual(d.extent, g.extent, accuracy: 1e-9)
        XCTAssertEqual(d.handBand.depth, g.handBand.depth, accuracy: 1e-9)
        XCTAssertEqual(d.pondRadius, g.pondRadius, accuracy: 1e-9)
        XCTAssertEqual(d.seats.count, 4)
        XCTAssertEqual(d.meldBands.count, 3)
    }

    // MARK: - End-to-end ZoneModel with a tilted band

    private func box(_ cx: Double, _ cy: Double) -> TileBoundingBox {
        TileBoundingBox(x: cx - 0.0135, y: cy - 0.018, width: 0.027, height: 0.036)
    }
    private func det(_ t: Tile, _ b: TileBoundingBox) -> DetectedTile {
        DetectedTile(tile: t, confidence: 0.9, box: b)
    }
    private func ingest(_ dets: [DetectedTile], _ store: TrackStore, _ zone: ZoneModel, at t: TimeInterval) {
        let o = store.associate(dets, at: t)
        zone.ingestSettled(detections: dets, outcome: o, store: store, at: t)
    }

    func testTiltedHandRowIsMyHandWhereAxisAlignedWouldNot() {
        // Tilted geometry: near edge (0,1.0)→(1,0.6), depth 0.25.
        var g = TrackerConfig.TableGeometry(handBandDepth: 0.25)
        g.handBand = Band(a: SIMD2(0, 1.0), b: SIMD2(1, 0.6), depth: 0.25)
        var cfg = TrackerConfig(); cfg.coordinateSpace = .tableSpace; cfg.tableGeometry = g
        let store = TrackStore(config: cfg), zone = ZoneModel(config: cfg)

        // 5 tiles following the tilt, ~0.05 inward of the near edge.
        let faces: [Tile] = [.m(1), .m(2), .m(3), .m(4), .m(5)]
        let xs = [0.40, 0.45, 0.50, 0.55, 0.60]
        let row = zip(faces, xs).map { f, x in det(f, box(x, (1 - 0.4 * x) - 0.05)) }
        for i in 0..<8 { ingest(row, store, zone, at: Double(i) * 0.2) }
        XCTAssertEqual(store.tracks.count, 5)
        XCTAssertTrue(store.tracks.allSatisfy { $0.zone == .myHand },
                      "a row following the tilted band resolves myHand")

        // The identical tiles under the default axis-aligned band are NOT all
        // myHand (the far end sits below the straight band's inner edge).
        var cfg2 = TrackerConfig(); cfg2.coordinateSpace = .tableSpace
        cfg2.tableGeometry = TrackerConfig.TableGeometry()   // axis-aligned depth 0.18
        let s2 = TrackStore(config: cfg2), z2 = ZoneModel(config: cfg2)
        for i in 0..<8 { ingest(row, s2, z2, at: Double(i) * 0.2) }
        XCTAssertFalse(s2.tracks.allSatisfy { $0.zone == .myHand },
                       "the same tilted row is rejected by an axis-aligned band")
    }
}
