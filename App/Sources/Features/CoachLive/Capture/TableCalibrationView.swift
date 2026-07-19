import DesignSystem
import Recognition
import SwiftUI
import simd

/// The v2.5 calibration UX (Technical design §4.1/§4.2/§4.3): four
/// draggable corner handles over the live AR preview, a user-edge (hand
/// band depth) slider, a mandatory "Confirm table" button, and a "Rescan"
/// link. Deliberately minimal — no animations beyond what SwiftUI gives for
/// free, no extra chrome; this is the functional calibration surface, not a
/// polished one.
///
/// Takes an already-built `CalibratedTable` (from `TableQuadProposal` +
/// `CalibratedTable.init(proposal:)`) rather than computing its own
/// proposal — orchestrating AR capture into a proposal is a later chunk's
/// job (`CoachLiveSession`/`ARTableCapture` wiring); this view is only about
/// letting the user edit and confirm ONE.
///
/// `lockedPlaneTransform` is a fixed snapshot (the plane
/// `TableCalibrationController` locked) — every corner render and every
/// drag-to-plane raycast this view performs reads it, paired with a FRESH
/// `capture.latestFrame` pulled once per operation (never a stale
/// intrinsics/pose mix — see `handleDrag`'s doc, matching §4.2's "each drag
/// handle is mapped back to the plane with the SAME `ARFrame` intrinsics and
/// camera pose used to render it").
struct TableCalibrationView: View {
    let capture: ARTableCapture
    let lockedPlaneTransform: simd_float4x4
    let onConfirm: (CalibratedTable) -> Void
    let onRescan: () -> Void

    @State private var table: CalibratedTable
    /// Corner indices whose most recent drag failed to raycast onto the
    /// plane (§4.2: "a corner that cannot raycast onto the selected plane is
    /// invalid and cannot be confirmed") — the corner's POSITION is left
    /// where it last successfully raycast; only the visual/Confirm-gating
    /// state reflects the failed attempt.
    @State private var invalidCornerIndices: Set<Int> = []

    private static let calibrationSpace = "TableCalibrationView.calibrationSpace"
    private static let refreshInterval: TimeInterval = 1.0 / 15.0

    init(capture: ARTableCapture,
         lockedPlaneTransform: simd_float4x4,
         initialTable: CalibratedTable,
         onConfirm: @escaping (CalibratedTable) -> Void,
         onRescan: @escaping () -> Void) {
        self.capture = capture
        self.lockedPlaneTransform = lockedPlaneTransform
        self.onConfirm = onConfirm
        self.onRescan = onRescan
        self._table = State(initialValue: initialTable)
    }

    var body: some View {
        GeometryReader { geo in
            let previewBounds = CGRect(origin: .zero, size: geo.size)
            // Handle positions must track the moving camera even though
            // `capture.latestFrame` is a polled (not `@Observable`) field —
            // `TimelineView` re-evaluates its content on a fixed cadence so
            // the overlay stays live without a manually-managed timer.
            TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
                ZStack {
                    ARCameraPreview(capture: capture)
                    ForEach(0..<4, id: \.self) { index in
                        handleView(index: index, previewBounds: previewBounds)
                    }
                    VStack {
                        Spacer()
                        controls(previewBounds: previewBounds)
                    }
                }
                .coordinateSpace(name: Self.calibrationSpace)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Corner handles

    @ViewBuilder
    private func handleView(index: Int, previewBounds: CGRect) -> some View {
        if let frame = capture.latestFrame,
           let screenPoint = screenPoint(for: table.corners[index], frame: frame, previewBounds: previewBounds) {
            Circle()
                .fill(invalidCornerIndices.contains(index) ? MJColor.amberZone : MJColor.gold)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .position(screenPoint)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.calibrationSpace))
                        .onChanged { value in
                            handleDrag(index: index, to: value.location, previewBounds: previewBounds)
                        }
                )
        }
    }

    /// Maps a screen drag location back to the plane using the SAME
    /// `ARTableFrame` for both halves of the round trip (oriented-normalized
    /// → table point), per §4.2's "same frame" requirement. A failed
    /// raycast (off the plane, behind the camera, degenerate intrinsics)
    /// marks the corner invalid and leaves its stored position untouched.
    private func handleDrag(index: Int, to location: CGPoint, previewBounds: CGRect) {
        guard let frame = capture.latestFrame else { return }
        let normalizedBox = AspectFillMapping.normalizedImageRect(
            of: CGRect(origin: location, size: .zero),
            previewBounds: previewBounds,
            orientedImageSize: frame.orientedImageSize)
        let orientedSize = SIMD2<Double>(Double(frame.orientedImageSize.width), Double(frame.orientedImageSize.height))
        guard let tablePoint = tableProjection(frame: frame)
            .tablePoint(ofNormalizedOrientedPoint: SIMD2<Double>(normalizedBox.x, normalizedBox.y),
                       orientedImageSize: orientedSize) else {
            invalidCornerIndices.insert(index)
            return
        }
        invalidCornerIndices.remove(index)
        table.movingCorner(index, to: SIMD2<Float>(Float(tablePoint.x), Float(tablePoint.y)))
    }

    private func screenPoint(for corner: SIMD2<Float>, frame: ARTableFrame, previewBounds: CGRect) -> CGPoint? {
        guard previewBounds.width > 0, previewBounds.height > 0 else { return nil }
        let orientedSize = SIMD2<Double>(Double(frame.orientedImageSize.width), Double(frame.orientedImageSize.height))
        guard let normalized = tableProjection(frame: frame)
            .normalizedOrientedPoint(ofTablePoint: SIMD2<Double>(Double(corner.x), Double(corner.y)),
                                     orientedImageSize: orientedSize) else { return nil }
        let box = TileBoundingBox(x: normalized.x, y: normalized.y, width: 0, height: 0)
        let rect = AspectFillMapping.previewRect(ofNormalized: box, previewBounds: previewBounds,
                                                 orientedImageSize: frame.orientedImageSize)
        return CGPoint(x: rect.minX, y: rect.minY)
    }

    private func tableProjection(frame: ARTableFrame) -> TableProjection {
        TableProjection(cameraTransform: frame.cameraTransform,
                        intrinsics: frame.intrinsics,
                        imageResolution: SIMD2<Float>(Float(frame.imageResolution.width), Float(frame.imageResolution.height)),
                        planeTransform: lockedPlaneTransform)
    }

    // MARK: - Controls

    private func controls(previewBounds: CGRect) -> some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hand boundary")
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Slider(value: Binding(
                    get: { Double(table.handBandFraction) },
                    set: { table.settingHandBandFraction(Float($0)) }
                ), in: Double(CalibratedTable.handBandFractionRange.lowerBound)...Double(CalibratedTable.handBandFractionRange.upperBound))
                .tint(MJColor.gold)
            }

            Button {
                onConfirm(table)
            } label: {
                Text("Confirm table")
                    .font(MJFont.ui(15, weight: .bold))
                    .foregroundStyle(MJColor.inkOnGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(MJColor.gold, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm(previewBounds: previewBounds))
            .opacity(canConfirm(previewBounds: previewBounds) ? 1 : 0.5)

            Button("Rescan", action: onRescan)
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.7))
                .buttonStyle(.plain)
        }
        .padding(20)
        .mjCard(cornerRadius: 20)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    /// Mandatory-confirmation gate (§4.1: "user confirmation remains
    /// mandatory even when confidence is high") — additionally requires
    /// every corner to currently raycast validly (not just at the moment it
    /// was last dragged), so a stale proposal the camera has since panned
    /// away from can't be confirmed blind.
    private func canConfirm(previewBounds: CGRect) -> Bool {
        guard let frame = capture.latestFrame, invalidCornerIndices.isEmpty else { return false }
        return table.corners.allSatisfy { screenPoint(for: $0, frame: frame, previewBounds: previewBounds) != nil }
    }
}
