import XCTest
import Foundation
import CoreGraphics
import CoreML
@testable import Recognition
import MahjongCore

final class RecognitionTests: XCTestCase {

    // MARK: - Helpers

    /// A detection at a given normalized box (x/y are the box origin, top-left).
    private func det(_ face: Tile, x: Double, y: Double,
                     w: Double = 0.05, h: Double = 0.15, conf: Double = 0.9) -> DetectedTile {
        DetectedTile(tile: face, confidence: conf, box: TileBoundingBox(x: x, y: y, width: w, height: h))
    }

    /// A detection specified by its CENTER (easier for clustering tests).
    private func detCenter(_ face: Tile, cx: Double, cy: Double,
                           w: Double = 0.05, h: Double = 0.15, conf: Double = 0.9) -> DetectedTile {
        det(face, x: cx - w / 2, y: cy - h / 2, w: w, h: h, conf: conf)
    }

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - Existing shape / mock

    func testRowLaysOutInOrder() {
        let r = RecognitionResult.row([.m(1), .m(2), .m(3)])
        XCTAssertEqual(r.faces, [.m(1), .m(2), .m(3)])
        XCTAssertTrue(zip(r.tiles, r.tiles.dropFirst()).allSatisfy { $0.box.x < $1.box.x })
    }

    func testLowConfidenceFlagging() {
        let r = RecognitionResult.row([.m(1), .m(2)], lowConfidenceIndices: [1])
        XCTAssertEqual(r.lowConfidenceCount, 1)
        XCTAssertTrue(r.tiles[1].isLowConfidence)
    }

    func testMockWinningHandShape() {
        XCTAssertEqual(MockHands.winning.tiles.count, 14)
        XCTAssertEqual(MockHands.winning.lowConfidenceCount, 1)
    }

    func testMockRecognizerReturnsResult() async throws {
        let r = try await MockRecognizer(result: MockHands.coach).recognize(.image(Self.blankImage()))
        XCTAssertEqual(r.tiles.count, 14)
    }

    // MARK: - HKDetectorLabels (model label → Tile)

    func testDetectorLabelCount() {
        XCTAssertEqual(HKDetectorLabels.ordered.count, 43)
    }

    func testDetectorLabelsCoverExactlyTheCanonicalFaces() {
        let mapped = HKDetectorLabels.ordered.compactMap(HKDetectorLabels.tile(for:))
        XCTAssertEqual(mapped.count, 42)
        XCTAssertEqual(Set(mapped), Set(Tile.allCanonical))
    }

    func testBackMapsToNil() {
        XCTAssertNil(HKDetectorLabels.tile(for: "back"))
        XCTAssertNil(HKDetectorLabels.tile(for: "not-a-tile"))
    }

    func testDragonsMapByModelOrderNotIndex() {
        XCTAssertEqual(HKDetectorLabels.tile(for: "5z"), .whiteDragon)
        XCTAssertEqual(HKDetectorLabels.tile(for: "6z"), .greenDragon)
        XCTAssertEqual(HKDetectorLabels.tile(for: "7z"), .redDragon)
    }

    func testWindsMap() {
        XCTAssertEqual(HKDetectorLabels.tile(for: "1z"), .east)
        XCTAssertEqual(HKDetectorLabels.tile(for: "2z"), .south)
        XCTAssertEqual(HKDetectorLabels.tile(for: "3z"), .west)
        XCTAssertEqual(HKDetectorLabels.tile(for: "4z"), .north)
    }

    func testSuitAndBonusDisambiguation() {
        XCTAssertEqual(HKDetectorLabels.tile(for: "1s"), .s(1))
        XCTAssertEqual(HKDetectorLabels.tile(for: "9s"), .s(9))
        XCTAssertEqual(HKDetectorLabels.tile(for: "1S"), .season(.spring))
        XCTAssertEqual(HKDetectorLabels.tile(for: "4S"), .season(.winter))
        XCTAssertEqual(HKDetectorLabels.tile(for: "1F"), .flower(.plum))
        XCTAssertEqual(HKDetectorLabels.tile(for: "4F"), .flower(.bamboo))
        XCTAssertEqual(HKDetectorLabels.tile(for: "9m"), .m(9))
        XCTAssertEqual(HKDetectorLabels.tile(for: "5p"), .p(5))
    }

    // MARK: - Row clustering

    /// The real-world bug: two physical rows must not interleave (old x-only sort did).
    func testTwoRowInterleaveRegression() {
        let input = [
            detCenter(.m(2), cx: 0.40, cy: 0.35), detCenter(.p(1), cx: 0.20, cy: 0.65),
            detCenter(.m(1), cx: 0.20, cy: 0.35), detCenter(.p(3), cx: 0.60, cy: 0.65),
            detCenter(.m(3), cx: 0.60, cy: 0.35), detCenter(.p(2), cx: 0.40, cy: 0.65),
        ]
        let result = RecognitionResult(tiles: input)
        XCTAssertEqual(result.faces, [.m(1), .m(2), .m(3), .p(1), .p(2), .p(3)])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].map(\.tile), [.m(1), .m(2), .m(3)])
        XCTAssertEqual(result.rows[1].map(\.tile), [.p(1), .p(2), .p(3)])
    }

    func testSingleRowMockStaysSingleRow() {
        let r = RecognitionResult.row([.m(1), .m(2), .m(3), .m(4)])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].map(\.tile), [.m(1), .m(2), .m(3), .m(4)])
    }

    func testTiltedRowChainsIntoOneCluster() {
        // 7 tiles drifting down-right by 0.01 each — a tilted single row, not two.
        let input = (0..<7).map { i in
            detCenter(.s(i + 1), cx: 0.12 + 0.12 * Double(i), cy: 0.40 + 0.01 * Double(i), h: 0.15)
        }
        let result = RecognitionResult(tiles: input.shuffledDeterministically())
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.tiles.count, 7)
        XCTAssertEqual(result.rows[0].map(\.tile), (1...7).map(Tile.s))
    }

    func testRowToleranceBoundary() {
        // height 0.2 → tolerance = max(0.1, 0.015) = 0.1. A gap under tolerance is one row…
        let same = RecognitionResult(tiles: [
            detCenter(.m(1), cx: 0.3, cy: 0.30, h: 0.2),
            detCenter(.m(2), cx: 0.3, cy: 0.38, h: 0.2),   // gap 0.08 < 0.1
        ])
        XCTAssertEqual(same.rows.count, 1)
        // …a gap over tolerance splits.
        let split = RecognitionResult(tiles: [
            detCenter(.m(1), cx: 0.3, cy: 0.30, h: 0.2),
            detCenter(.m(2), cx: 0.3, cy: 0.42, h: 0.2),   // gap 0.12 > 0.1
        ])
        XCTAssertEqual(split.rows.count, 2)
    }

    func testReadingOrderStabilityForDuplicatePositions() {
        // Two tiles at the same center keep input order (stable sort).
        let input = [detCenter(.m(5), cx: 0.5, cy: 0.5), detCenter(.p(5), cx: 0.5, cy: 0.5)]
        XCTAssertEqual(RecognitionResult(tiles: input).faces, [.m(5), .p(5)])
    }

    // MARK: - Letterbox inversion

    func testLetterboxInversionPortrait() {
        // 720×1280 portrait → scale 0.5, padX 140, padY 0.
        let g = LetterboxGeometry(orientedImageSize: CGSize(width: 720, height: 1280))
        let full = g.normalizedBox(x1: 140, y1: 0, x2: 500, y2: 640)
        XCTAssertEqual(full.x, 0, accuracy: 1e-6)
        XCTAssertEqual(full.y, 0, accuracy: 1e-6)
        XCTAssertEqual(full.width, 1, accuracy: 1e-6)
        XCTAssertEqual(full.height, 1, accuracy: 1e-6)
        // A centered box maps to a centered normalized box.
        let mid = g.normalizedBox(x1: 302, y1: 288, x2: 338, y2: 352)
        XCTAssertEqual(mid.centerX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(mid.centerY, 0.5, accuracy: 1e-6)
    }

    func testLetterboxInversionLandscape() {
        // 1280×720 landscape → scale 0.5, padX 0, padY 140.
        let g = LetterboxGeometry(orientedImageSize: CGSize(width: 1280, height: 720))
        let full = g.normalizedBox(x1: 0, y1: 140, x2: 640, y2: 500)
        XCTAssertEqual(full.x, 0, accuracy: 1e-6)
        XCTAssertEqual(full.y, 0, accuracy: 1e-6)
        XCTAssertEqual(full.width, 1, accuracy: 1e-6)
        XCTAssertEqual(full.height, 1, accuracy: 1e-6)
    }

    func testDecodeEnd2EndTensorWithIdentityGeometry() throws {
        let array = try MLMultiArray(shape: [1, 3, 6], dataType: .float32)
        func set(_ r: Int, _ v: [Float]) {
            for c in 0..<6 {
                array[[NSNumber(value: 0), NSNumber(value: r), NSNumber(value: c)]] = NSNumber(value: v[c])
            }
        }
        set(0, [64, 320, 128, 384, 0.90, 17])   // class 17 = "9p" → keep
        set(1, [0, 0, 32, 32, 0.95, 42])         // class 42 = "back" → skip
        set(2, [10, 10, 20, 20, 0.10, 3])        // below threshold → skip

        let identity = LetterboxGeometry(orientedImageSize: CGSize(width: 640, height: 640))
        let tiles = VisionRecognizer.decodeTiles(from: array, threshold: 0.30, geometry: identity)
        XCTAssertEqual(tiles.count, 1)
        let t = try XCTUnwrap(tiles.first)
        XCTAssertEqual(t.tile, .p(9))
        XCTAssertEqual(t.confidence, 0.90, accuracy: 1e-5)
        XCTAssertEqual(t.box.x, 64.0 / 640, accuracy: 1e-5)
        XCTAssertEqual(t.box.y, 320.0 / 640, accuracy: 1e-5)
        XCTAssertEqual(t.box.width, 64.0 / 640, accuracy: 1e-5)
        XCTAssertEqual(t.box.height, 64.0 / 640, accuracy: 1e-5)
    }

    // MARK: - IoU + overlap suppression

    func testIoUCases() {
        let a = TileBoundingBox(x: 0, y: 0, width: 0.2, height: 0.2)
        XCTAssertEqual(VisionRecognizer.iou(a, a), 1.0, accuracy: 1e-9)
        XCTAssertEqual(VisionRecognizer.iou(a, TileBoundingBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2)), 0, accuracy: 1e-9)
        // half-overlap → 1/3
        XCTAssertEqual(VisionRecognizer.iou(a, TileBoundingBox(x: 0.1, y: 0, width: 0.2, height: 0.2)),
                       1.0 / 3.0, accuracy: 1e-9)
        // containment (small fully inside large) → area ratio 0.25
        XCTAssertEqual(VisionRecognizer.iou(TileBoundingBox(x: 0, y: 0, width: 0.4, height: 0.4),
                                            TileBoundingBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
                       0.25, accuracy: 1e-9)
    }

    func testOverlapSuppressionClassAgnostic() {
        // Two labels on one tile — keep the higher-confidence one.
        let tiles = [
            det(.m(5), x: 0.10, y: 0.40, w: 0.06, h: 0.15, conf: 0.90),
            det(.p(5), x: 0.105, y: 0.40, w: 0.06, h: 0.15, conf: 0.70),
        ]
        let kept = VisionRecognizer.suppressingOverlaps(tiles)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.tile, .m(5))
    }

    func testSuppressionKeepsAdjacentNeighbors() {
        let tiles = [
            det(.m(1), x: 0.10, y: 0.40, w: 0.08, h: 0.15, conf: 0.9),
            det(.m(2), x: 0.17, y: 0.40, w: 0.08, h: 0.15, conf: 0.9),
        ]
        XCTAssertEqual(VisionRecognizer.suppressingOverlaps(tiles).count, 2)
    }

    // MARK: - inReticle Codable + flagging

    func testInReticleDecodesWithMissingKey() throws {
        let original = DetectedTile(tile: .m(5), confidence: 0.9,
                                    box: TileBoundingBox(x: 0, y: 0, width: 0.1, height: 0.1), inReticle: false)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        dict.removeValue(forKey: "inReticle")
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(DetectedTile.self, from: data)
        XCTAssertTrue(decoded.inReticle)   // missing key → defaults true
    }

    func testInReticleRoundtrip() throws {
        let original = DetectedTile(tile: .p(3), confidence: 0.8,
                                    box: TileBoundingBox(x: 0.1, y: 0.2, width: 0.1, height: 0.1), inReticle: false)
        let decoded = try JSONDecoder().decode(DetectedTile.self, from: JSONEncoder().encode(original))
        XCTAssertFalse(decoded.inReticle)
        XCTAssertEqual(decoded, original)
    }

    func testKeepingTilesInsideROIDropsOutsiders() {
        let roi = TileBoundingBox(x: 0.2, y: 0.2, width: 0.6, height: 0.6)  // +0.03 → [0.17, 0.83]
        let base = RecognitionResult(tiles: [
            detCenter(.m(1), cx: 0.50, cy: 0.50, w: 0.05, h: 0.05),   // inside → kept
            detCenter(.m(9), cx: 0.95, cy: 0.50, w: 0.05, h: 0.05),   // outside (x) → dropped
            detCenter(.p(5), cx: 0.82, cy: 0.50, w: 0.05, h: 0.05),   // inside the margin → kept
            detCenter(.s(7), cx: 0.50, cy: 0.86, w: 0.05, h: 0.05),   // below the margin → dropped
        ])
        let kept = base.keepingTiles(insideROI: roi)
        XCTAssertEqual(kept.faces.sorted { $0.classIndex < $1.classIndex }, [.m(1), .p(5)])
    }

    func testKeepingTilesWithNilROIKeepsEverything() {
        let base = RecognitionResult(tiles: [
            detCenter(.m(1), cx: 0.05, cy: 0.05, w: 0.05, h: 0.05),
            detCenter(.m(9), cx: 0.95, cy: 0.95, w: 0.05, h: 0.05),
        ])
        XCTAssertEqual(base.keepingTiles(insideROI: nil).tiles.count, 2)
    }

    // MARK: - Aspect-fill reticle mapping

    func testAspectFillMappingCentersReticle() {
        // iPhone 393×852 preview, 720×1280 image; a horizontally centered reticle.
        let preview = CGRect(x: 0, y: 0, width: 393, height: 852)
        let reticle = CGRect(x: (393 - 300) / 2, y: 426 - 75, width: 300, height: 150)
        let roi = AspectFillMapping.normalizedImageRect(of: reticle, previewBounds: preview,
                                                        orientedImageSize: CGSize(width: 720, height: 1280))
        XCTAssertEqual(roi.centerX, 0.5, accuracy: 0.005)
        XCTAssertEqual(roi.centerY, 0.5, accuracy: 0.005)
        XCTAssertEqual(roi.width, 300.0 / 479.25, accuracy: 0.01)
    }

    func testPreviewRectInvertsNormalizedMapping() {
        // A tile rect on-screen → normalize → back should land on the same rect.
        let preview = CGRect(x: 0, y: 0, width: 393, height: 852)
        let image = CGSize(width: 720, height: 1280)
        let tileRect = CGRect(x: 140, y: 500, width: 70, height: 96)
        let norm = AspectFillMapping.normalizedImageRect(of: tileRect, previewBounds: preview,
                                                         orientedImageSize: image)
        let back = AspectFillMapping.previewRect(ofNormalized: norm, previewBounds: preview,
                                                 orientedImageSize: image)
        XCTAssertEqual(back.minX, tileRect.minX, accuracy: 0.5)
        XCTAssertEqual(back.minY, tileRect.minY, accuracy: 0.5)
        XCTAssertEqual(back.width, tileRect.width, accuracy: 0.5)
        XCTAssertEqual(back.height, tileRect.height, accuracy: 0.5)
    }
}

private extension Array {
    /// Deterministic reorder (no `Math.random`): reverse then rotate by 3.
    func shuffledDeterministically() -> [Element] {
        guard count > 1 else { return self }
        let reversed = Array(self.reversed())
        return Array(reversed[3...] + reversed[..<3])
    }
}
