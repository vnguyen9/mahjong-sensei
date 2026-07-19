import ARKit
import DesignSystem
import Recognition
import SceneKit
import SwiftUI
import UIKit
import simd

/// A brief, self-contained ARKit calibration screen shown BEFORE the Coach
/// Live play loop starts.
///
/// This view runs its OWN `ARSession` (a plain `ARWorldTrackingConfiguration`
/// with horizontal plane detection) — it is deliberately independent of
/// `ARTableCapture`/`CoachLiveSession`'s longer-lived play-loop session. The
/// user sees ARKit's default plane visualization (a translucent grey grid on
/// the detected table) plus Apple's stock `ARCoachingOverlayView` onboarding,
/// then places two COARSE marks — the inner edge of their own hand band, and
/// a point on the pond rim — which are converted into a
/// `TrackerConfig.TableGeometry` and handed back to the caller.
///
/// The produced `TableGeometry` carries only orientation-NORMALIZED scalars
/// (`extent`, `handBandDepth`, `pondRadius` — fractions of the table's
/// physical size), so it transfers cleanly into the play loop's own,
/// separately-locked plane regardless of exactly how the user was facing
/// during this screen. Yaw-aligning the calibration plane so its local +z
/// points toward the user (to match `TableCalibrationGeometry`'s doc
/// convention exactly) is left as a device-QA refinement — this screen
/// doesn't need it to produce a usable geometry, since both marks are
/// projected through the SAME plane transform they were captured against.
struct ARCalibrationView: UIViewControllerRepresentable {
    var onComplete: (TrackerConfig.TableGeometry) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ARCalibrationViewController {
        let controller = ARCalibrationViewController()
        controller.onComplete = onComplete
        controller.onCancel = onCancel
        return controller
    }

    /// Nothing to push from SwiftUI-side state — this is a self-contained,
    /// one-shot calibration screen; all its state lives in the view
    /// controller and is surfaced only via `onComplete`/`onCancel`.
    func updateUIViewController(_ uiViewController: ARCalibrationViewController, context: Context) {}
}

/// The real logic behind `ARCalibrationView`. A plain `UIViewController`
/// (rather than a SwiftUI `View`) because it owns an `ARSCNView` +
/// `ARCoachingOverlayView` + tap gesture + `ARSCNViewDelegate`/
/// `ARSessionDelegate` — exactly the surface UIKit's AR types are designed
/// around.
final class ARCalibrationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    var onComplete: ((TrackerConfig.TableGeometry) -> Void)?
    var onCancel: (() -> Void)?

    /// What the next tap/finger-point places. Progresses forward only —
    /// re-marking isn't offered here (this is a coarse, one-pass screen;
    /// getting it exactly right is a device-QA refinement, not this file's
    /// job).
    private enum MarkStage {
        case handBandEdge
        case pondEdge
        case done
    }

    private let sceneView = ARSCNView()
    private let coachingOverlay = ARCoachingOverlayView()
    private let instructionLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let useFingerButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    private var stage: MarkStage = .handBandEdge

    /// The largest currently-tracked horizontal plane — the one taps/finger
    /// points and the final `extentMetres` are read against. Updated (main
    /// thread only) from `renderer(_:didAdd/didUpdate:for:)`.
    private var calibrationPlaneAnchor: ARPlaneAnchor?
    private var planeNodes: [UUID: SCNNode] = [:]

    /// Anchor-local table points (metres, `(x: local x, y: local z)` —
    /// exactly `TableProjection.tablePoint`'s output space), fed straight
    /// into `TableCalibrationGeometry.geometry`.
    private var handBandInnerEdge: SIMD2<Double>?
    private var pondEdge: SIMD2<Double>?
    private var handMarkerNode: SCNNode?
    private var pondMarkerNode: SCNNode?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupCoachingOverlay()
        setupControls()
        updateInstruction()
        updateConfirmButtonState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .none
        sceneView.session.run(configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func setupSceneView() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tap)
    }

    private func setupCoachingOverlay() {
        // Apple's stock "move your phone to find a surface" onboarding —
        // shows/hides itself automatically as `.horizontalPlane` detection
        // progresses, no manual state tracking needed here.
        coachingOverlay.session = sceneView.session
        coachingOverlay.goal = .horizontalPlane
        coachingOverlay.activatesAutomatically = true
        coachingOverlay.frame = view.bounds
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.addSubview(coachingOverlay)
    }

    private func setupControls() {
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center
        instructionLabel.textColor = UIColor(MJColor.creamHeading)
        instructionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        instructionLabel.backgroundColor = UIColor(MJColor.sheetGlass)
        instructionLabel.layer.cornerRadius = 14
        instructionLabel.layer.masksToBounds = true
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(UIColor(MJColor.cream(0.75)), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        useFingerButton.setTitle("Use finger", for: .normal)
        useFingerButton.setTitleColor(UIColor(MJColor.inkOnGold), for: .normal)
        useFingerButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        useFingerButton.backgroundColor = UIColor(MJColor.cream(0.85))
        useFingerButton.layer.cornerRadius = 12
        useFingerButton.addTarget(self, action: #selector(useFingerTapped), for: .touchUpInside)

        confirmButton.setTitle("Use table", for: .normal)
        confirmButton.setTitleColor(UIColor(MJColor.inkOnGold), for: .normal)
        confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        confirmButton.backgroundColor = UIColor(MJColor.gold)
        confirmButton.layer.cornerRadius = 14
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        let bottomStack = UIStackView(arrangedSubviews: [cancelButton, useFingerButton, confirmButton])
        bottomStack.axis = .horizontal
        bottomStack.alignment = .fill
        bottomStack.distribution = .fillEqually
        bottomStack.spacing = 12
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            instructionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            instructionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            instructionLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            bottomStack.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    // MARK: - Instruction text

    private func updateInstruction() {
        switch stage {
        case .handBandEdge:
            instructionLabel.text = "Tap the near edge of your hand — closest to you on the table."
        case .pondEdge:
            instructionLabel.text = "Now tap a point on the edge of the pond, in the middle of the table."
        case .done:
            instructionLabel.text = "Marks placed. Tap \"Use table\" to confirm."
        }
    }

    private func updateConfirmButtonState() {
        // Confirm only needs a locked plane to compute `extentMetres` from —
        // the marks themselves are optional (`TableCalibrationGeometry`
        // falls back to sane defaults for whichever mark is `nil`), matching
        // the screen's "coarse, approximate is fine" spirit.
        let enabled = calibrationPlaneAnchor != nil
        confirmButton.isEnabled = enabled
        confirmButton.alpha = enabled ? 1 : 0.5
    }

    // MARK: - Plane visualization (ARSCNViewDelegate)

    /// Note: `ARSCNViewDelegate` callbacks fire on SceneKit's render thread,
    /// not the main thread. Direct `SCNNode`/`SCNGeometry` edits here are
    /// safe (SceneKit synchronizes scene-graph writes made inside these
    /// callbacks with its own render pass — the standard ARKit sample-code
    /// pattern), but any read/write of plain Swift state this controller
    /// also touches from UIKit callbacks (`calibrationPlaneAnchor`, button
    /// state) is hopped to the main thread explicitly.
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        if let planeNode = makePlaneNode(for: planeAnchor) {
            node.addChildNode(planeNode)
            planeNodes[planeAnchor.identifier] = planeNode
        }
        considerCalibrationPlane(planeAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        if let planeNode = planeNodes[planeAnchor.identifier],
           let planeGeometry = planeNode.geometry as? ARSCNPlaneGeometry {
            planeGeometry.update(from: planeAnchor.geometry)
        }
        considerCalibrationPlane(planeAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
        planeNodes[planeAnchor.identifier] = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.calibrationPlaneAnchor?.identifier == planeAnchor.identifier {
                self.calibrationPlaneAnchor = nil
                self.updateConfirmButtonState()
            }
        }
    }

    /// ARKit's default plane visualization — a translucent grey grid
    /// covering the detected plane's current geometry, via
    /// `ARSCNPlaneGeometry` (the mesh ARKit itself refines as the plane
    /// grows/reshapes), rather than a static `SCNPlane` sized once at
    /// creation.
    private func makePlaneNode(for anchor: ARPlaneAnchor) -> SCNNode? {
        guard let device = sceneView.device,
              let geometry = ARSCNPlaneGeometry(device: device) else { return nil }
        geometry.update(from: anchor.geometry)

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.85, alpha: 0.35)
        material.isDoubleSided = true
        material.lightingModel = .constant
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }

    /// Tracks the largest horizontal plane seen so far as THE calibration
    /// plane — taps/finger-points and the final `extentMetres` all read
    /// against whichever anchor this currently holds.
    private func considerCalibrationPlane(_ anchor: ARPlaneAnchor) {
        let area = Double(anchor.planeExtent.width) * Double(anchor.planeExtent.height)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let current = self.calibrationPlaneAnchor {
                let currentArea = Double(current.planeExtent.width) * Double(current.planeExtent.height)
                if anchor.identifier == current.identifier || area >= currentArea {
                    self.calibrationPlaneAnchor = anchor
                }
            } else {
                self.calibrationPlaneAnchor = anchor
            }
            self.updateConfirmButtonState()
        }
    }

    // MARK: - Marking

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard stage != .done, gesture.state == .ended else { return }
        guard let planeAnchor = calibrationPlaneAnchor else { return }

        let screenPoint = gesture.location(in: sceneView)
        guard let query = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else { return }

        let tablePoint = tablePoint(ofWorldTransform: result.worldTransform, planeAnchor: planeAnchor)
        let worldPosition = SIMD3<Float>(result.worldTransform.columns.3.x,
                                         result.worldTransform.columns.3.y,
                                         result.worldTransform.columns.3.z)
        applyMark(tablePoint, worldPosition: worldPosition)
    }

    /// Secondary/optional marking path: point at the table with an index
    /// finger instead of tapping the screen. Reads the current frame,
    /// detects the fingertip with `HandPoseFingertip`, and raycasts it onto
    /// the calibration plane via `TableProjection` — the same math the live
    /// play loop uses to turn a detection into a table point, just fed a
    /// Vision hand landmark instead of a tile box.
    @objc private func useFingerTapped() {
        guard stage != .done,
              let planeAnchor = calibrationPlaneAnchor,
              let frame = sceneView.session.currentFrame else { return }

        guard let orientedPoint = HandPoseFingertip.indexFingertipOrientedPoint(in: frame.capturedImage) else {
            // No hand found / low confidence — silently ignore; the user can
            // just try again or fall back to tapping.
            return
        }

        let projection = TableProjection(
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: SIMD2<Float>(Float(frame.camera.imageResolution.width),
                                          Float(frame.camera.imageResolution.height)),
            planeTransform: planeAnchor.transform)

        // Portrait swap of the landscape captured-image resolution — see
        // `ARTableFrame.orientedImageSize`'s doc for why this is exactly
        // `(height, width)`.
        let orientedImageSize = SIMD2<Double>(Double(frame.camera.imageResolution.height),
                                              Double(frame.camera.imageResolution.width))

        guard let tablePoint = projection.tablePoint(ofNormalizedOrientedPoint: orientedPoint,
                                                       orientedImageSize: orientedImageSize) else { return }

        let worldHit = planeAnchor.transform * SIMD4<Float>(Float(tablePoint.x), 0, Float(tablePoint.y), 1)
        let worldPosition = SIMD3<Float>(worldHit.x, worldHit.y, worldHit.z)
        applyMark(tablePoint, worldPosition: worldPosition)
    }

    /// Converts a raycast's world-space hit into the calibration plane's
    /// anchor-local `(x, z)` — packed as `SIMD2(x: local x, y: local z)`,
    /// matching `TableProjection.tablePoint`'s own output convention so both
    /// marking paths (tap and finger) land in the exact same space.
    private func tablePoint(ofWorldTransform worldTransform: simd_float4x4, planeAnchor: ARPlaneAnchor) -> SIMD2<Double> {
        let worldHit = SIMD4<Float>(worldTransform.columns.3.x,
                                    worldTransform.columns.3.y,
                                    worldTransform.columns.3.z,
                                    1)
        let local = simd_inverse(planeAnchor.transform) * worldHit
        return SIMD2<Double>(Double(local.x), Double(local.z))
    }

    private func applyMark(_ tablePoint: SIMD2<Double>, worldPosition: SIMD3<Float>) {
        switch stage {
        case .handBandEdge:
            handBandInnerEdge = tablePoint
            placeMarkerNode(&handMarkerNode, at: worldPosition, color: UIColor(MJColor.gold))
            stage = .pondEdge
        case .pondEdge:
            pondEdge = tablePoint
            placeMarkerNode(&pondMarkerNode, at: worldPosition, color: UIColor(MJColor.jadeAccent))
            stage = .done
        case .done:
            break
        }
        updateInstruction()
        updateConfirmButtonState()
    }

    /// Drops (or moves, if already placed) a small coarse dot marker at a
    /// world position — deliberately simple: this screen only needs the
    /// user to see roughly where their mark landed, not a polished 3D asset.
    private func placeMarkerNode(_ node: inout SCNNode?, at worldPosition: SIMD3<Float>, color: UIColor) {
        let position = SCNVector3(worldPosition.x, worldPosition.y, worldPosition.z)
        if let existing = node {
            existing.position = position
        } else {
            let sphere = SCNSphere(radius: 0.015)
            sphere.firstMaterial?.diffuse.contents = color
            sphere.firstMaterial?.lightingModel = .constant
            let markerNode = SCNNode(geometry: sphere)
            markerNode.position = position
            sceneView.scene.rootNode.addChildNode(markerNode)
            node = markerNode
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func confirmTapped() {
        guard let planeAnchor = calibrationPlaneAnchor else { return }
        // `planeExtent` (iOS 16+) over the deprecated `extent` — take the
        // larger dimension as the table's play-axis extent; downstream
        // clamping (`TableCalibrationGeometry.extentRange`) handles anything
        // implausible.
        let extentMetres = Double(max(planeAnchor.planeExtent.width, planeAnchor.planeExtent.height))
        let geometry = TableCalibrationGeometry.geometry(extentMetres: extentMetres,
                                                         handBandInnerEdge: handBandInnerEdge,
                                                         pondEdge: pondEdge)
        onComplete?(geometry)
    }
}
