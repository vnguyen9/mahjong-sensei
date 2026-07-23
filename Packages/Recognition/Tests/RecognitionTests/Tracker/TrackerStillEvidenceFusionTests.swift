import XCTest
@testable import Recognition
import MahjongCore

final class TrackerDirectEvidenceFusionTests: XCTestCase {
    func testUnroundedAutoConfirmBoundary() {
        let threshold = TrackerDirectEvidencePolicy.autoConfirmThreshold
        let evidence = make([threshold - 0.000_001, threshold])

        XCTAssertEqual(evidence.tiles[0].status, .needsReview)
        XCTAssertEqual(evidence.tiles[0].decisionReason, .belowAutoConfirmThreshold)
        XCTAssertEqual(evidence.tiles[1].status, .confirmed)
        XCTAssertEqual(evidence.tiles[1].decisionReason, .autoConfirmed)
    }

    func testDisplayAndSuggestionBoundariesRemainDistinct() {
        let evidence = make([0.2999, 0.3000])

        XCTAssertEqual(evidence.discardedTiles.count, 1)
        XCTAssertEqual(evidence.tiles.count, 1)
        XCTAssertNotNil(evidence.tiles[0].faceSuggestion)
    }

    func testDirectDetectionGeometryIsCanonicalEvidence() {
        let box = TileBoundingBox(x: 0.42, y: 0.2, width: 0.1, height: 0.2)
        let evidence = TrackerDirectEvidenceFusion.makeEvidence(
            canonicalFrameID: FrameID(3),
            detections: [.init(label: "1z", confidence: 0.9, box: box)]
        )

        XCTAssertEqual(evidence.tiles.count, 1)
        XCTAssertEqual(evidence.tiles[0].box, box)
        XCTAssertEqual(evidence.tiles[0].faceSuggestion, .tile(.east))
    }

    func testConservationDowngradesWeakestAutoConfirmedCopy() throws {
        let detections = (0..<5).map {
            TrackerDirectDetection(label: "1m", confidence: 0.80 + Double($0) / 100,
                                   box: box(x: Double($0) * 0.12))
        }
        let evidence = TrackerDirectEvidenceFusion.makeEvidence(
            canonicalFrameID: FrameID(4), detections: detections
        )

        XCTAssertEqual(evidence.tiles.filter { $0.status == .confirmed }.count, 4)
        XCTAssertEqual(evidence.tiles.filter {
            $0.decisionReason == .conservationViolation
        }.count, 1)
        XCTAssertEqual(try XCTUnwrap(evidence.tiles.first).detectionConfidence,
                       0.80, accuracy: 0.000_001)
    }

    private func make(_ confidences: [Double]) -> TrackerScanEvidence {
        TrackerDirectEvidenceFusion.makeEvidence(
            canonicalFrameID: FrameID(1),
            detections: confidences.enumerated().map {
                TrackerDirectDetection(label: "\($0.offset + 1)m",
                                       confidence: $0.element,
                                       box: box(x: Double($0.offset) * 0.15))
            }
        )
    }

    private func box(x: Double) -> TileBoundingBox {
        TileBoundingBox(x: x, y: 0.2, width: 0.1, height: 0.2)
    }
}
