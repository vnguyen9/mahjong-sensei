import XCTest
@testable import Recognition

final class DeferredRegionWorkQueueTests: XCTestCase {
    private enum Region: Hashable, Sendable { case hand, pond, left, far, right }

    func testVerificationUsesRequestedOrderAndThreeReadLimit() {
        var queue = BoundedRegionVerificationQueue<Region>()
        queue.begin(order: [.hand, .pond, .left, .far, .right])
        XCTAssertEqual(queue.current, .hand)
        queue.recordSuccessfulRead(for: .pond, stabilized: false)
        XCTAssertEqual(queue.current, .hand, "later regions cannot skip the head")
        queue.recordSuccessfulRead(for: .hand, stabilized: false)
        queue.recordSuccessfulRead(for: .hand, stabilized: false)
        XCTAssertEqual(queue.current, .hand)
        queue.recordSuccessfulRead(for: .hand, stabilized: false)
        XCTAssertEqual(queue.current, .pond)
    }

    func testStableRegionEndsVerificationEarly() {
        var queue = BoundedRegionVerificationQueue<Region>()
        queue.begin(order: [.hand, .pond])
        queue.recordSuccessfulRead(for: .hand, stabilized: true)
        XCTAssertEqual(queue.current, .pond)
    }

    func testOffscreenWorkIsDeferredAndReturnsWhenAvailable() {
        var queue = DeferredRegionWorkQueue<Region>()
        queue.enqueue(.hand, isAvailable: false)
        queue.enqueue(.pond)
        XCTAssertEqual(queue.select(maximum: 2, priority: .hand), [.pond])
        queue.setAvailable(true, for: .hand)
        XCTAssertEqual(queue.select(maximum: 1, priority: .hand), [.hand])
    }

    func testRepeatedSelectionCannotStarveDeferredRegions() {
        var queue = DeferredRegionWorkQueue<Region>()
        [.hand, .pond, .left, .far, .right].forEach { queue.enqueue($0) }
        var selected: Set<Region> = []
        for _ in 0..<3 {
            selected.formUnion(queue.select(maximum: 2, preferred: .hand))
        }
        XCTAssertEqual(selected, Set([.hand, .pond, .left, .far, .right]))
    }
}
