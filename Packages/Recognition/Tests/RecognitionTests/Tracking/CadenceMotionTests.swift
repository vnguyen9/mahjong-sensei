import XCTest
import Foundation
import CoreVideo
@testable import Recognition

/// Chunk-6 coverage: `CadencePolicy` (cadence transitions, thermal backoff,
/// settle-burst) and `MotionDetector` (vImage luma-grid diff on synthesized
/// `CVPixelBuffer`s) — the tracker plan's §9.28/§9.29 test list items.
final class CadenceMotionTests: XCTestCase {

    // MARK: - CadencePolicy

    func testIdleCadenceIsRoughlyOneHertz() {
        var policy = CadencePolicy()
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .nominal, timeSinceLastInference: 0.5), .skip)
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .nominal, timeSinceLastInference: 1.0), .infer)
    }

    func testMotionAboveActiveSwitchesToBurstCadence() {
        var policy = CadencePolicy()
        let config = TrackerConfig()
        // Below burstInterval(0.18) but above idleInterval would matter if
        // idle applied — active motion must let it infer well before 1s.
        XCTAssertEqual(policy.decide(motionLevel: config.motionActive + 0.01, thermal: .nominal,
                                     timeSinceLastInference: 0.05), .skip, "not due yet at burst cadence either")
        XCTAssertEqual(policy.decide(motionLevel: config.motionActive + 0.01, thermal: .nominal,
                                     timeSinceLastInference: 0.18), .infer)
    }

    func testSettleBurstFiresThreeTimesThenDecaysToIdle() {
        var policy = CadencePolicy()
        let config = TrackerConfig()
        // Arm the burst state.
        _ = policy.decide(motionLevel: config.motionActive + 0.05, thermal: .nominal, timeSinceLastInference: 1.0)
        // Motion calms this tick — settle burst should now be armed.
        var inferCount = 0
        for _ in 0..<3 {
            let d = policy.decide(motionLevel: 0.0, thermal: .nominal, timeSinceLastInference: policy.settleBurstInterval)
            XCTAssertEqual(d, .infer, "each of the 3 settle-burst frames must infer at the tight interval")
            inferCount += 1
        }
        XCTAssertEqual(inferCount, 3)
        // The 4th calm tick at the settle-burst interval should now be
        // judged against the (longer) idle interval and skip.
        XCTAssertEqual(policy.decide(motionLevel: 0.0, thermal: .nominal, timeSinceLastInference: policy.settleBurstInterval),
                       .skip, "settle burst exhausted — falls back to idle cadence")
        XCTAssertEqual(policy.decide(motionLevel: 0.0, thermal: .nominal, timeSinceLastInference: policy.idleInterval),
                       .infer)
    }

    func testFairThermalScalesIntervalsByMultiplier() {
        var policy = CadencePolicy()
        let scaled = policy.idleInterval * policy.fairMultiplier
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .fair, timeSinceLastInference: policy.idleInterval),
                       .skip, "not due yet — fair thermal stretches the idle interval")
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .fair, timeSinceLastInference: scaled), .infer)
    }

    func testSeriousThermalUsesItsOwnSlowerIntervalsButKeepsSettleBurstFast() {
        var policy = CadencePolicy()
        let config = TrackerConfig()
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .serious, timeSinceLastInference: policy.idleInterval),
                       .skip, "serious idle interval is slower than nominal idle")
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .serious, timeSinceLastInference: policy.seriousIdleInterval),
                       .infer)

        // Arm a settle burst under .serious, then confirm it still uses the
        // fast settleBurstInterval, not the slower seriousIdleInterval.
        var burstPolicy = CadencePolicy()
        _ = burstPolicy.decide(motionLevel: config.motionActive + 0.05, thermal: .serious, timeSinceLastInference: 1.0)
        XCTAssertEqual(burstPolicy.decide(motionLevel: 0, thermal: .serious, timeSinceLastInference: burstPolicy.settleBurstInterval),
                       .infer, "settle bursts are kept fast even under .serious thermal")
    }

    func testCriticalThermalSuspendsRegardlessOfMotionOrTiming() {
        var policy = CadencePolicy()
        XCTAssertEqual(policy.decide(motionLevel: 1.0, thermal: .critical, timeSinceLastInference: 1000), .suspend)
    }

    func testRecoveryFromCriticalResumesNormalCadence() {
        var policy = CadencePolicy()
        _ = policy.decide(motionLevel: 1.0, thermal: .critical, timeSinceLastInference: 1000)
        XCTAssertEqual(policy.decide(motionLevel: 0, thermal: .nominal, timeSinceLastInference: policy.idleInterval), .infer)
    }

    func testThermalInitFromProcessInfoRawValueMapsDirectly() {
        XCTAssertEqual(CadencePolicy.Thermal(processInfoRawValue: 0), .nominal)
        XCTAssertEqual(CadencePolicy.Thermal(processInfoRawValue: 1), .fair)
        XCTAssertEqual(CadencePolicy.Thermal(processInfoRawValue: 2), .serious)
        XCTAssertEqual(CadencePolicy.Thermal(processInfoRawValue: 3), .critical)
        XCTAssertEqual(CadencePolicy.Thermal(processInfoRawValue: 99), .critical, "unknown raw values fail safe to critical")
    }

    // MARK: - MotionDetector (§9.29)

    /// Builds a 320×180 (16:9, exact ×10 of the 32×18 grid) bi-planar 420
    /// full-range `CVPixelBuffer` and fills the luma plane uniformly with
    /// `value`, except a rectangular patch (in luma-plane pixel coordinates)
    /// filled with `patchValue` when provided.
    private func makeBuffer(value: UInt8, patch: (x: Int, y: Int, w: Int, h: Int, value: UInt8)? = nil) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         attrs as CFDictionary, &pb)
        precondition(status == kCVReturnSuccess, "test setup: CVPixelBufferCreate failed (\(status))")
        let buffer = pb!

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for col in 0..<width {
                base[row * rowBytes + col] = value
            }
        }
        if let patch {
            for row in patch.y..<min(patch.y + patch.h, height) {
                for col in patch.x..<min(patch.x + patch.w, width) {
                    base[row * rowBytes + col] = patch.value
                }
            }
        }
        return buffer
    }

    func testIdenticalBuffersReportNearZeroLevel() {
        let detector = MotionDetector()
        let a = makeBuffer(value: 128)
        let b = makeBuffer(value: 128)
        _ = detector.sample(a, at: 0.0)                    // first call only seeds `previousGrid`
        let sample = detector.sample(b, at: 0.1)
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample!.level, 0, accuracy: 0.0001)
        XCTAssertNil(sample!.dominantRegion, "no diff at all — no dominant region")
    }

    func testFirstSampleEverReturnsZeroLevelAndNoRegion() {
        let detector = MotionDetector()
        let sample = detector.sample(makeBuffer(value: 100), at: 0.0)
        XCTAssertEqual(sample?.level, 0)
        XCTAssertNil(sample?.dominantRegion)
    }

    /// A change concentrated in the raw buffer's TOP row-band maps to the
    /// oriented frame's RIGHT third (see `MotionDetector`'s type doc for the
    /// `.right`-rotation correspondence this asserts).
    func testChangeInRawTopBandReportsOrientedRightRegion() {
        let detector = MotionDetector()
        let base = makeBuffer(value: 40)
        // Top 1/3 of a 180-tall luma plane is rows 0..<60 — exactly the raw
        // row-band `MotionDetector` buckets into oriented `.right`; patch
        // the whole band across the width so it dominates unambiguously.
        let changed = makeBuffer(value: 40, patch: (x: 0, y: 0, w: 320, h: 60, value: 220))
        _ = detector.sample(base, at: 0.0)
        let sample = detector.sample(changed, at: 0.1)
        XCTAssertNotNil(sample)
        XCTAssertGreaterThan(sample!.level, TrackerConfig().motionActive)
        XCTAssertEqual(sample!.dominantRegion, .right)
    }

    func testChangeInRawBottomBandReportsOrientedLeftRegion() {
        let detector = MotionDetector()
        let base = makeBuffer(value: 40)
        // Bottom 1/3 (rows 120..<180) — the raw row-band that buckets into
        // oriented `.left`.
        let changed = makeBuffer(value: 40, patch: (x: 0, y: 120, w: 320, h: 60, value: 220))
        _ = detector.sample(base, at: 0.0)
        let sample = detector.sample(changed, at: 0.1)
        XCTAssertEqual(sample?.dominantRegion, .left)
    }

    func testUnsupportedFormatReturnsNil() {
        // `32ARGB` — neither of the accepted 420 bi-planar formats nor the
        // accepted `32BGRA` interleaved format (see `testBGRABuffer...`
        // below) — must still degrade to nil, never crash.
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pb)
        precondition(status == kCVReturnSuccess)
        let detector = MotionDetector()
        XCTAssertNil(detector.sample(pb!, at: 0.0), "an unsupported pixel format must degrade to nil, never crash")
    }

    // MARK: - MotionDetector: BGRA path

    /// Builds a 320×180 interleaved `BGRA` `CVPixelBuffer` (mirrors
    /// `makeBuffer`'s bi-planar-420 buffer, but 4-channel interleaved) with
    /// B=G=R=`value` uniformly (and A=255), except an optional patch. Setting
    /// all three color channels equal makes the expected diff
    /// format-independent — `MotionDetector`'s BGRA downscale is a cheap
    /// approximation (see its doc), not a real luma conversion, so this test
    /// only needs "brighter patch ⇒ bigger diff in the right cells," not an
    /// exact byte value.
    private func makeBGRABuffer(value: UInt8, patch: (x: Int, y: Int, w: Int, h: Int, value: UInt8)? = nil) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        precondition(status == kCVReturnSuccess, "test setup: CVPixelBufferCreate failed (\(status))")
        let buffer = pb!

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        func fill(x: Int, y: Int, w: Int, h: Int, value: UInt8) {
            for row in y..<min(y + h, height) {
                for col in x..<min(x + w, width) {
                    let offset = row * rowBytes + col * 4
                    base[offset] = value        // B
                    base[offset + 1] = value    // G
                    base[offset + 2] = value    // R
                    base[offset + 3] = 255      // A
                }
            }
        }
        fill(x: 0, y: 0, w: width, h: height, value: value)
        if let patch { fill(x: patch.x, y: patch.y, w: patch.w, h: patch.h, value: patch.value) }
        return buffer
    }

    /// Mirrors `testChangeInRawTopBandReportsOrientedRightRegion` on a BGRA
    /// buffer instead of a 420 bi-planar one — confirms the format is
    /// actually accepted (not silently dropped to nil) and that the
    /// green-channel downscale still produces a usable diff + region.
    func testBGRABufferChangeInRawTopBandReportsOrientedRightRegion() {
        let detector = MotionDetector()
        let base = makeBGRABuffer(value: 40)
        let changed = makeBGRABuffer(value: 40, patch: (x: 0, y: 0, w: 320, h: 60, value: 220))
        _ = detector.sample(base, at: 0.0)
        let sample = detector.sample(changed, at: 0.1)
        XCTAssertNotNil(sample, "BGRA is now a supported motion-gate format")
        XCTAssertGreaterThan(sample!.level, TrackerConfig().motionActive)
        XCTAssertEqual(sample!.dominantRegion, .right)
    }

    func testLevelIsEMASmoothedAcrossFrames() {
        let detector = MotionDetector()
        let a = makeBuffer(value: 0)
        let bright = makeBuffer(value: 255)
        _ = detector.sample(a, at: 0.0)
        let first = detector.sample(bright, at: 0.1)!.level
        // Diffing back to a flat buffer of the *same* value as `bright`
        // shouldn't be zero relative to the previous (bright) grid unless
        // it's identical — feed `bright` again to isolate smoothing decay.
        let second = detector.sample(bright, at: 0.2)!.level
        XCTAssertLessThan(second, first, "level decays toward 0 (EMA) once the scene stops changing")
    }
}
