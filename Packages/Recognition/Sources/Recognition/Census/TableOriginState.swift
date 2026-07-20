import Foundation
import simd

/// One session's fitted play-area frame. Local +Z points toward the user's
/// camera position at lock time; local X/Z lie on the locked horizontal
/// plane and local Y is its normal.
public struct TableOriginState: Sendable {
    public private(set) var tableToWorld: simd_float4x4
    public private(set) var extent: SIMD2<Float>
    public private(set) var lockedAt: TimeInterval
    public private(set) var hasTileCloudFit: Bool
    public private(set) var autoFitDisabled: Bool
    public private(set) var isFrozen: Bool

    public var worldToTable: simd_float4x4 { simd_inverse(tableToWorld) }

    public init(lockedPlaneTransform: simd_float4x4,
                lockedExtent: Float,
                cameraPosition: SIMD3<Float>,
                at time: TimeInterval) {
        let origin = SIMD3<Float>(
            lockedPlaneTransform.columns.3.x,
            lockedPlaneTransform.columns.3.y,
            lockedPlaneTransform.columns.3.z
        )
        var y = SIMD3<Float>(
            lockedPlaneTransform.columns.1.x,
            lockedPlaneTransform.columns.1.y,
            lockedPlaneTransform.columns.1.z
        )
        if simd_length_squared(y) < 1e-6 { y = SIMD3(0, 1, 0) }
        y = simd_normalize(y)
        if y.y < 0 { y = -y }

        var z = cameraPosition - origin
        z -= y * simd_dot(z, y)
        if simd_length_squared(z) < 1e-6 {
            z = SIMD3(
                lockedPlaneTransform.columns.2.x,
                lockedPlaneTransform.columns.2.y,
                lockedPlaneTransform.columns.2.z
            )
        }
        z = simd_normalize(z)
        let x = simd_normalize(simd_cross(y, z))
        self.tableToWorld = simd_float4x4(
            SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1)
        )
        let initial = Self.clamp(lockedExtent)
        self.extent = SIMD2(repeating: initial)
        self.lockedAt = time
        self.hasTileCloudFit = false
        self.autoFitDisabled = false
        self.isFrozen = false
    }

    /// Fits translation and 5th–95th-percentile bounds after at least eight
    /// confirmed world tracks. The first fit may replace the plane extent;
    /// subsequent fits during the 30-second window only expand it.
    @discardableResult
    public mutating func updateAutoFit(
        confirmedWorldPositions: [SIMD3<Float>],
        at time: TimeInterval
    ) -> Bool {
        guard !autoFitDisabled, !isFrozen else { return false }
        if time - lockedAt >= 30 {
            isFrozen = true
            return false
        }
        guard confirmedWorldPositions.count >= 8 else { return false }

        let medianWorld = SIMD3<Float>(
            Self.quantile(confirmedWorldPositions.map(\.x), 0.5),
            tableToWorld.columns.3.y,
            Self.quantile(confirmedWorldPositions.map(\.z), 0.5)
        )
        if !hasTileCloudFit {
            tableToWorld.columns.3 = SIMD4(medianWorld, 1)
        }

        let inverse = simd_inverse(tableToWorld)
        let local = confirmedWorldPositions.map { position -> SIMD2<Float> in
            let p = inverse * SIMD4(position, 1)
            return SIMD2(p.x, p.z)
        }
        let width = Self.quantile(local.map(\.x), 0.95)
            - Self.quantile(local.map(\.x), 0.05) + 0.120
        let depth = Self.quantile(local.map(\.y), 0.95)
            - Self.quantile(local.map(\.y), 0.05) + 0.120
        let proposed = SIMD2(Self.clamp(width), Self.clamp(depth))
        extent = hasTileCloudFit
            ? SIMD2(max(extent.x, proposed.x), max(extent.y, proposed.y))
            : proposed
        hasTileCloudFit = true
        return true
    }

    public mutating func recenterPond(at worldPosition: SIMD3<Float>) {
        tableToWorld.columns.3 = SIMD4(
            worldPosition.x,
            tableToWorld.columns.3.y,
            worldPosition.z,
            1
        )
        autoFitDisabled = true
        isFrozen = true
    }

    private static func clamp(_ value: Float) -> Float {
        min(1.20, max(0.65, value))
    }

    private static func quantile(_ values: [Float], _ q: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Float(sorted.count - 1) * q).rounded())
        return sorted[min(sorted.count - 1, max(0, index))]
    }
}
