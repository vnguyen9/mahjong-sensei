import XCTest
@testable import Recognition

final class TileSizeMeasurementTests: XCTestCase {
    func testFiveStableSamplesOverOneSecondAreAccepted() {
        var accumulator = TileSizeMeasurementAccumulator()
        var outcome: TileSizeMeasurementAccumulator.Outcome = .collecting(sampleCount: 0)
        for index in 0...5 {
            outcome = accumulator.append(TileSizeMeasurementSample(
                width: 0.024 + Float(index % 2) * 0.0002,
                length: 0.032 + Float(index % 2) * 0.0002,
                height: 0.016,
                timestamp: Double(index) * 0.2
            ))
        }
        guard case let .accepted(sample) = outcome else {
            return XCTFail("Expected stable measurement, got \(outcome)")
        }
        XCTAssertEqual(sample.width, 0.0241, accuracy: 0.0002)
        XCTAssertEqual(sample.length, 0.0321, accuracy: 0.0002)
        XCTAssertEqual(sample.height, 0.016, accuracy: 0.0001)
    }

    func testMeasurementCannotCompleteBeforeOneSecond() {
        var accumulator = TileSizeMeasurementAccumulator()
        var outcome: TileSizeMeasurementAccumulator.Outcome = .collecting(sampleCount: 0)
        for index in 0..<5 {
            outcome = accumulator.append(TileSizeMeasurementSample(
                width: 0.024, length: 0.032, height: 0.016,
                timestamp: Double(index) * 0.1
            ))
        }
        XCTAssertEqual(outcome, .collecting(sampleCount: 5))
    }

    func testUnstableAndOutOfRangeMeasurementsAreRejected() {
        var unstable = TileSizeMeasurementAccumulator()
        let widths: [Float] = [0.020, 0.028, 0.020, 0.028, 0.024, 0.024]
        var unstableOutcome: TileSizeMeasurementAccumulator.Outcome = .collecting(sampleCount: 0)
        for (index, width) in widths.enumerated() {
            unstableOutcome = unstable.append(TileSizeMeasurementSample(
                width: width, length: 0.032, height: 0.016,
                timestamp: Double(index) * 0.2
            ))
        }
        XCTAssertEqual(unstableOutcome, .rejected(.unstable))

        var invalid = TileSizeMeasurementAccumulator()
        var invalidOutcome: TileSizeMeasurementAccumulator.Outcome = .collecting(sampleCount: 0)
        for index in 0...5 {
            invalidOutcome = invalid.append(TileSizeMeasurementSample(
                width: 0.015, length: 0.032, height: 0.016,
                timestamp: Double(index) * 0.2
            ))
        }
        XCTAssertEqual(invalidOutcome, .rejected(.widthOutOfRange))
    }

    func testResetReturnsToEmptyCollection() {
        var accumulator = TileSizeMeasurementAccumulator()
        _ = accumulator.append(TileSizeMeasurementSample(
            width: 0.024, length: 0.032, height: 0.016, timestamp: 0
        ))
        accumulator.reset()
        XCTAssertTrue(accumulator.samples.isEmpty)
    }
}
