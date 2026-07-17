import XCTest
@testable import Recognition
import MahjongCore

final class RecognitionTests: XCTestCase {
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

    func testMockRecognizerReturnsResult() async {
        let r = await MockRecognizer(result: MockHands.coach).recognize()
        XCTAssertEqual(r.tiles.count, 14)
    }
}
