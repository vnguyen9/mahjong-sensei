import Foundation
import simd

/// Platform-neutral metadata stored beside ARKit's opaque world-map archive.
/// Tile identities and counts are deliberately absent: only the calibrated
/// play-area extent survives a launch.
public struct WorldMapCalibrationMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var extentX: Float
    public var extentZ: Float

    public init(version: Int = Self.currentVersion,
                extent: SIMD2<Float>) {
        self.version = version
        self.extentX = extent.x
        self.extentZ = extent.y
    }

    public var validatedExtent: SIMD2<Float>? {
        guard version == Self.currentVersion,
              extentX.isFinite, extentZ.isFinite,
              (0.65 ... 1.20).contains(extentX),
              (0.65 ... 1.20).contains(extentZ) else {
            return nil
        }
        return SIMD2(extentX, extentZ)
    }
}
