import ARKit
import DesignSystem
import MahjongCore
import Recognition
import SceneKit
import SwiftUI
import UIKit
import simd

/// The multi-stage ARKit calibration screen shown BEFORE the Coach Live play
/// loop starts (spec screens 2–7). It renders and raycasts through the exact
/// `ARSession` owned by `ARTableCapture`; it never runs, pauses, resets, or
/// replaces that session.
///
/// The user sees ARKit's default plane grid + Apple's `ARCoachingOverlayView`
/// onboarding, then:
///   1. **marks their hand row** by dropping two posts (pinch or tap) at each
///      end of their tiles,
///   2. **marks the pond** with two opposite corners,
///   3. **reviews and directly adjusts** the resulting pond-adjacent regions,
/// which are converted into the canonical `WorldTableCalibration` shared by
/// census ownership, ROI planning, and overlays.
struct ARCalibrationView: UIViewControllerRepresentable {
    let capture: ARTableCapture
    /// The user's seat wind (from the setup card), used to label the seats.
    var mySeatWind: Wind = .east
    var onComplete: (WorldTableCalibration) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ARCalibrationViewController {
        let controller = ARCalibrationViewController(capture: capture)
        controller.mySeatWind = mySeatWind
        controller.onComplete = onComplete
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: ARCalibrationViewController, context: Context) {
        uiViewController.mySeatWind = mySeatWind
    }
}

/// The real logic behind `ARCalibrationView`. A `UIViewController` (rather than
/// a SwiftUI `View`) because it owns an `ARSCNView` + `ARCoachingOverlayView` +
/// tap gesture + `ARSCNViewDelegate`/`ARSessionDelegate`.
final class ARCalibrationViewController: UIViewController, ARSCNViewDelegate {
    var mySeatWind: Wind = .east
    var onComplete: ((WorldTableCalibration) -> Void)?
    var onCancel: (() -> Void)?
    private let capture: ARTableCapture

    /// Internal point-placement substages back the three user-visible steps.
    enum MarkStage: Int {
        case handPostA     // left end of my row
        case handPostB     // right end of my row
        case pondCornerA   // one corner of the discard pile
        case pondCornerB   // the opposite corner → an oriented pond rectangle
        case review        // direct edit + confirm

        /// Grouped 1-based step for the three-step calibration flow.
        var displayStep: Int {
            switch self {
            case .handPostA, .handPostB: return 1
            case .pondCornerA, .pondCornerB: return 2
            case .review: return 3
            }
        }
    }

    private let sceneView = ARSCNView()
    private let coachingOverlay = ARCoachingOverlayView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stepLabel = UILabel()
    private let cardView = UIView()
    private let backButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private let playerLegendLabel = UILabel()
    private let playerLegendIcon = UIImageView()
    /// Torch toggle (top-right) — dim rooms make the tiles hard to read during
    /// calibration. Reuses the shared `CameraTorch` (same back camera as live).
    private let flashButton = UIButton(type: .system)
    private var torchOn = false

    private var stage: MarkStage = .handPostA

    /// The largest currently-tracked horizontal plane.
    private var calibrationPlaneAnchor: ARPlaneAnchor?
    private var planeNodes: [UUID: SCNNode] = [:]

    /// Anchor-local table points (metres, `(x: local x, y: local z)`), fed into
    /// `TableCalibrationGeometry.geometry`.
    private var handPostA: SIMD2<Double>?
    private var handPostB: SIMD2<Double>?
    private var pondCornerA: SIMD2<Double>?
    private var pondCornerB: SIMD2<Double>?
    private var handMarkerA: SCNNode?
    private var handMarkerB: SCNNode?
    private var bandNode: SCNNode?
    private var pondMarkerA: SCNNode?
    private var pondMarkerB: SCNNode?
    private var pondRectNode: SCNNode?

    // Four directly draggable pond corners, used during review to refine the
    // two-corner pond mark without a second edit mode.
    private var pondQuad: [SIMD2<Double>] = []
    private var pondQuadMarkers: [SCNNode?] = [nil, nil, nil, nil]
    private var pondQuadFillNode: SCNNode?

    /// Opponent seat midpoints (anchor-local metres, `.left`/`.right`/`.across`
    /// only — the user's own `.me` seat is the hand row) draggable during
    /// review, and their 3D marker nodes.
    private var seatMidpoints: [RelativeSeat: SIMD2<Double>] = [:]
    private var seatMarkers: [RelativeSeat: SCNNode] = [:]

    /// A single draggable review handle — either hand post, a pond
    /// quad corner (by index), or an opponent seat.
    private enum EditHandle: Equatable {
        case handA, handB, handRegion, pond(Int), pondRegion, seat(RelativeSeat)
    }
    private var grabbedHandle: EditHandle?
    /// The table-local difference between a finger and the grabbed handle's
    /// anchor. Retaining it avoids snapping a region's center under the finger
    /// when a direct drag begins.
    private var directDragOffset: SIMD2<Double>?
    /// Filled, oriented review polygons and their text labels. Every node uses
    /// the final `WorldTableCalibration` transform, never a plane extent.
    private var reviewRegionNodes: [SCNNode] = []

    // Live hand-pose pinch marking (no button): a ghost tile follows the
    // fingertip; a pinch (thumb+index close) drops the next tile and advances,
    // and pinching a placed tile grabs it to move.
    private var hoverNode: SCNNode?
    private var hoverStyleKey: String?
    private var lastPinchSampleAt: TimeInterval = 0
    private var pinchInferenceInFlight = false
    private var pinchDisplayLink: CADisplayLink?
    /// Hysteresis so a loose/near hand never counts as a pinch: engage only
    /// below `pinchEnterGap`, release only above `pinchReleaseGap` (oriented-
    /// normalized units). Tunable on device.
    private var isPinchEngaged = false
    private let pinchEnterGap: Double = 0.030
    private let pinchReleaseGap: Double = 0.060
    /// Which placed post the current pinch is dragging, and whether this pinch
    /// created a NEW post (→ advance the stage on release) vs. grabbed an
    /// existing one to move (→ stay).
    private enum WhichPost { case handA, handB, pondA, pondB }
    private var grabbedPost: WhichPost?
    private var grabIsNewPlacement = false
    /// A pinch within this table-space radius (metres) of a placed post grabs
    /// it to move instead of creating a new one.
    private let grabRadius: Double = 0.06
    /// The representative tile face shown on the 3D markers.
    private let markerTile: Tile = .p(5)
    private static var tileTextureCache: [String: UIImage] = [:]

    init(capture: ARTableCapture) {
        self.capture = capture
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sceneView.session = capture.sharedSession
        setupSceneView()
        setupCoachingOverlay()
        setupControls()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        publishInterfaceOrientation()
        seedCalibrationPlaneFromCurrentFrame()
        let link = CADisplayLink(target: self, selector: #selector(samplePinchFrame))
        link.add(to: .main, forMode: .common)
        pinchDisplayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if torchOn { CameraTorch.set(false); torchOn = false }
        pinchDisplayLink?.invalidate()
        pinchDisplayLink = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        publishInterfaceOrientation()
    }

    private func publishInterfaceOrientation() {
        let orientation =
            view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        capture.updateImageOrientation(orientation.cameraImageOrientation)
    }

    // MARK: - Setup

    private func setupSceneView() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        // A deliberate drag must never also become the tap fallback when it
        // ends. Hand-pose pinch remains independent of UIKit gestures.
        tap.require(toFail: pan)
        sceneView.addGestureRecognizer(tap)
        sceneView.addGestureRecognizer(pan)
    }

    private func setupCoachingOverlay() {
        coachingOverlay.session = sceneView.session
        coachingOverlay.goal = .horizontalPlane
        coachingOverlay.activatesAutomatically = true
        coachingOverlay.frame = view.bounds
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.addSubview(coachingOverlay)
    }

    private func setupControls() {
        // Instruction card (top).
        cardView.backgroundColor = UIColor(MJColor.sheetGlass)
        cardView.layer.cornerRadius = 16
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)

        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.textColor = UIColor(MJColor.creamHeading)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = UIColor(MJColor.cream(0.7))
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true

        stepLabel.textAlignment = .center
        stepLabel.textColor = UIColor(MJColor.gold(0.85))
        stepLabel.font = .preferredFont(forTextStyle: .caption1)
        stepLabel.adjustsFontForContentSizeCategory = true

        let cardStack = UIStackView(arrangedSubviews: [stepLabel, titleLabel, subtitleLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 4
        cardStack.alignment = .fill
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardStack)

        // Bottom controls.
        styleSecondary(backButton, title: "Back")
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.accessibilityLabel = "Back"
        backButton.accessibilityHint = "Returns to the previous calibration step."

        stylePill(primaryButton, title: "Confirm", background: MJColor.gold)
        primaryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.accessibilityLabel = "Confirm and start"
        primaryButton.accessibilityHint = "Uses the reviewed hand, pond, and player regions to start tracking."

        let bottomStack = UIStackView(arrangedSubviews: [backButton, primaryButton])
        bottomStack.axis = .horizontal
        bottomStack.alignment = .fill
        bottomStack.distribution = .fillEqually
        bottomStack.spacing = 12
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        playerLegendLabel.numberOfLines = 0
        playerLegendLabel.textAlignment = .center
        playerLegendLabel.textColor = UIColor(MJColor.creamHeading)
        playerLegendLabel.font = .preferredFont(forTextStyle: .footnote)
        playerLegendLabel.adjustsFontForContentSizeCategory = true
        playerLegendLabel.text = "Player marker — drag to the center of their exposed tiles."
        playerLegendLabel.backgroundColor = UIColor(MJColor.sheetGlass)
        playerLegendLabel.layer.cornerRadius = 12
        playerLegendLabel.layer.masksToBounds = true
        playerLegendLabel.isHidden = true
        playerLegendLabel.translatesAutoresizingMaskIntoConstraints = false
        playerLegendLabel.accessibilityLabel = "Player marker. Drag to the center of their exposed tiles."
        view.addSubview(playerLegendLabel)

        playerLegendIcon.image = UIImage(systemName: "person.fill")
        playerLegendIcon.tintColor = .systemOrange
        playerLegendIcon.contentMode = .scaleAspectFit
        playerLegendIcon.isAccessibilityElement = false
        playerLegendIcon.isHidden = true
        playerLegendIcon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerLegendIcon)

        // Flash toggle (top-right). Hidden if the device has no torch.
        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.tintColor = UIColor(MJColor.creamHeading)
        flashButton.backgroundColor = UIColor(MJColor.sheetGlass)
        flashButton.layer.cornerRadius = 22
        flashButton.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        flashButton.isHidden = !CameraTorch.isAvailable
        flashButton.accessibilityLabel = "Toggle flash"
        flashButton.accessibilityHint = "Improves table visibility during calibration."
        view.addSubview(flashButton)

        NSLayoutConstraint.activate([
            flashButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            flashButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            flashButton.widthAnchor.constraint(equalToConstant: 44),
            flashButton.heightAnchor.constraint(equalToConstant: 44),

            cardView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            bottomStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            bottomStack.heightAnchor.constraint(equalToConstant: 50),

            playerLegendLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            playerLegendLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            playerLegendLabel.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -14),
            playerLegendLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            playerLegendIcon.leadingAnchor.constraint(equalTo: playerLegendLabel.leadingAnchor, constant: 12),
            playerLegendIcon.centerYAnchor.constraint(equalTo: playerLegendLabel.centerYAnchor),
            playerLegendIcon.widthAnchor.constraint(equalToConstant: 20),
            playerLegendIcon.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func styleSecondary(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor(MJColor.cream(0.75)), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    }

    private func stylePill(_ button: UIButton, title: String, background: Color) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor(MJColor.inkOnGold), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.backgroundColor = UIColor(background)
        button.layer.cornerRadius = 14
    }

    // MARK: - UI state

    private func refreshUI() {
        let plane = calibrationPlaneAnchor != nil
        stepLabel.text = "STEP \(stage.displayStep) OF 3"

        // Marking stages advance on a tap or pinch — review is the only
        // confirmation screen, so there is no hidden fourth step.
        let marking: Bool
        switch stage {
        case .handPostA, .handPostB:
            marking = true
            titleLabel.text = "Mark your hand row"
            subtitleLabel.text = plane
                ? "Tap or pinch one end of your tiles, then the other."
                : "Move the iPad to find the table first."
        case .pondCornerA, .pondCornerB:
            marking = true
            titleLabel.text = "Mark the pond"
            subtitleLabel.text = "Tap or pinch two opposite corners of the discard area."
        case .review:
            marking = false
            titleLabel.text = "Review your table"
            subtitleLabel.text = "Move the iPad slightly. Drag any labeled region that does not line up."
            primaryButton.setTitle("Confirm & Start", for: .normal)
        }

        backButton.setTitle(stage == .handPostA ? "Cancel" : "Back", for: .normal)
        playerLegendLabel.isHidden = stage != .review
        playerLegendIcon.isHidden = stage != .review
        primaryButton.isHidden = marking
        primaryButton.isEnabled = plane
        primaryButton.alpha = plane ? 1 : 0.45
    }

    // MARK: - Plane visualization (ARSCNViewDelegate)

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
                self.refreshUI()
            }
        }
    }

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

    private func considerCalibrationPlane(_ anchor: ARPlaneAnchor) {
        if let lockedID = capture.lockedPlaneIdentifier,
           anchor.identifier != lockedID {
            return
        }
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
            self.refreshUI()
        }
    }

    private func seedCalibrationPlaneFromCurrentFrame() {
        let planes = sceneView.session.currentFrame?.anchors.compactMap { $0 as? ARPlaneAnchor } ?? []
        if let lockedID = capture.lockedPlaneIdentifier,
           let locked = planes.first(where: { $0.identifier == lockedID }) {
            considerCalibrationPlane(locked)
        } else if let largest = planes.max(by: {
            $0.planeExtent.width * $0.planeExtent.height
                < $1.planeExtent.width * $1.planeExtent.height
        }) {
            considerCalibrationPlane(largest)
        }
    }

    // MARK: - Marking (tap fallback)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let screenPoint = gesture.location(in: sceneView)
        guard let (tablePoint, worldPosition) = raycastTablePoint(at: screenPoint) else { return }
        // Review mode: a tap moves the nearest handle (hand post, pond corner,
        // or player marker) to it — tap fallback for the pinch-drag, allowed beyond
        // `grabRadius` since a tap is deliberate.
        if stage == .review {
            if let h = nearestEditHandle(to: tablePoint, withinRadius: false) {
                moveEditHandle(h, to: tablePoint)
                lightImpact()
            }
            return
        }
        placeAndAdvance(tablePoint, worldPosition: worldPosition)
    }

    /// Direct finger drag for the review screen. Unlike the Vision hand-pose
    /// pinch, this is a normal UIKit gesture and works immediately on iPad.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard stage == .review else { return }
        let screenPoint = gesture.location(in: sceneView)
        let hit = raycastTablePoint(at: screenPoint)

        switch gesture.state {
        case .began:
            guard let (tablePoint, _) = hit else { return }
            let handle = reviewRegionHandle(containing: tablePoint)
                ?? nearestEditHandle(to: tablePoint, withinRadius: true)
            guard let handle, let anchor = reviewHandleAnchor(handle) else { return }
            grabbedHandle = handle
            directDragOffset = anchor - tablePoint
        case .changed:
            guard let (tablePoint, _) = hit,
                  let handle = grabbedHandle else { return }
            moveEditHandle(handle, to: tablePoint + (directDragOffset ?? .zero))
        case .ended, .cancelled, .failed:
            let movedHandle = grabbedHandle
            grabbedHandle = nil
            directDragOffset = nil
            if movedHandle != nil { lightImpact() }
            refreshUI()
        default:
            break
        }
    }

    private func raycastTablePoint(at screenPoint: CGPoint) -> (SIMD2<Double>, SIMD3<Float>)? {
        guard let planeAnchor = calibrationPlaneAnchor,
              let query = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else { return nil }
        let tablePoint = tablePoint(ofWorldTransform: result.worldTransform, planeAnchor: planeAnchor)
        let worldPosition = SIMD3<Float>(result.worldTransform.columns.3.x,
                                         result.worldTransform.columns.3.y,
                                         result.worldTransform.columns.3.z)
        return (tablePoint, worldPosition)
    }

    private func dist2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    // MARK: - Live pinch

    /// Continuous hand-pose sampling (~10 Hz, off-main) while placing marks: a
    /// ghost tile follows the fingertip and a pinch places/moves the current
    /// post. This is the iOS equivalent of visionOS hand tracking — Vision's
    /// `VNDetectHumanHandPoseRequest`, run only during calibration (bounded
    /// cost). No "Pinch" button.
    @objc private func samplePinchFrame() {
        guard let frame = sceneView.session.currentFrame else { return }
        // Sampling stays live through the review, so a pinch can
        // still GRAB a placed tile to nudge it — new tiles are only created in
        // the marking stages (`postForCurrentStage`), so review can't add posts.
        guard let planeAnchor = calibrationPlaneAnchor else { hideHover(); return }
        guard !pinchInferenceInFlight, frame.timestamp - lastPinchSampleAt >= 0.1 else { return }
        lastPinchSampleAt = frame.timestamp
        pinchInferenceInFlight = true

        let pixelBuffer = frame.capturedImage
        let cameraTransform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let planeTransform = planeAnchor.transform
        let imageOrientation = (
            view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        ).cameraImageOrientation

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sample = HandPoseFingertip.pinch(
                in: pixelBuffer,
                orientation: imageOrientation
            )
            var tablePoint: SIMD2<Double>?
            if let point = sample?.point {
                let projection = TableProjection(
                    cameraTransform: cameraTransform,
                    intrinsics: intrinsics,
                    imageResolution: SIMD2<Float>(Float(resolution.width), Float(resolution.height)),
                    planeTransform: planeTransform)
                let transform = FrameImageTransform(
                    imageOrientation: imageOrientation,
                    imageResolution: resolution
                )
                tablePoint = projection.tablePoint(
                    ofNormalizedOrientedPoint: point,
                    imageTransform: transform
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pinchInferenceInFlight = false
                self.handlePinchSample(sample, tablePoint: tablePoint, planeTransform: planeTransform)
            }
        }
    }

    private func handlePinchSample(_ sample: HandPoseFingertip.PinchSample?,
                                   tablePoint: SIMD2<Double>?, planeTransform: simd_float4x4) {
        guard let sample, let tablePoint else {
            if isPinchEngaged { isPinchEngaged = false; grabbedPost = nil; grabbedHandle = nil }  // hand lost mid-drag
            hideHover()
            return
        }
        let world4 = planeTransform * SIMD4<Float>(Float(tablePoint.x), 0, Float(tablePoint.y), 1)
        let worldPosition = SIMD3<Float>(world4.x, world4.y, world4.z)

        // Edge-detected pinch with hysteresis — a loose/near hand never counts.
        if !isPinchEngaged, sample.gap <= pinchEnterGap {
            isPinchEngaged = true
            if stage == .review {
                grabbedHandle = nearestEditHandle(to: tablePoint)
                if let h = grabbedHandle { moveEditHandle(h, to: tablePoint) }
            } else { beginGrab(at: tablePoint, worldPosition: worldPosition) }
        } else if isPinchEngaged, sample.gap >= pinchReleaseGap {
            isPinchEngaged = false
            if stage == .review {
                if grabbedHandle != nil { lightImpact() }
                grabbedHandle = nil
                refreshUI()
            }
            else { endGrab() }
        }

        if isPinchEngaged {
            hideHover()
            if stage == .review {
                if let h = grabbedHandle { moveEditHandle(h, to: tablePoint) }
            } else if let grabbedPost {
                setPost(grabbedPost, tablePoint: tablePoint, worldPosition: worldPosition)
            }
        } else if postForCurrentStage() != nil {
            updateHover(at: worldPosition)   // ghost follows the finger only when a new tile can drop
        } else {
            hideHover()                      // review: pinch moves existing markers, no ghost
        }
    }

    // MARK: - Review (hand posts + pond quad + player markers)

    /// Turns the two pond points into a directly editable quad, seeds the
    /// nearby opponent player markers from the canonical guided calibration,
    /// and shows the same geometry that will be used in Live.
    private func enterReview() {
        guard calibrationPlaneAnchor != nil else { return }
        if pondQuad.count != 4 { pondQuad = seededPondQuad() }
        pondMarkerA?.isHidden = true
        pondMarkerB?.isHidden = true
        pondRectNode?.isHidden = true
        for i in 0..<4 { placeQuadMarker(i) }
        updatePondQuadFill()
        seedSeatMidpointsIfNeeded()
        for seat: RelativeSeat in [.left, .right, .across] { placeSeatMarker(seat) }
        stage = .review
        refreshReviewGeometry()
        refreshUI()
    }

    /// Returns to step 2 without discarding any hand or pond marks. The review
    /// affordances disappear, but a subsequent review restores the edited quad.
    private func leaveReviewForPondMarking() {
        clearReviewGeometry()
        for i in pondQuadMarkers.indices { pondQuadMarkers[i]?.isHidden = true }
        for seat in seatMarkers.keys { seatMarkers[seat]?.isHidden = true }
        pondMarkerA?.isHidden = false
        pondMarkerB?.isHidden = false
        updatePondRectNode()
        stage = .pondCornerB
    }

    /// The 4 local-metre corners to start refining from: the current 2-corner
    /// rect's corners, or a small default box around the pond centre.
    private func seededPondQuad() -> [SIMD2<Double>] {
        if let a = pondCornerA, let b = pondCornerB {
            let minX = Swift.min(a.x, b.x), maxX = Swift.max(a.x, b.x)
            let minZ = Swift.min(a.y, b.y), maxZ = Swift.max(a.y, b.y)
            return [SIMD2(minX, minZ), SIMD2(maxX, minZ), SIMD2(maxX, maxZ), SIMD2(minX, maxZ)]
        }
        let c = pondCornerA ?? pondCornerB ?? SIMD2(0, 0)
        let r = 0.12
        return [SIMD2(c.x - r, c.y - r), SIMD2(c.x + r, c.y - r),
                SIMD2(c.x + r, c.y + r), SIMD2(c.x - r, c.y + r)]
    }

    /// Seeds the three draggable player-marker centers from the same guided
    /// calibration geometry that Live will use. They intentionally sit just
    /// outside the marked pond, never at the outer extent of ARKit's (often
    /// much larger) detected plane. Returning to review preserves a drag.
    private func seedSeatMidpointsIfNeeded() {
        guard seatMidpoints.isEmpty,
              let planeAnchor = calibrationPlaneAnchor,
              let handPostA,
              let handPostB,
              let pondCornerA,
              let pondCornerB else { return }

        let markedPond = pondQuad.count == 4 ? pondQuad : [
            SIMD2(pondCornerA.x, pondCornerA.y),
            SIMD2(pondCornerB.x, pondCornerA.y),
            SIMD2(pondCornerB.x, pondCornerB.y),
            SIMD2(pondCornerA.x, pondCornerB.y),
        ]
        let marks = GuidedTableMarks(
            planeTransform: planeAnchor.transform,
            handEndpoints: (
                SIMD2(Float(handPostA.x), Float(handPostA.y)),
                SIMD2(Float(handPostB.x), Float(handPostB.y))
            ),
            pondPolygon: markedPond.map { SIMD2(Float($0.x), Float($0.y)) }
        )
        guard let calibration = WorldTableCalibration.guided(marks: marks) else {
            return
        }

        let inversePlane = simd_inverse(planeAnchor.transform)
        func planeLocalCenter(for zone: SemanticZoneID) -> SIMD2<Double>? {
            guard let polygon = calibration.revealedZonePolygons[zone],
                  !polygon.isEmpty else { return nil }
            let tableCenter = polygon.reduce(SIMD2<Float>.zero, +)
                / Float(polygon.count)
            let world = calibration.tableToWorld * SIMD4(
                tableCenter.x, 0, tableCenter.y, 1
            )
            let planeLocal = inversePlane * world
            return SIMD2(Double(planeLocal.x), Double(planeLocal.z))
        }

        seatMidpoints[.left] = planeLocalCenter(for: .tableRevealedLeft)
        seatMidpoints[.right] = planeLocalCenter(for: .tableRevealedRight)
        seatMidpoints[.across] = planeLocalCenter(for: .tableRevealedFar)
    }

    /// Every draggable handle's current table point, for `nearestEditHandle`.
    private func editHandlePoints() -> [(EditHandle, SIMD2<Double>)] {
        var points: [(EditHandle, SIMD2<Double>)] = []
        if let a = handPostA { points.append((.handA, a)) }
        if let b = handPostB { points.append((.handB, b)) }
        for i in pondQuad.indices { points.append((.pond(i), pondQuad[i])) }
        for (seat, m) in seatMidpoints { points.append((.seat(seat), m)) }
        return points
    }

    /// The nearest handle to `p`. `withinRadius` (pinch engage) restricts to
    /// `grabRadius`; a tap fallback (`withinRadius: false`) always finds the
    /// globally-nearest handle, since a tap is deliberate.
    private func nearestEditHandle(to p: SIMD2<Double>, withinRadius: Bool = true) -> EditHandle? {
        // A deliberate tap on a label/fill moves that *whole* region. Pinches
        // remain marker-centric, avoiding accidental region translations.
        if !withinRadius, let region = reviewRegionHandle(containing: p) {
            return region
        }
        var best: (EditHandle, Double)?
        for (h, tp) in editHandlePoints() {
            let d = dist2(p, tp).squareRoot()
            if withinRadius && d > grabRadius { continue }
            if best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    private func reviewRegionHandle(containing planePoint: SIMD2<Double>) -> EditHandle? {
        guard let planeAnchor = calibrationPlaneAnchor,
              let calibration = currentCalibration() else { return nil }
        let world = planeAnchor.transform * SIMD4<Float>(Float(planePoint.x), 0, Float(planePoint.y), 1)
        let table = simd_inverse(calibration.tableToWorld) * world
        let tablePoint = SIMD2<Float>(table.x, table.z)
        if polygon(calibration.handPolygon, contains: tablePoint) { return .handRegion }
        if polygon(calibration.pondPolygon, contains: tablePoint) { return .pondRegion }
        let seats: [(SemanticZoneID, RelativeSeat)] = [
            (.tableRevealedLeft, .left),
            (.tableRevealedFar, .across),
            (.tableRevealedRight, .right),
        ]
        for (zone, seat) in seats {
            if let region = calibration.revealedZonePolygons[zone], polygon(region, contains: tablePoint) {
                return .seat(seat)
            }
        }
        return nil
    }

    private func reviewHandleAnchor(_ handle: EditHandle) -> SIMD2<Double>? {
        switch handle {
        case .handA: return handPostA
        case .handB: return handPostB
        case .handRegion:
            guard let a = handPostA, let b = handPostB else { return nil }
            return (a + b) / 2
        case let .pond(index):
            return pondQuad.indices.contains(index) ? pondQuad[index] : nil
        case .pondRegion:
            guard !pondQuad.isEmpty else { return nil }
            return pondQuad.reduce(SIMD2<Double>.zero, +) / Double(pondQuad.count)
        case let .seat(seat):
            return seatMidpoints[seat]
        }
    }

    private func polygon(_ polygon: [SIMD2<Float>], contains point: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var contains = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                contains.toggle()
            }
            j = i
        }
        return contains
    }

    /// Moves the given handle to `tablePoint` and updates its 3D marker(s).
    private func moveEditHandle(_ h: EditHandle, to tablePoint: SIMD2<Double>) {
        switch h {
        case .handA:
            setPost(.handA, tablePoint: tablePoint, worldPosition: worldFromLocal(tablePoint))
        case .handB:
            setPost(.handB, tablePoint: tablePoint, worldPosition: worldFromLocal(tablePoint))
        case .handRegion:
            moveHandRegion(to: tablePoint)
        case let .pond(i):
            setQuadCorner(i, tablePoint: tablePoint)
        case .pondRegion:
            movePondRegion(to: tablePoint)
        case let .seat(seat):
            seatMidpoints[seat] = tablePoint
            placeSeatMarker(seat)
        }
        refreshReviewGeometry()
    }

    private func moveHandRegion(to center: SIMD2<Double>) {
        guard let a = handPostA, let b = handPostB else { return }
        let previousCenter = (a + b) / 2
        let delta = center - previousCenter
        setPost(.handA, tablePoint: a + delta, worldPosition: worldFromLocal(a + delta))
        setPost(.handB, tablePoint: b + delta, worldPosition: worldFromLocal(b + delta))
    }

    private func movePondRegion(to center: SIMD2<Double>) {
        if pondQuad.count != 4 { pondQuad = seededPondQuad() }
        let previousCenter = pondQuad.reduce(SIMD2<Double>.zero, +) / Double(pondQuad.count)
        let delta = center - previousCenter
        for i in pondQuad.indices { setQuadCorner(i, tablePoint: pondQuad[i] + delta) }
        // The two original marks are retained for Back → step 2 and updated
        // from the translated quad's bounds so they continue to describe it.
        let minX = pondQuad.map(\.x).min() ?? center.x
        let maxX = pondQuad.map(\.x).max() ?? center.x
        let minZ = pondQuad.map(\.y).min() ?? center.y
        let maxZ = pondQuad.map(\.y).max() ?? center.y
        pondCornerA = SIMD2(minX, minZ)
        pondCornerB = SIMD2(maxX, maxZ)
    }

    /// An amber person icon over a ring makes an opponent marker legible as a
    /// player location rather than another tile or a generic calibration dot.
    private func makeSeatMarkerNode() -> SCNNode {
        let root = SCNNode()

        let ring = SCNTorus(ringRadius: 0.018, pipeRadius: 0.003)
        let ringMaterial = SCNMaterial()
        ringMaterial.diffuse.contents = UIColor(MJColor.gold)
        ringMaterial.lightingModel = .constant
        ring.materials = [ringMaterial]
        root.addChildNode(SCNNode(geometry: ring))

        let icon = SCNPlane(width: 0.035, height: 0.035)
        let iconMaterial = SCNMaterial()
        iconMaterial.diffuse.contents = UIImage(systemName: "person.fill")?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        iconMaterial.lightingModel = .constant
        iconMaterial.isDoubleSided = true
        iconMaterial.writesToDepthBuffer = false
        icon.materials = [iconMaterial]
        let iconNode = SCNNode(geometry: icon)
        iconNode.position = SCNVector3(0, 0.024, 0)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        iconNode.constraints = [billboard]
        root.addChildNode(iconNode)
        return root
    }

    /// Creates (or moves) the 3D marker for `seat` at its current
    /// `seatMidpoints` entry, lifted slightly off the plane.
    private func placeSeatMarker(_ seat: RelativeSeat) {
        guard let m = seatMidpoints[seat] else { return }
        let world = worldFromLocal(m)
        let position = SCNVector3(world.x, world.y + 0.012, world.z)
        if let existing = seatMarkers[seat] {
            existing.position = position
        } else {
            let node = makeSeatMarkerNode()
            node.position = position
            sceneView.scene.rootNode.addChildNode(node)
            seatMarkers[seat] = node
        }
        seatMarkers[seat]?.isHidden = false
    }

    private func setQuadCorner(_ i: Int, tablePoint: SIMD2<Double>) {
        guard pondQuad.indices.contains(i) else { return }
        pondQuad[i] = tablePoint
        placeQuadMarker(i)
        updatePondQuadFill()
    }

    private func placeQuadMarker(_ i: Int) {
        guard pondQuad.indices.contains(i) else { return }
        let world = worldFromLocal(pondQuad[i])
        placeTileMarker(&pondQuadMarkers[i], at: world, theme: .jade,
                        body: UIColor(MJColor.jadeAccent), key: "jade", standing: false)
        pondQuadMarkers[i]?.isHidden = false
    }

    private func clearQuadNodes() {
        for i in pondQuadMarkers.indices { pondQuadMarkers[i]?.removeFromParentNode(); pondQuadMarkers[i] = nil }
        pondQuadFillNode?.removeFromParentNode(); pondQuadFillNode = nil
    }

    /// A flat translucent jade polygon over the 4 pond-quad corners, built in
    /// the plane's local frame then transformed into world space.
    private func updatePondQuadFill() {
        pondQuadFillNode?.removeFromParentNode()
        pondQuadFillNode = nil
        guard pondQuad.count == 4, let planeAnchor = calibrationPlaneAnchor else { return }
        let verts = pondQuad.map { SCNVector3(Float($0.x), 0.001, Float($0.y)) }
        let source = SCNGeometrySource(vertices: verts)
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(MJColor.jadeAccent)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geo.materials = [material]
        let node = SCNNode(geometry: geo)
        node.opacity = 0.3
        node.renderingOrder = -1
        node.simdTransform = planeAnchor.transform
        sceneView.scene.rootNode.addChildNode(node)
        pondQuadFillNode = node
    }

    /// Builds the exact input consumed by the guided-calibration factory. This
    /// is deliberately shared by review rendering and `complete()` so preview,
    /// editable player markers, and the saved calibration cannot diverge.
    private func currentGuidedMarks() -> GuidedTableMarks? {
        guard let planeAnchor = calibrationPlaneAnchor,
              let handPostA,
              let handPostB,
              let pondCornerA,
              let pondCornerB else { return nil }
        let markedPond = pondQuad.count == 4 ? pondQuad : [
            SIMD2(pondCornerA.x, pondCornerA.y),
            SIMD2(pondCornerB.x, pondCornerA.y),
            SIMD2(pondCornerB.x, pondCornerB.y),
            SIMD2(pondCornerA.x, pondCornerB.y),
        ]
        let seatZones = Dictionary(uniqueKeysWithValues: seatMidpoints.compactMap {
            seat, point -> (SemanticZoneID, SIMD2<Float>)? in
            let zone: SemanticZoneID
            switch seat {
            case .left: zone = .tableRevealedLeft
            case .across: zone = .tableRevealedFar
            case .right: zone = .tableRevealedRight
            case .me: return nil
            }
            return (zone, SIMD2(Float(point.x), Float(point.y)))
        })
        return GuidedTableMarks(
            planeTransform: planeAnchor.transform,
            handEndpoints: (
                SIMD2(Float(handPostA.x), Float(handPostA.y)),
                SIMD2(Float(handPostB.x), Float(handPostB.y))
            ),
            pondPolygon: markedPond.map { SIMD2(Float($0.x), Float($0.y)) },
            revealedZoneCenters: seatZones
        )
    }

    private func currentCalibration() -> WorldTableCalibration? {
        guard let marks = currentGuidedMarks() else { return nil }
        return WorldTableCalibration.guided(marks: marks)
    }

    /// Renders filled regions and names in *calibration table coordinates*.
    /// They are therefore a live proof of the transform that will be persisted,
    /// not a second scalar/plane-extent approximation.
    private func refreshReviewGeometry() {
        clearReviewGeometry()
        guard stage == .review, let calibration = currentCalibration() else { return }
        let regions: [(String, [SIMD2<Float>], UIColor)] = [
            ("Your hand", calibration.handPolygon, UIColor(MJColor.gold)),
            ("Pond", calibration.pondPolygon, UIColor(MJColor.jadeAccent)),
            ("Left player · exposed tiles", calibration.revealedZonePolygons[.tableRevealedLeft] ?? [], .systemOrange),
            ("Across player · exposed tiles", calibration.revealedZonePolygons[.tableRevealedFar] ?? [], .systemOrange),
            ("Right player · exposed tiles", calibration.revealedZonePolygons[.tableRevealedRight] ?? [], .systemOrange),
        ]
        for (name, polygon, color) in regions where polygon.count >= 3 {
            let node = makeReviewRegionNode(name: name, polygon: polygon, color: color)
            node.simdTransform = calibration.tableToWorld
            sceneView.scene.rootNode.addChildNode(node)
            reviewRegionNodes.append(node)
        }
    }

    private func clearReviewGeometry() {
        reviewRegionNodes.forEach { $0.removeFromParentNode() }
        reviewRegionNodes.removeAll()
    }

    private func makeReviewRegionNode(name: String, polygon: [SIMD2<Float>], color: UIColor) -> SCNNode {
        let root = SCNNode()
        let vertices = polygon.map { SCNVector3($0.x, 0.003, $0.y) }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = (1..<(polygon.count - 1)).flatMap { [Int32(0), Int32($0), Int32($0 + 1)] }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        let fill = SCNNode(geometry: geometry)
        fill.opacity = 0.18
        fill.renderingOrder = -2
        root.addChildNode(fill)

        let centroid = polygon.reduce(SIMD2<Float>.zero, +) / Float(polygon.count)
        let text = SCNText(string: name, extrusionDepth: 0.001)
        text.font = UIFont.preferredFont(forTextStyle: .caption2)
        text.flatness = 0.2
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = UIColor(MJColor.creamHeading)
        textMaterial.lightingModel = .constant
        text.materials = [textMaterial]
        let label = SCNNode(geometry: text)
        label.scale = SCNVector3(0.0012, 0.0012, 0.0012)
        label.position = SCNVector3(centroid.x, 0.018, centroid.y)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        label.constraints = [billboard]
        root.addChildNode(label)
        return root
    }

    private func worldFromLocal(_ p: SIMD2<Double>) -> SIMD3<Float> {
        let t = calibrationPlaneAnchor?.transform ?? matrix_identity_float4x4
        let w = t * SIMD4<Float>(Float(p.x), 0, Float(p.y), 1)
        return SIMD3<Float>(w.x, w.y, w.z)
    }

    /// Pinch-down: grab the nearest placed post within `grabRadius` to move it,
    /// else create a new post for the current stage at the pinch point.
    private func beginGrab(at tablePoint: SIMD2<Double>, worldPosition: SIMD3<Float>) {
        if let near = nearestPlacedPost(to: tablePoint) {
            grabbedPost = near
            grabIsNewPlacement = false
        } else {
            grabbedPost = postForCurrentStage()
            grabIsNewPlacement = grabbedPost != nil
        }
        if let grabbedPost { setPost(grabbedPost, tablePoint: tablePoint, worldPosition: worldPosition) }
    }

    /// Pinch-up: a NEW placement advances the stage; moving an existing tile stays.
    private func endGrab() {
        let wasNew = grabIsNewPlacement
        grabbedPost = nil
        grabIsNewPlacement = false
        if wasNew {
            lightImpact()
            advanceStage()
        } else {
            refreshUI()
        }
    }

    private func postForCurrentStage() -> WhichPost? {
        switch stage {
        case .handPostA: return .handA
        case .handPostB: return .handB
        case .pondCornerA: return .pondA
        case .pondCornerB: return .pondB
        default: return nil
        }
    }

    private func nearestPlacedPost(to p: SIMD2<Double>) -> WhichPost? {
        var best: (WhichPost, Double)?
        func consider(_ which: WhichPost, _ tp: SIMD2<Double>?) {
            guard let tp else { return }
            let dx = p.x - tp.x, dy = p.y - tp.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= grabRadius, best == nil || d < best!.1 { best = (which, d) }
        }
        consider(.handA, handPostA)
        consider(.handB, handPostB)
        consider(.pondA, pondCornerA)
        consider(.pondB, pondCornerB)
        return best?.0
    }

    private func setPost(_ which: WhichPost, tablePoint: SIMD2<Double>, worldPosition: SIMD3<Float>) {
        switch which {
        case .handA:
            handPostA = tablePoint
            placeTileMarker(&handMarkerA, at: worldPosition, theme: .ivory,
                            body: UIColor(MJColor.cream(1)), key: "ivory", standing: true)
            updateBandNode()
        case .handB:
            handPostB = tablePoint
            placeTileMarker(&handMarkerB, at: worldPosition, theme: .ivory,
                            body: UIColor(MJColor.cream(1)), key: "ivory", standing: true)
            updateBandNode()
        case .pondA:
            pondCornerA = tablePoint
            placeTileMarker(&pondMarkerA, at: worldPosition, theme: .jade,
                            body: UIColor(MJColor.jadeAccent), key: "jade", standing: false)
            updatePondRectNode()
        case .pondB:
            pondCornerB = tablePoint
            placeTileMarker(&pondMarkerB, at: worldPosition, theme: .jade,
                            body: UIColor(MJColor.jadeAccent), key: "jade", standing: false)
            updatePondRectNode()
        }
        refreshUI()
    }

    /// Tap fallback: place the current stage's post and advance.
    private func placeAndAdvance(_ tablePoint: SIMD2<Double>, worldPosition: SIMD3<Float>) {
        guard let which = postForCurrentStage() else { return }
        setPost(which, tablePoint: tablePoint, worldPosition: worldPosition)
        lightImpact()
        advanceStage()
    }

    private func advanceStage() {
        isPinchEngaged = false
        grabbedPost = nil
        switch stage {
        case .handPostA where handPostA != nil: stage = .handPostB
        case .handPostB where handPostB != nil: stage = .pondCornerA
        case .pondCornerA where pondCornerA != nil: stage = .pondCornerB
        case .pondCornerB where pondCornerB != nil:
            enterReview()
            return
        default: break
        }
        refreshUI()
    }

    private func tablePoint(ofWorldTransform worldTransform: simd_float4x4, planeAnchor: ARPlaneAnchor) -> SIMD2<Double> {
        let worldHit = SIMD4<Float>(worldTransform.columns.3.x, worldTransform.columns.3.y,
                                    worldTransform.columns.3.z, 1)
        let local = simd_inverse(planeAnchor.transform) * worldHit
        return SIMD2<Double>(Double(local.x), Double(local.z))
    }

    // MARK: - 3D tile nodes

    private func updateHover(at worldPosition: SIMD3<Float>) {
        // The ghost mirrors the current stage's marker: a standing ivory tile
        // for the hand posts, a flat jade tile for the pond corners.
        let standing = stage == .handPostA || stage == .handPostB
        let key = standing ? "ivory" : "jade"
        if hoverNode == nil || hoverStyleKey != key {
            hoverNode?.removeFromParentNode()
            let body = standing ? UIColor(MJColor.cream(0.9)) : UIColor(MJColor.jadeAccent)
            let node = makeTileNode(theme: standing ? .ivory : .jade, body: body, key: key, standing: standing)
            node.opacity = 0.35
            sceneView.scene.rootNode.addChildNode(node)
            hoverNode = node
            hoverStyleKey = key
        }
        hoverNode?.isHidden = false
        let lift: Float = standing ? 0.016 : 0
        hoverNode?.position = SCNVector3(worldPosition.x, worldPosition.y + lift, worldPosition.z)
    }

    private func hideHover() { hoverNode?.isHidden = true }

    /// A standing translucent block spanning the two hand posts — the same
    /// height and depth as the tile markers — so the oriented hand band reads as
    /// a low "wall" of tiles standing on the table, not a flat stripe. Its
    /// centre sits at the markers' own y (they are already lifted by half a
    /// tile height), so the block stands ON the surface.
    private func updateBandNode() {
        bandNode?.removeFromParentNode()
        guard let a = handMarkerA?.position, let b = handMarkerB?.position else { return }
        let dx = b.x - a.x, dz = b.z - a.z
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.001 else { return }
        let box = SCNBox(width: CGFloat(length), height: 0.032, length: 0.016, chamferRadius: 0.003)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(MJColor.gold(0.9))
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false   // translucent — don't occlude the tile markers
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.opacity = 0.5
        node.renderingOrder = -1
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        node.eulerAngles.y = -atan2(dz, dx)
        sceneView.scene.rootNode.addChildNode(node)
        bandNode = node
    }

    /// A flat translucent jade rectangle spanning the two pond corners — the
    /// axis-aligned (in table space) footprint Coach will watch for discards.
    /// Built in the plane's local frame (so its edges align with the table
    /// axes, matching `PondShape.rect`) then transformed into world space.
    private func updatePondRectNode() {
        pondRectNode?.removeFromParentNode()
        pondRectNode = nil
        guard let a = pondCornerA, let b = pondCornerB,
              let planeAnchor = calibrationPlaneAnchor else { return }
        let width = abs(a.x - b.x), length = abs(a.y - b.y)
        guard width > 0.001, length > 0.001 else { return }
        let cx = (a.x + b.x) / 2, cz = (a.y + b.y) / 2

        let box = SCNBox(width: CGFloat(width), height: 0.002, length: CGFloat(length), chamferRadius: 0.002)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(MJColor.jadeAccent)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.opacity = 0.28
        node.renderingOrder = -1
        // Place at the pond centre in the plane's local frame (y = 0 on plane).
        var offset = matrix_identity_float4x4
        offset.columns.3 = SIMD4<Float>(Float(cx), 0.001, Float(cz), 1)
        node.simdTransform = planeAnchor.transform * offset
        sceneView.scene.rootNode.addChildNode(node)
        pondRectNode = node
    }

    private func placeTileMarker(_ node: inout SCNNode?, at worldPosition: SIMD3<Float>,
                                 theme: TileTheme, body: UIColor, key: String, standing: Bool) {
        // Standing tiles rest ON the table, so lift the node by half their
        // height; flat tiles sit at plane level.
        let lift: Float = standing ? 0.016 : 0
        let position = SCNVector3(worldPosition.x, worldPosition.y + lift, worldPosition.z)
        if let existing = node {
            existing.position = position
        } else {
            let markerNode = makeTileNode(theme: theme, body: body, key: key, standing: standing)
            markerNode.position = position
            sceneView.scene.rootNode.addChildNode(markerNode)
            node = markerNode
        }
    }

    /// A small 3D mahjong tile at the app's real footprint, its face textured
    /// from the same `MahjongTileView` the app draws. `standing` tiles stand on
    /// edge with the face toward the user (a billboard keeps them upright and
    /// facing the camera); flat tiles lie face-up (used for the pond).
    private func makeTileNode(theme: TileTheme, body: UIColor, key: String, standing: Bool) -> SCNNode {
        let bodyMat = SCNMaterial()
        bodyMat.diffuse.contents = body
        bodyMat.lightingModel = .constant
        let faceMat = SCNMaterial()
        faceMat.diffuse.contents = markerTexture(theme: theme, key: key) ?? body
        faceMat.lightingModel = .constant

        let box: SCNBox
        var materials: [SCNMaterial]
        if standing {
            // Upright: 0.024 wide × 0.032 tall × 0.016 thick; face on the front
            // (index 0), which the Y-axis billboard turns toward the user.
            box = SCNBox(width: 0.024, height: 0.032, length: 0.016, chamferRadius: 0.003)
            materials = [faceMat, bodyMat, bodyMat, bodyMat, bodyMat, bodyMat]
        } else {
            // Flat: face on top (index 4), seen from above.
            box = SCNBox(width: 0.024, height: 0.016, length: 0.032, chamferRadius: 0.003)
            materials = [bodyMat, bodyMat, bodyMat, bodyMat, faceMat, bodyMat]
        }
        box.materials = materials
        let node = SCNNode(geometry: box)
        if standing {
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .Y   // stay upright, rotate to face the camera/user
            node.constraints = [billboard]
        }
        return node
    }

    /// Renders the existing procedural `MahjongTileView` to a `UIImage` once
    /// per theme and caches it — the tile's face texture.
    private func markerTexture(theme: TileTheme, key: String) -> UIImage? {
        if let cached = Self.tileTextureCache[key] { return cached }
        let renderer = ImageRenderer(content: MahjongTileView(markerTile, theme: theme, width: 240, showsBadge: false))
        renderer.scale = 3
        let image = renderer.uiImage
        if let image { Self.tileTextureCache[key] = image }
        return image
    }

    // MARK: - Actions

    @objc private func flashTapped() {
        torchOn.toggle()
        if !CameraTorch.set(torchOn) { torchOn = false; flashButton.isHidden = true; return }
        flashButton.setImage(UIImage(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill"), for: .normal)
        flashButton.tintColor = torchOn ? UIColor(MJColor.gold) : UIColor(MJColor.creamHeading)
    }

    private func lightImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func backTapped() {
        isPinchEngaged = false; grabbedPost = nil; grabbedHandle = nil; directDragOffset = nil
        switch stage {
        case .handPostA:
            onCancel?()
        case .handPostB:
            handPostA = nil; handMarkerA?.removeFromParentNode(); handMarkerA = nil
            stage = .handPostA
        case .pondCornerA:
            handPostB = nil; handMarkerB?.removeFromParentNode(); handMarkerB = nil
            bandNode?.removeFromParentNode(); bandNode = nil
            stage = .handPostB
        case .pondCornerB:
            pondCornerA = nil; pondMarkerA?.removeFromParentNode(); pondMarkerA = nil
            pondRectNode?.removeFromParentNode(); pondRectNode = nil
            stage = .pondCornerA
        case .review:
            leaveReviewForPondMarking()
        }
        refreshUI()
    }

    @objc private func primaryTapped() {
        switch stage {
        case .review: complete()
        default: break
        }
        refreshUI()
    }

    private func complete() {
        guard let calibration = currentCalibration() else {
            subtitleLabel.text = "Move the hand row at least 15 cm from the pond, then try again."
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onComplete?(calibration)
    }
}
