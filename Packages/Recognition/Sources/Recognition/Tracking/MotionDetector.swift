import Foundation
import CoreVideo
import Accelerate

/// Cheap, spatial motion signal from the camera feed — the "how much and
/// roughly where did the table change" input that both drives `CadencePolicy`
/// (breathing cadence) and feeds `TurnEngine`'s seat-attribution evidence
/// (`MotionSample.dominantRegion`).
///
/// Technique (tracker plan §4.2): downscale the luma plane to a tiny 32×18
/// grid with `vImageScale_Planar8` (~0.2–0.5 ms for 1280×720 — chosen over
/// `CIAreaAverage` because it needs no CoreImage round-trip and *keeps
/// spatial information*, which a single scalar average would throw away),
/// then mean-abs-diff that grid against the previous one.
///
/// **Region mapping.** The grid is built directly from the RAW (landscape,
/// sensor-native, unrotated) buffer — no pixel rotation happens. Region
/// buckets are derived by applying the *same* `.right`-display-rotation
/// correspondence `RecognizerFrame.orientedPixelSize` already encodes
/// elsewhere in this module (`CameraCapture` is pinned to feed exactly this
/// buffer/orientation convention — landscape sensor-native, rotated 90° CW
/// for display): under a 90° CW rotation, the oriented image's left/right
/// edges are the raw buffer's bottom/top row-bands (inverted), and the
/// oriented image's top edge is the raw buffer's left column-band. So:
///   - oriented **right** third ← raw **top** row-band (small row index)
///   - oriented **center** third ← raw **middle** row-band
///   - oriented **left** third ← raw **bottom** row-band (large row index)
///   - oriented **top** ← raw **left** column-band (small column index)
/// The dominant region is whichever of these four band-sums is largest this
/// frame; a cell can (and often does) contribute to two bands at once (its
/// row-band and its column-band) — that's intentional, this is a coarse
/// evidence signal for `TurnEngine`'s attribution softmax, not a hard
/// partition.
///
/// Not `Sendable` — mutable single-owner state (the one previous grid), same
/// convention as `TrackStore`/`ZoneModel`. Works on macOS too (Accelerate is
/// a system framework there), so `Tools/detect-dump`'s video dumper can run
/// the *exact same* motion code as the live app for replay fidelity.
///
/// **Pixel format.** `CameraCapture` no longer pins a format — it leaves the
/// camera output at iOS's default `BGRA` (the format the proven scan/lookup
/// Vision path has always used). `sample` accepts that directly: `vImage`
/// has no `Planar8`-style single-channel scaler for interleaved formats, so
/// the BGRA path scales all 4 channels with `vImageScale_ARGB8888` (it only
/// cares that the buffer is 4 interleaved 8-bit channels, not their semantic
/// order) and then takes each scaled cell's green byte (`BGRA` byte layout:
/// B, G, R, A) as a cheap brightness proxy — deliberately NOT a real
/// BT.601/709 luma conversion, because this only feeds a coarse "did this
/// cell change" motion gate, not a visual output; precision doesn't matter.
/// The 420 bi-planar path (still accepted — see `isSupportedFormat`) stays
/// exactly as before, downscaling the luma plane straight with
/// `vImageScale_Planar8`.
public final class MotionDetector {

    /// Downscaled luma grid dimensions — small enough that the scale + diff
    /// is sub-millisecond, large enough to keep the "3 thirds + top" spatial
    /// resolution the plan calls for. Own constants, not `TrackerConfig`:
    /// nothing outside this type needs to tune grid resolution (mirrors
    /// `CadencePolicy` owning its own cadence constants rather than
    /// duplicating them into `TrackerConfig`). Internal (not `private`) so
    /// `MotionField`'s public `gridWidth`/`gridHeight` can mirror these
    /// exact values instead of duplicating the literals.
    static let gridWidth = 32
    static let gridHeight = 18
    private static let cellCount = gridWidth * gridHeight

    /// EMA smoothing weight on the published `level` (plan §4.2) — smooths
    /// frame-to-frame sensor/compression noise without lagging a real burst
    /// by more than a couple of ticks at the ~8 Hz poll rate.
    private static let emaAlpha = 0.4

    /// Per-cell |Δ| threshold for `MotionField.changed` (Lane B chunk E) —
    /// deliberately coarser than the aggregate diff's `diff > 0` gate below
    /// (which feeds `level`/`dominantRegion` and tolerates single-count
    /// sensor noise by summing across the whole grid): a single noisy cell
    /// flipping `changed` on its own would make ROI localization worse than
    /// useless. Not `TrackerConfig`-tunable — an internal detail of this
    /// type, same as `gridWidth`/`emaAlpha`.
    private static let changeThreshold = 10.0

    private var previousGrid: [UInt8]?
    private var smoothedLevel: Double = 0

    public init() {}

    /// One motion reading. Returns `nil` — never throws — when the buffer
    /// isn't one of the three supported formats (420 bi-planar full-range
    /// `420f`, video-range `420v` — the luma-plane layout is identical, and
    /// it's what `CVPixelBufferCreate` hands back by default in tests — or
    /// interleaved `BGRA`, the default/unpinned camera output — see the type
    /// doc's "Pixel format" section) or a plane/base address can't be read.
    /// A dropped motion sample degrades the UI's "breathing" cadence
    /// gracefully; it must never crash or block `ingest`.
    ///
    /// A thin wrapper over `sampleField(_:at:)` — the exact same grid/diff
    /// path, just discarding the per-cell `changed` grid that method also
    /// computes (Lane B chunk E's ROI scheduler). Byte-identical behavior to
    /// before that field existed: every numeric path (`level`,
    /// `dominantRegion`, `meanLuma`, the `previousGrid` mutation timing) is
    /// now computed exactly once, in `sampleField`, not duplicated here.
    public func sample(_ buffer: CVPixelBuffer, at t: TimeInterval) -> MotionSample? {
        sampleField(buffer, at: t)?.sample
    }

    /// Like `sample(_:at:)`, but also returns the uncollapsed per-cell change
    /// grid as a `MotionField` (Lane B chunk E) — see that type's doc. Shares
    /// every line of the grid-downscale/diff path with `sample`; nothing
    /// here duplicates that logic.
    public func sampleField(_ buffer: CVPixelBuffer, at t: TimeInterval) -> MotionField? {
        guard isSupportedFormat(buffer) else { return nil }
        guard let grid = downscaleLumaGrid(buffer) else { return nil }
        defer { previousGrid = grid }

        // Brightness needs no prior frame — computed up front so it's on
        // BOTH return paths below, including the very first sample of the
        // session (the dark-table torch chip must be able to react before
        // any motion diff exists at all).
        let meanLuma = grid.reduce(0.0) { $0 + Double($1) } / Double(grid.count)

        guard let previous = previousGrid else {
            let sample = MotionSample(t: t, level: 0, dominantRegion: nil, meanLuma: meanLuma)
            return MotionField(sample: sample, changed: [Bool](repeating: false, count: Self.cellCount))
        }

        let diff = diffGrids(grid, against: previous)
        let rawLevel = diff.totalDiff / Double(Self.cellCount * 255)
        smoothedLevel = Self.emaAlpha * rawLevel + (1 - Self.emaAlpha) * smoothedLevel

        var region: MotionRegion?
        if diff.totalDiff > 0 {
            let order: [MotionRegion] = [.left, .center, .right, .top]
            var bestIdx = 0
            for i in 1..<diff.bandSums.count where diff.bandSums[i] > diff.bandSums[bestIdx] { bestIdx = i }
            region = order[bestIdx]
        }

        let sample = MotionSample(t: t, level: smoothedLevel, dominantRegion: region, meanLuma: meanLuma)
        return MotionField(sample: sample, changed: diff.changed)
    }

    /// One frame's worth of per-cell diffing — the single computation both
    /// `sample`/`sampleField` build on. `bandSums`/`totalDiff` feed the
    /// COLLAPSED `level`/`dominantRegion` (via the existing `diff > 0` gate,
    /// unchanged from before `MotionField` existed); `changed` is the SAME
    /// per-cell `diff`, uncollapsed, thresholded by `changeThreshold`
    /// instead — a stricter, independent gate (see that constant's doc for
    /// why it can't just reuse `diff > 0`).
    private struct GridDiff { var bandSums: [Double]; var totalDiff: Double; var changed: [Bool] }

    private func diffGrids(_ grid: [UInt8], against previous: [UInt8]) -> GridDiff {
        // band index: 0 = left, 1 = center, 2 = right, 3 = top (see type doc).
        var bandSums = [Double](repeating: 0, count: 4)
        var totalDiff = 0.0
        var changed = [Bool](repeating: false, count: Self.cellCount)
        let topThird = Self.gridHeight / 3, bottomThird = 2 * Self.gridHeight / 3
        let leftThird = Self.gridWidth / 3
        for row in 0..<Self.gridHeight {
            for col in 0..<Self.gridWidth {
                let i = row * Self.gridWidth + col
                let diff = Double(abs(Int(grid[i]) - Int(previous[i])))
                changed[i] = diff > Self.changeThreshold
                guard diff > 0 else { continue }
                totalDiff += diff
                if row < topThird { bandSums[2] += diff }             // raw top → oriented right
                else if row < bottomThird { bandSums[1] += diff }     // raw middle → oriented center
                else { bandSums[0] += diff }                          // raw bottom → oriented left
                if col < leftThird { bandSums[3] += diff }            // raw left → oriented top
            }
        }
        return GridDiff(bandSums: bandSums, totalDiff: totalDiff, changed: changed)
    }

    // MARK: - vImage downscale

    /// Dispatches to the format-specific downscale path (see the type doc's
    /// "Pixel format" section); `nil` for anything `isSupportedFormat`
    /// already rejected.
    private func downscaleLumaGrid(_ buffer: CVPixelBuffer) -> [UInt8]? {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return downscaleLumaGrid420(buffer)
        case kCVPixelFormatType_32BGRA:
            return downscaleLumaGridBGRA(buffer)
        default:
            return nil
        }
    }

    /// 420 bi-planar path: scale plane 0 (luma) straight down with the
    /// single-channel `vImageScale_Planar8`.
    private func downscaleLumaGrid420(_ buffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, rowBytes > 0 else { return nil }

        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: rowBytes)

        var destBytes = [UInt8](repeating: 0, count: Self.cellCount)
        let error: vImage_Error = destBytes.withUnsafeMutableBytes { destPtr in
            var dst = vImage_Buffer(data: destPtr.baseAddress, height: vImagePixelCount(Self.gridHeight),
                                    width: vImagePixelCount(Self.gridWidth), rowBytes: Self.gridWidth)
            return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { return nil }
        return destBytes
    }

    /// `BGRA` path — the default (now-unpinned) camera output. `vImage` has
    /// no `Planar8`-style single-channel scaler for interleaved data, so this
    /// scales all 4 channels at once with `vImageScale_ARGB8888` (it only
    /// cares that the buffer is 4 interleaved 8-bit channels, not their
    /// semantic order — BGRA fits structurally) and then takes each scaled
    /// cell's green byte (`BGRA` byte layout: B, G, R, A) as a cheap
    /// brightness proxy. This is deliberately NOT a real BT.601/709 luma
    /// conversion — gate precision doesn't matter, only "did this cell
    /// change" does (see the type doc).
    private func downscaleLumaGridBGRA(_ buffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, rowBytes > 0 else { return nil }

        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: rowBytes)

        // Scaled 32×18 BGRA buffer (4 bytes/cell) — narrowed to one byte/cell
        // (the green channel) below.
        var scaled = [UInt8](repeating: 0, count: Self.cellCount * 4)
        let error: vImage_Error = scaled.withUnsafeMutableBytes { destPtr in
            var dst = vImage_Buffer(data: destPtr.baseAddress, height: vImagePixelCount(Self.gridHeight),
                                    width: vImagePixelCount(Self.gridWidth), rowBytes: Self.gridWidth * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { return nil }

        var grid = [UInt8](repeating: 0, count: Self.cellCount)
        for i in 0..<Self.cellCount { grid[i] = scaled[i * 4 + 1] }   // green byte
        return grid
    }

    private func isSupportedFormat(_ buffer: CVPixelBuffer) -> Bool {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_32BGRA:
            return true
        default:
            return false
        }
    }
}
