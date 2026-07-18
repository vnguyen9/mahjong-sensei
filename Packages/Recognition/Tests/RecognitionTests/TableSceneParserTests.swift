import XCTest
import Foundation
@testable import Recognition
import MahjongCore

/// Stage A — the geometric auto-zoner. Synthetic layouts cover each rule;
/// the JSON fixtures are real photos run through `Tools/detect-dump`
/// (the production detector), hand-labeled from the images.
final class TableSceneParserTests: XCTestCase {

    // MARK: - Builders (normalized coords; rank ~0.08 tall, pond ~0.04)

    private func detCenter(_ face: Tile, cx: Double, cy: Double,
                           w: Double, h: Double, conf: Double = 0.9) -> DetectedTile {
        DetectedTile(tile: face, confidence: conf,
                     box: TileBoundingBox(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }

    /// Non-bonus faces for geometry tests (bamboo 1–9 cycling).
    private func faces(_ n: Int) -> [Tile] { (0..<n).map { .s(($0 % 9) + 1) } }

    /// My rank: a tight horizontal run near the bottom of the frame.
    private func rank(_ faces: [Tile], startX: Double = 0.125, pitch: Double = 0.052,
                      y: Double = 0.84, w: Double = 0.05, h: Double = 0.08) -> [DetectedTile] {
        faces.enumerated().map { i, f in
            detCenter(f, cx: startX + Double(i) * pitch, cy: y, w: w, h: h)
        }
    }

    /// A discard pond: small mid-frame tiles in neat rows.
    private func pond(_ count: Int, perRow: Int = 6) -> [DetectedTile] {
        (0..<count).map { i in
            detCenter(.m((i % 9) + 1),
                      cx: 0.36 + Double(i % perRow) * 0.028,
                      cy: 0.42 + Double(i / perRow) * 0.05,
                      w: 0.026, h: 0.04)
        }
    }

    // MARK: - Synthetic scenes

    func testConcealedHandPlusPond() {
        let scene = TableSceneParser.parse(rank(faces(14)) + pond(12))
        XCTAssertEqual(scene.mine.count, 14)
        XCTAssertTrue(scene.myMelds.isEmpty)
        XCTAssertEqual(scene.table.count, 12)
        XCTAssertTrue(scene.unresolved.isEmpty)
        XCTAssertEqual(scene.confidence, 1.0)
    }

    func testMeldSplitFromRankRow() {
        // 11 concealed + a pung laid just right of the rank — same cluster,
        // separated by the along-axis run gap.
        let meld = (0..<3).map { detCenter(.east, cx: 0.78 + Double($0) * 0.049, cy: 0.84, w: 0.047, h: 0.075) }
        let scene = TableSceneParser.parse(rank(faces(11)) + meld + pond(10))
        XCTAssertEqual(scene.mine.count, 11)
        XCTAssertEqual(scene.myMelds.count, 1)
        XCTAssertEqual(scene.myMelds.first?.count, 3)
        XCTAssertEqual(scene.table.count, 10)
        XCTAssertEqual(scene.confidence, 1.0)   // 11 = 14 − 3×1 ✓
    }

    func testMeldAsSeparateCluster() {
        // Same pung but pushed far enough right to be its own cluster —
        // caught by the my-edge scale + depth gates instead.
        let meld = (0..<3).map { detCenter(.east, cx: 0.86 + Double($0) * 0.045, cy: 0.84, w: 0.043, h: 0.075) }
        let scene = TableSceneParser.parse(rank(faces(11)) + meld + pond(10))
        XCTAssertEqual(scene.mine.count, 11)
        XCTAssertEqual(scene.myMelds.count, 1)
        XCTAssertEqual(scene.table.count, 10)
    }

    func testDrawnTileJoinsRank() {
        // 13 + the just-drawn tile set slightly apart: still mine.
        let drawn = [detCenter(.p(5), cx: 0.879, cy: 0.84, w: 0.05, h: 0.08)]
        let scene = TableSceneParser.parse(rank(faces(13)) + drawn + pond(8))
        XCTAssertEqual(scene.mine.count, 14)
        XCTAssertTrue(scene.myMelds.isEmpty)
        XCTAssertTrue(scene.unresolved.isEmpty)
    }

    func testBonusRowJoinsMine() {
        // Flowers displayed above the rank belong to me (session splits them out).
        let flowers = [detCenter(.flower(.plum), cx: 0.125, cy: 0.72, w: 0.045, h: 0.07),
                       detCenter(.season(.spring), cx: 0.177, cy: 0.72, w: 0.045, h: 0.07)]
        let scene = TableSceneParser.parse(rank(faces(14)) + flowers + pond(9))
        XCTAssertEqual(scene.mine.count, 16)
        XCTAssertEqual(scene.mine.filter { $0.tile.isBonus }.count, 2)
        XCTAssertEqual(scene.confidence, 1.0)   // concealed still 14
    }

    func testOpponentMeldsAndPondGoToTable() {
        // Opponents' melds are far/small — counts only, never structure.
        let topMeld = (0..<3).map { detCenter(.west, cx: 0.50 + Double($0) * 0.025, cy: 0.12, w: 0.023, h: 0.035) }
        let sideMeld = (0..<3).map { detCenter(.p(7), cx: 0.06, cy: 0.50 + Double($0) * 0.05, w: 0.05, h: 0.045) }
        let scene = TableSceneParser.parse(rank(faces(14)) + pond(9) + topMeld + sideMeld)
        XCTAssertEqual(scene.mine.count, 14)
        XCTAssertTrue(scene.myMelds.isEmpty)
        XCTAssertEqual(scene.table.count, 15)
    }

    func testMessyPondStillTable() {
        let jitter: [(Double, Double)] = [(0.40, 0.44), (0.45, 0.42), (0.43, 0.47), (0.48, 0.46),
                                          (0.52, 0.43), (0.55, 0.47), (0.50, 0.50), (0.57, 0.44)]
        let scattered = jitter.enumerated().map { i, c in
            detCenter(.m((i % 9) + 1), cx: c.0, cy: c.1, w: 0.026, h: i.isMultiple(of: 2) ? 0.038 : 0.042)
        }
        let scene = TableSceneParser.parse(rank(faces(13)) + scattered)
        XCTAssertEqual(scene.mine.count, 13)
        XCTAssertEqual(scene.table.count, 8)
    }

    func testTiltedRankParsesAsOneRun() {
        // Handheld roll: the rank is a diagonal in image space (~13°). Naive
        // y-banding fragments it; the principal-axis path must not.
        let tilted = faces(13).enumerated().map { i, f in
            detCenter(f, cx: 0.125 + Double(i) * 0.052, cy: 0.84 - Double(i) * 0.012, w: 0.05, h: 0.08)
        }
        let scene = TableSceneParser.parse(tilted + pond(10))
        XCTAssertEqual(scene.mine.count, 13)
        XCTAssertEqual(scene.table.count, 10)
        XCTAssertTrue(scene.unresolved.isEmpty)
    }

    func testPondCloseupHasNoHand() {
        // Nothing at rank scale in frame → counts only, low confidence.
        let scene = TableSceneParser.parse(pond(15))
        XCTAssertTrue(scene.mine.isEmpty)
        XCTAssertEqual(scene.table.count, 15)
        XCTAssertEqual(scene.confidence, 0.2, accuracy: 0.001)
    }

    func testEmptyInput() {
        let scene = TableSceneParser.parse([])
        XCTAssertTrue(scene.mine.isEmpty && scene.table.isEmpty)
        XCTAssertEqual(scene.confidence, 0)
    }

    func testSingleTileIsTable() {
        let scene = TableSceneParser.parse([detCenter(.redDragon, cx: 0.5, cy: 0.5, w: 0.1, h: 0.16)])
        XCTAssertTrue(scene.mine.isEmpty)
        XCTAssertEqual(scene.table.count, 1)
    }

    // MARK: - Real-photo fixtures (Tools/detect-dump output)

    private struct FixtureDump: Decodable {
        var image: String
        var imageWidth: Int
        var imageHeight: Int
        var threshold: Double
        var tiles: [DetectedTile]
    }

    private func fixture(_ name: String) throws -> [DetectedTile] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures"), "missing fixture \(name)")
        return try JSONDecoder().decode(FixtureDump.self, from: Data(contentsOf: url)).tiles
    }

    /// Player's-seat photo, early game: the 13-tile rank is the only thing the
    /// detector fires on (the rotated pond tile never detects — see fixtures README).
    func testAotomoFixtureIsAllMine() throws {
        let scene = TableSceneParser.parse(try fixture("aotomo-mahjong-table.boxes"))
        XCTAssertEqual(scene.mine.map(\.tile.code).sorted(),
                       ["2m", "2m", "2p", "2p", "4m", "4m", "4p", "4s", "5p", "7m", "7p", "7s", "W"])
        XCTAssertTrue(scene.myMelds.isEmpty)
        XCTAssertTrue(scene.table.isEmpty)
        XCTAssertTrue(scene.unresolved.isEmpty)
        XCTAssertGreaterThanOrEqual(scene.confidence, 0.95)
    }

    /// Corner shot of a real game (thumbnail, noisy faces — geometry only):
    /// a 10-tile diagonal rank + an East pung beside it, a 15-tile pond,
    /// and one lone mid-table season left honestly unresolved.
    func testImages5FixtureSplitsRankPondAndMeld() throws {
        let scene = TableSceneParser.parse(try fixture("images-5.boxes"))
        XCTAssertEqual(scene.mine.count, 10)
        XCTAssertEqual(scene.myMelds.count, 1)
        XCTAssertEqual(scene.myMelds.first?.map(\.tile.code), ["E", "E", "E"])
        XCTAssertEqual(scene.table.count, 15)
        XCTAssertEqual(scene.unresolved.map(\.tile.code), ["S3"])
        XCTAssertEqual(scene.confidence, 0.75, accuracy: 0.001)
        // The coaching invariant: nothing near my edge leaks into the count
        // bucket, and no pond tile is ever treated as structure.
        let pondHeights = scene.table.map(\.box.height)
        let mineHeights = scene.mine.map(\.box.height)
        XCTAssertLessThan(pondHeights.max() ?? 0, mineHeights.min() ?? 1)
    }
}
