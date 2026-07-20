import CoreVideo
import ImageIO
import XCTest
@testable import Recognition

final class DepthSamplerTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, nil, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return buffer!
    }

    private func fillDepth(_ buffer: CVPixelBuffer, with value: Float32) {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.stride
        let values = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            for x in 0..<width {
                values[y * stride + x] = value
            }
        }
    }

    private func fillConfidence(_ buffer: CVPixelBuffer, with value: UInt8) {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let values = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                values[y * stride + x] = value
            }
        }
    }

    private func fillDepthGradient(_ buffer: CVPixelBuffer) {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.stride
        let values = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            for x in 0..<width {
                values[y * stride + x] = Float32(1 + x + y * 10)
            }
        }
    }

    func testAllIPadOrientationsSampleTheSameRawDepthNeighborhood() throws {
        let depth = makeBuffer(width: 9, height: 9, format: kCVPixelFormatType_DepthFloat32)
        let confidence = makeBuffer(width: 9, height: 9, format: kCVPixelFormatType_OneComponent8)
        fillDepthGradient(depth)
        fillConfidence(confidence, with: 2)
        let rawPoint = SIMD2<Double>(0.25, 0.70)
        var samples: [Float] = []
        for orientation: CGImagePropertyOrientation in [.right, .left, .up, .down] {
            let transform = FrameImageTransform(
                imageOrientation: orientation,
                imageResolution: CGSize(width: 1920, height: 1440)
            )
            let oriented = transform.orientedNormalized(fromRaw: rawPoint)
            samples.append(try XCTUnwrap(DepthSampler.inspect(
                atOrientedNormalized: oriented,
                imageTransform: transform,
                depthMap: depth,
                confidenceMap: confidence
            ).depthMeters))
        }
        for sample in samples.dropFirst() {
            XCTAssertEqual(sample, samples[0], accuracy: 0.0001)
        }
    }

    func test_mediumConfidenceNeighborhoodReturnsMedian() {
        let depth = makeBuffer(width: 7, height: 7, format: kCVPixelFormatType_DepthFloat32)
        let confidence = makeBuffer(width: 7, height: 7, format: kCVPixelFormatType_OneComponent8)
        fillDepth(depth, with: 1.25)
        fillConfidence(confidence, with: 1)

        let sampled = DepthSampler.depth(
                atOrientedNormalized: SIMD2(0.5, 0.5),
                imageResolution: SIMD2(1920, 1440),
                orientedImageSize: SIMD2(1440, 1920),
                depthMap: depth,
                confidenceMap: confidence
            )
        XCTAssertEqual(try XCTUnwrap(sampled), 1.25, accuracy: 0.0001)
    }

    func test_lowConfidenceAndInvalidDepthAreRejected() {
        let depth = makeBuffer(width: 7, height: 7, format: kCVPixelFormatType_DepthFloat32)
        let confidence = makeBuffer(width: 7, height: 7, format: kCVPixelFormatType_OneComponent8)
        fillDepth(depth, with: .nan)
        fillConfidence(confidence, with: 0)

        let result = DepthSampler.inspect(
            atOrientedNormalized: SIMD2(0.5, 0.5),
            imageResolution: SIMD2(1920, 1440),
            orientedImageSize: SIMD2(1440, 1920),
            depthMap: depth,
            confidenceMap: confidence
        )
        XCTAssertNil(result.depthMeters)
        XCTAssertEqual(result.rejection, .noTrustworthyValues)
    }

    func test_missingConfidenceIsRejectedRatherThanGuessed() {
        let depth = makeBuffer(width: 3, height: 3, format: kCVPixelFormatType_DepthFloat32)
        fillDepth(depth, with: 1)
        let result = DepthSampler.inspect(
            atOrientedNormalized: SIMD2(0.5, 0.5),
            imageResolution: SIMD2(100, 100),
            orientedImageSize: SIMD2(100, 100),
            depthMap: depth,
            confidenceMap: nil
        )
        XCTAssertEqual(result.rejection, .missingConfidence)
    }
}
