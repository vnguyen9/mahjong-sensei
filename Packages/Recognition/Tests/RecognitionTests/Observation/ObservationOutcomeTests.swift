import XCTest
import CoreGraphics
@testable import Recognition
import MahjongCore

/// Chunk A observation-semantics tests (§8): a thrown/failed inference must
/// surface as `.failed`, never a `.success` with an empty (or partial)
/// observation list — that conflation is exactly what §8 forbids.
final class ObservationOutcomeTests: XCTestCase {

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private static func input() -> LocatorInput { LocatorInput(frame: .image(blankImage())) }

    private static func acceptedQuality() -> FrameQuality {
        FrameQuality(trackingIsNormal: true, sharpness: 1, exposureScore: 1,
                     clippingFraction: 0, projectedPixelsPerTile: 100,
                     coverageFraction: 1, accepted: true)
    }

    private struct ThrowingLocator: TileLocating {
        struct Boom: Error {}
        func locate(in region: LocatorInput) async throws -> [TileLocalization] { throw Boom() }
    }

    private struct EmptyLocator: TileLocating {
        func locate(in region: LocatorInput) async throws -> [TileLocalization] { [] }
    }

    private struct FixedLocator: TileLocating {
        var localizations: [TileLocalization]
        func locate(in region: LocatorInput) async throws -> [TileLocalization] { localizations }
    }

    func testThrowingLocatorSurfacesAsFailedNeverEmptySuccess() async {
        let collector = ObservationCollector(locator: ThrowingLocator())

        let outcome = await collector.observe(frameID: FrameID(1), input: Self.input(),
                                              coverage: CoverageMask(), quality: Self.acceptedQuality())

        switch outcome {
        case .failed:
            break // expected
        case .success(let batch):
            XCTFail("a throwing locator must never surface as .success (got \(batch.observations.count) observations)")
        case .skipped:
            XCTFail("a throwing locator is a failure, not a skip")
        }
    }

    func testZeroDetectionsIsARealSuccessNotAFailure() async {
        let collector = ObservationCollector(locator: EmptyLocator())

        let outcome = await collector.observe(frameID: FrameID(1), input: Self.input(),
                                              coverage: CoverageMask(), quality: Self.acceptedQuality())

        guard case .success(let batch) = outcome else {
            return XCTFail("an honest zero-detection frame is still a success, not a failure/skip")
        }
        XCTAssertTrue(batch.observations.isEmpty)
    }

    func testUnacceptedQualityIsSkippedBeforeAttempting() async {
        let rejecting = FrameQuality(trackingIsNormal: true, sharpness: 0, exposureScore: 0,
                                     clippingFraction: 1, projectedPixelsPerTile: 0,
                                     coverageFraction: 0, accepted: false,
                                     rejectionReasons: [.belowSharpnessThreshold])
        // A throwing locator here proves the guard short-circuits before any
        // inference is attempted (a throw would also surface as .failed, so
        // reaching .skipped is the only way this case can pass).
        let collector = ObservationCollector(locator: ThrowingLocator())

        let outcome = await collector.observe(frameID: FrameID(1), input: Self.input(),
                                              coverage: CoverageMask(), quality: rejecting)

        guard case .skipped(.qualityRejected(let reasons)) = outcome else {
            return XCTFail("rejected quality must skip before even calling the locator")
        }
        XCTAssertEqual(reasons, [.belowSharpnessThreshold])
    }

    func testTrackingNotNormalIsSkipped() async {
        let notTracking = FrameQuality(trackingIsNormal: false, sharpness: 1, exposureScore: 1,
                                       clippingFraction: 0, projectedPixelsPerTile: 100,
                                       coverageFraction: 1, accepted: true)
        let collector = ObservationCollector(locator: ThrowingLocator())

        let outcome = await collector.observe(frameID: FrameID(1), input: Self.input(),
                                              coverage: CoverageMask(), quality: notTracking)

        guard case .skipped(.trackingNotNormal) = outcome else {
            return XCTFail("tracking-not-normal must skip, got \(outcome)")
        }
    }

    func testSuccessCarriesLocalizationsIntoObservations() async {
        let box = TileBoundingBox(x: 0.2, y: 0.2, width: 0.1, height: 0.2)
        let locator = FixedLocator(localizations: [TileLocalization(box: box, confidence: 0.8)])
        let collector = ObservationCollector(locator: locator)

        let outcome = await collector.observe(frameID: FrameID(7), input: Self.input(),
                                              coverage: CoverageMask(), quality: Self.acceptedQuality())

        guard case .success(let batch) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(batch.observations.count, 1)
        XCTAssertEqual(batch.observations.first?.box, box)
        XCTAssertEqual(batch.observations.first?.frameID, FrameID(7))
    }
}

extension ObservationOutcome: CustomStringConvertible {
    public var description: String {
        switch self {
        case .success(let batch): return "success(\(batch.observations.count) observations)"
        case .skipped(let reason): return "skipped(\(reason))"
        case .failed(let failure): return "failed(\(failure))"
        }
    }
}
