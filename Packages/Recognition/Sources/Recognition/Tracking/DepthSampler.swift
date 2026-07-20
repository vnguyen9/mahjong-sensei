import CoreVideo
import Foundation
import simd

public enum DepthSampleRejection: String, Sendable, Equatable {
    case missingDepth
    case missingConfidence
    case invalidGeometry
    case unsupportedDepthFormat
    case unsupportedConfidenceFormat
    case noTrustworthyValues
    case heightOutOfRange
    case orientationTransition
    case occluded
}

public struct DepthSampleResult: Sendable, Equatable {
    public var depthMeters: Float?
    public var rejection: DepthSampleRejection?

    public init(depthMeters: Float?, rejection: DepthSampleRejection?) {
        self.depthMeters = depthMeters
        self.rejection = rejection
    }
}

/// Samples ARKit scene depth at a detector point without inventing spatial
/// evidence. Coordinates follow ``TableProjection``'s `.right`-oriented,
/// normalized image convention; depth/confidence buffers remain in captured
/// landscape orientation.
public enum DepthSampler {
    /// Returns the median of a 5×5 medium/high-confidence neighborhood.
    /// `nil` means no trustworthy spatial observation should be emitted.
    public static func depth(
        atOrientedNormalized point: SIMD2<Double>,
        imageResolution: SIMD2<Double>,
        orientedImageSize: SIMD2<Double>,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?
    ) -> Float? {
        inspect(
            atOrientedNormalized: point,
            imageResolution: imageResolution,
            orientedImageSize: orientedImageSize,
            depthMap: depthMap,
            confidenceMap: confidenceMap
        ).depthMeters
    }

    public static func inspect(
        atOrientedNormalized point: SIMD2<Double>,
        imageResolution: SIMD2<Double>,
        orientedImageSize: SIMD2<Double>,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?
    ) -> DepthSampleResult {
        inspect(
            atOrientedNormalized: point,
            imageTransform: FrameImageTransform(
                imageOrientation: .right,
                imageResolution: CGSize(
                    width: imageResolution.x,
                    height: imageResolution.y
                )
            ),
            depthMap: depthMap,
            confidenceMap: confidenceMap
        )
    }

    public static func inspect(
        atOrientedNormalized point: SIMD2<Double>,
        imageTransform: FrameImageTransform,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?
    ) -> DepthSampleResult {
        guard let depthMap else {
            return DepthSampleResult(depthMeters: nil, rejection: .missingDepth)
        }
        guard let confidenceMap else {
            return DepthSampleResult(depthMeters: nil, rejection: .missingConfidence)
        }
        let imageResolution = SIMD2<Double>(
            imageTransform.imageResolution.width,
            imageTransform.imageResolution.height
        )
        guard imageResolution.x > 0, imageResolution.y > 0,
              imageTransform.orientedImageSize.width > 0,
              imageTransform.orientedImageSize.height > 0,
              point.x.isFinite, point.y.isFinite else {
            return DepthSampleResult(depthMeters: nil, rejection: .invalidGeometry)
        }
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return DepthSampleResult(depthMeters: nil, rejection: .unsupportedDepthFormat)
        }
        guard CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 else {
            return DepthSampleResult(depthMeters: nil, rejection: .unsupportedConfidenceFormat)
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let confidenceWidth = CVPixelBufferGetWidth(confidenceMap)
        let confidenceHeight = CVPixelBufferGetHeight(confidenceMap)
        guard depthWidth > 0, depthHeight > 0, confidenceWidth > 0, confidenceHeight > 0 else {
            return DepthSampleResult(depthMeters: nil, rejection: .invalidGeometry)
        }

        let raw = imageTransform.rawNormalized(fromOriented: point)
        let capturedX = raw.x * imageResolution.x
        let capturedY = raw.y * imageResolution.y
        let depthX = capturedX / imageResolution.x * Double(depthWidth)
        let depthY = capturedY / imageResolution.y * Double(depthHeight)
        guard depthX.isFinite, depthY.isFinite,
              depthX >= 0, depthY >= 0,
              depthX <= Double(depthWidth), depthY <= Double(depthHeight) else {
            return DepthSampleResult(depthMeters: nil, rejection: .invalidGeometry)
        }

        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else {
            return DepthSampleResult(depthMeters: nil, rejection: .unsupportedDepthFormat)
        }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) == kCVReturnSuccess else {
            return DepthSampleResult(depthMeters: nil, rejection: .unsupportedConfidenceFormat)
        }
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return DepthSampleResult(depthMeters: nil, rejection: .invalidGeometry)
        }

        let centerX = min(max(Int(depthX.rounded()), 0), depthWidth - 1)
        let centerY = min(max(Int(depthY.rounded()), 0), depthHeight - 1)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
        let depths = depthBase.assumingMemoryBound(to: Float32.self)
        let confidences = confidenceBase.assumingMemoryBound(to: UInt8.self)
        var accepted: [Float] = []
        accepted.reserveCapacity(25)

        for y in max(0, centerY - 2)...min(depthHeight - 1, centerY + 2) {
            for x in max(0, centerX - 2)...min(depthWidth - 1, centerX + 2) {
                let confidenceX = min(
                    confidenceWidth - 1,
                    max(0, Int((Double(x) + 0.5) / Double(depthWidth) * Double(confidenceWidth)))
                )
                let confidenceY = min(
                    confidenceHeight - 1,
                    max(0, Int((Double(y) + 0.5) / Double(depthHeight) * Double(confidenceHeight)))
                )
                // ARConfidenceLevel: low=0, medium=1, high=2.
                guard confidences[confidenceY * confidenceStride + confidenceX] >= 1 else { continue }
                let value = depths[y * depthStride + x]
                guard value.isFinite, value > 0 else { continue }
                accepted.append(value)
            }
        }

        guard !accepted.isEmpty else {
            return DepthSampleResult(depthMeters: nil, rejection: .noTrustworthyValues)
        }
        accepted.sort()
        let middle = accepted.count / 2
        let median: Float
        if accepted.count.isMultiple(of: 2) {
            median = (accepted[middle - 1] + accepted[middle]) / 2
        } else {
            median = accepted[middle]
        }
        return DepthSampleResult(depthMeters: median, rejection: nil)
    }
}
