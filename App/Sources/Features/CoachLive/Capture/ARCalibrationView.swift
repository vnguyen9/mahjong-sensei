import ARKit
import DesignSystem
import MahjongCore
import Recognition
import SceneKit
import SwiftUI
import UIKit
import simd

/// The multi-stage ARKit calibration screen shown BEFORE the Coach Live play
/// loop starts (spec screens 2–7). It runs its OWN `ARSession` (a plain
/// `ARWorldTrackingConfiguration` with horizontal plane detection), independent
/// of `ARTableCapture`/`CoachLiveSession`'s longer-lived play-loop session.
///
/// The user sees ARKit's default plane grid + Apple's `ARCoachingOverlayView`
/// onboarding, then:
///   1. **brackets their hand row** by dropping two posts (pinch or tap) at
///      each end of their tiles — an *oriented* band that follows the row,
///   2. **marks the pond** with one point,
///   3. **confirms the auto-placed seats** (derived from the plane edges + the
///      user's seat wind),
/// which are converted into a `TrackerConfig.TableGeometry` (oriented hand band
/// + seats + meld bands) and handed back via `onComplete`.
///
/// The produced geometry carries orientation-normalized fractions, so it
/// transfers into the play loop's own separately-locked plane. (True world-
/// anchored raycast precision is device-QA; ARSCNView does not render in the
/// Simulator, where this shows chrome over a black scene.)
struct ARCalibrationView: UIViewControllerRepresentable {
    /// The user's seat wind (from the setup card), used to label the seats.
    var mySeatWind: Wind = .east
    var onComplete: (TrackerConfig.TableGeometry) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> ARCalibrationViewController {
        let controller = ARCalibrationViewController()
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
final class ARCalibrationViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    var mySeatWind: Wind = .east
    var onComplete: ((TrackerConfig.TableGeometry) -> Void)?
    var onCancel: (() -> Void)?

    /// What the next tap/pinch places, and the review/confirm tail.
    enum MarkStage: Int {
        case handPostA     // left end of my row
        case handPostB     // right end of my row
        case pondCornerA   // one corner of the discard pile
        case pondCornerB   // the opposite corner → an oriented pond rectangle
        case edit          // full edit mode: drag hand posts, pond corners, seats
        case seats         // auto-placed seats, confirm
        case done          // review, start tracking

        /// Grouped 1-based step for the "STEP n OF 4" label (hand = 1, pond = 2,
        /// seats = 3, done = 4), since multiple raw stages back each of hand +
        /// pond.
        var displayStep: Int {
            switch self {
            case .handPostA, .handPostB: return 1
            case .pondCornerA, .pondCornerB, .edit: return 2
            case .seats: return 3
            case .done: return 4
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
    /// Shown only on the seats/done review — enters the 4-corner pond refine.
    private let refineButton = UIButton(type: .system)
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

    // Pond refine: 4 draggable corners (anchor-local metres, winding order)
    // that override the 2-corner rect with an arbitrary quad. Empty until the
    // user enters edit mode; `editReturnStage` is where "Done"/"Back" goes back to.
    private var pondQuad: [SIMD2<Double>] = []
    private var pondQuadMarkers: [SCNNode?] = [nil, nil, nil, nil]
    private var pondQuadFillNode: SCNNode?
    private var editReturnStage: MarkStage = .seats

    /// Opponent seat midpoints (anchor-local metres, `.left`/`.right`/`.across`
    /// only — the user's own `.me` seat is the hand row) draggable in full edit
    /// mode, and their 3D marker nodes.
    private var seatMidpoints: [RelativeSeat: SIMD2<Double>] = [:]
    private var seatMarkers: [RelativeSeat: SCNNode] = [:]

    /// A single draggable handle in full edit mode — either hand post, a pond
    /// quad corner (by index), or an opponent seat.
    private enum EditHandle: Equatable {
        case handA, handB, pond(Int), seat(RelativeSeat)
    }
    private var grabbedHandle: EditHandle?

    // Live hand-pose pinch marking (no button): a ghost tile follows the
    // fingertip; a pinch (thumb+index close) drops the next tile and advances,
    // and pinching a placed tile grabs it to move.
    private var hoverNode: SCNNode?
    private var hoverStyleKey: String?
    private var lastPinchSampleAt: TimeInterval = 0
    private var pinchInferenceInFlight = false
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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSceneView()
        setupCoachingOverlay()
        setupControls()
        refreshUI()
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
        // Drop the torch on the way out; the live capture re-asserts its own
        // `pendingTorchState` when it resumes, so we don't leak this session's
        // flash state into tracking.
        if torchOn { CameraTorch.set(false); torchOn = false }
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
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)

        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = UIColor(MJColor.cream(0.7))
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        stepLabel.textAlignment = .center
        stepLabel.textColor = UIColor(MJColor.gold(0.85))
        stepLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        let cardStack = UIStackView(arrangedSubviews: [stepLabel, titleLabel, subtitleLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 4
        cardStack.alignment = .fill
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardStack)

        // Bottom controls.
        styleSecondary(backButton, title: "Back")
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        stylePill(primaryButton, title: "Confirm", background: MJColor.gold)
        primaryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        let bottomStack = UIStackView(arrangedSubviews: [backButton, primaryButton])
        bottomStack.axis = .horizontal
        bottomStack.alignment = .fill
        bottomStack.distribution = .fillEqually
        bottomStack.spacing = 12
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomStack)

        // "Edit layout" — a secondary pill just above the bottom row, visible
        // only during the seats/done review.
        var refineConfig = UIButton.Configuration.plain()
        refineConfig.attributedTitle = AttributedString("Edit layout", attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor(MJColor.inkOnGold)
        ]))
        refineConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        refineButton.configuration = refineConfig
        refineButton.backgroundColor = UIColor(MJColor.cream(0.9))
        refineButton.layer.cornerRadius = 12
        refineButton.translatesAutoresizingMaskIntoConstraints = false
        refineButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        view.addSubview(refineButton)

        // Flash toggle (top-right). Hidden if the device has no torch.
        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.tintColor = UIColor(MJColor.creamHeading)
        flashButton.backgroundColor = UIColor(MJColor.sheetGlass)
        flashButton.layer.cornerRadius = 22
        flashButton.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        flashButton.isHidden = !CameraTorch.isAvailable
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

            refineButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            refineButton.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -14)
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
        stepLabel.text = "STEP \(stage.displayStep) OF 4"

        // Marking stages advance automatically on each pinch — no button.
        let marking: Bool
        switch stage {
        case .handPostA:
            marking = true
            titleLabel.text = "Bracket your hand row"
            subtitleLabel.text = plane ? "Pinch at one end of your tiles to drop a marker."
                                       : "Move your phone to find the table first."
        case .handPostB:
            marking = true
            titleLabel.text = "Bracket your hand row"
            subtitleLabel.text = "Pinch at the other end. Pinch a placed tile to move it."
        case .pondCornerA:
            marking = true
            titleLabel.text = "Box the pond"
            subtitleLabel.text = "Pinch one corner of the discard area."
        case .pondCornerB:
            marking = true
            titleLabel.text = "Box the pond"
            subtitleLabel.text = "Pinch the opposite corner. Pinch a corner to move it."
        case .edit:
            marking = false
            titleLabel.text = "Edit the layout"
            subtitleLabel.text = "Tap or pinch a marker to move your hand, the pond, or a seat."
            primaryButton.setTitle("Done", for: .normal)
        case .seats:
            marking = false
            titleLabel.text = "Players detected automatically"
            subtitleLabel.text = "You are \(windName(mySeatWind)) (+Z). Tap Edit layout to adjust."
            primaryButton.setTitle("Confirm seats", for: .normal)
        case .done:
            marking = false
            titleLabel.text = "Does this look right?"
            subtitleLabel.text = "Tap Edit layout to fine-tune, or start tracking."
            primaryButton.setTitle("Start tracking", for: .normal)
        }

        backButton.setTitle(stage == .handPostA ? "Cancel" : "Back", for: .normal)
        // Pinch drives the marking stages, so hide the primary there; show it
        // only for the review + refine confirmations.
        primaryButton.isHidden = marking
        primaryButton.isEnabled = plane
        primaryButton.alpha = plane ? 1 : 0.45
        // "Refine pond area" only offered on the seats/done review.
        refineButton.isHidden = !(stage == .seats || stage == .done)
    }

    private func windName(_ w: Wind) -> String {
        switch w {
        case .east: return "East 東"
        case .south: return "South 南"
        case .west: return "West 西"
        case .north: return "North 北"
        }
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

    // MARK: - Marking (tap fallback)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let planeAnchor = calibrationPlaneAnchor else { return }
        let screenPoint = gesture.location(in: sceneView)
        guard let query = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else { return }
        let tablePoint = tablePoint(ofWorldTransform: result.worldTransform, planeAnchor: planeAnchor)
        let worldPosition = SIMD3<Float>(result.worldTransform.columns.3.x,
                                         result.worldTransform.columns.3.y,
                                         result.worldTransform.columns.3.z)
        // Edit mode: a tap moves the nearest handle (hand post, pond corner,
        // or seat) to it — tap fallback for the pinch-drag, allowed beyond
        // `grabRadius` since a tap is deliberate.
        if stage == .edit {
            if let h = nearestEditHandle(to: tablePoint, withinRadius: false) {
                moveEditHandle(h, to: tablePoint)
            }
            return
        }
        placeAndAdvance(tablePoint, worldPosition: worldPosition)
    }

    private func dist2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    // MARK: - Live pinch (ARSessionDelegate)

    /// Continuous hand-pose sampling (~10 Hz, off-main) while placing marks: a
    /// ghost tile follows the fingertip and a pinch places/moves the current
    /// post. This is the iOS equivalent of visionOS hand tracking — Vision's
    /// `VNDetectHumanHandPoseRequest`, run only during calibration (bounded
    /// cost). No "Pinch" button.
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Sampling stays live through the seats/done review too, so a pinch can
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sample = HandPoseFingertip.pinch(in: pixelBuffer)
            var tablePoint: SIMD2<Double>?
            if let point = sample?.point {
                let projection = TableProjection(
                    cameraTransform: cameraTransform,
                    intrinsics: intrinsics,
                    imageResolution: SIMD2<Float>(Float(resolution.width), Float(resolution.height)),
                    planeTransform: planeTransform)
                let orientedImageSize = SIMD2<Double>(Double(resolution.height), Double(resolution.width))
                tablePoint = projection.tablePoint(ofNormalizedOrientedPoint: point, orientedImageSize: orientedImageSize)
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
            if stage == .edit {
                grabbedHandle = nearestEditHandle(to: tablePoint)
                if let h = grabbedHandle { moveEditHandle(h, to: tablePoint) }
            } else { beginGrab(at: tablePoint, worldPosition: worldPosition) }
        } else if isPinchEngaged, sample.gap >= pinchReleaseGap {
            isPinchEngaged = false
            if stage == .edit { grabbedHandle = nil; refreshUI() }
            else { endGrab() }
        }

        if isPinchEngaged {
            hideHover()
            if stage == .edit {
                if let h = grabbedHandle { moveEditHandle(h, to: tablePoint) }
            } else if let grabbedPost {
                setPost(grabbedPost, tablePoint: tablePoint, worldPosition: worldPosition)
            }
        } else if postForCurrentStage() != nil {
            updateHover(at: worldPosition)   // ghost follows the finger only when a new tile can drop
        } else {
            hideHover()                      // review/edit: pinch moves existing markers, no ghost
        }
    }

    // MARK: - Full edit mode (hand posts + pond quad + seats)

    /// Enters `.edit`: seeds the pond quad + the 3 opponent seat markers if
    /// not already present, hides the pond rect preview in favor of the 4
    /// draggable quad corners, and shows every handle. Hand markers stay
    /// visible throughout.
    @objc private func editTapped() {
        guard calibrationPlaneAnchor != nil else { return }
        editReturnStage = stage
        // Seed the quad from the current pond footprint (2-corner rect or a
        // previously-refined quad), in anchor-local metres.
        if pondQuad.count != 4 { pondQuad = seededPondQuad() }
        // Hide the rect preview; show 4 corner markers + the quad fill.
        pondMarkerA?.isHidden = true
        pondMarkerB?.isHidden = true
        pondRectNode?.isHidden = true
        for i in 0..<4 { placeQuadMarker(i) }
        updatePondQuadFill()
        seedSeatMidpointsIfNeeded()
        for seat: RelativeSeat in [.left, .right, .across] { placeSeatMarker(seat) }
        stage = .edit
        refreshUI()
    }

    /// Exits `.edit` in place — edits are kept, not reverted. Hides the pond
    /// quad corner handles + the 3 seat markers, but keeps the applied pond
    /// quad fill as the pond viz (same as the old pond-refine "Done") and
    /// keeps the hand markers.
    private func exitEditInPlace() {
        for i in pondQuadMarkers.indices { pondQuadMarkers[i]?.isHidden = true }
        for seat in seatMarkers.keys { seatMarkers[seat]?.isHidden = true }
        pondMarkerA?.isHidden = true
        pondMarkerB?.isHidden = true
        pondRectNode?.isHidden = true
        stage = editReturnStage
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

    /// Seeds the 3 opponent seat midpoints (anchor-local metres) at the
    /// canonical edge midpoints of the current plane extent, only if not
    /// already placed (so re-entering edit mode doesn't reset a drag).
    private func seedSeatMidpointsIfNeeded() {
        guard seatMidpoints.isEmpty else { return }
        let extent = calibrationPlaneAnchor.map { Double(max($0.planeExtent.width, $0.planeExtent.height)) } ?? 0.9
        seatMidpoints[.left] = SIMD2(-extent / 2, 0)
        seatMidpoints[.right] = SIMD2(extent / 2, 0)
        seatMidpoints[.across] = SIMD2(0, -extent / 2)
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
        var best: (EditHandle, Double)?
        for (h, tp) in editHandlePoints() {
            let d = dist2(p, tp).squareRoot()
            if withinRadius && d > grabRadius { continue }
            if best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    /// Moves the given handle to `tablePoint` and updates its 3D marker(s).
    private func moveEditHandle(_ h: EditHandle, to tablePoint: SIMD2<Double>) {
        switch h {
        case .handA:
            setPost(.handA, tablePoint: tablePoint, worldPosition: worldFromLocal(tablePoint))
        case .handB:
            setPost(.handB, tablePoint: tablePoint, worldPosition: worldFromLocal(tablePoint))
        case let .pond(i):
            setQuadCorner(i, tablePoint: tablePoint)
        case let .seat(seat):
            seatMidpoints[seat] = tablePoint
            placeSeatMarker(seat)
        }
    }

    /// A small gold sphere marking an opponent seat — visually distinct from
    /// the tile-shaped hand/pond markers so it reads as a seat, not a tile.
    private func makeSeatMarkerNode() -> SCNNode {
        let sphere = SCNSphere(radius: 0.012)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(MJColor.gold)
        material.lightingModel = .constant
        sphere.materials = [material]
        return SCNNode(geometry: sphere)
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
        if wasNew { advanceStage() } else { refreshUI() }
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
        advanceStage()
    }

    private func advanceStage() {
        isPinchEngaged = false
        grabbedPost = nil
        switch stage {
        case .handPostA where handPostA != nil: stage = .handPostB
        case .handPostB where handPostB != nil: stage = .pondCornerA
        case .pondCornerA where pondCornerA != nil: stage = .pondCornerB
        case .pondCornerB where pondCornerB != nil: stage = .seats
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

    @objc private func backTapped() {
        isPinchEngaged = false; grabbedPost = nil; grabbedHandle = nil
        switch stage {
        case .edit:
            // Exit in place — edits are kept, not reverted (matches "Done").
            exitEditInPlace()
            refreshUI()
            return
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
        case .seats:
            pondCornerB = nil; pondMarkerB?.removeFromParentNode(); pondMarkerB = nil
            pondRectNode?.removeFromParentNode(); pondRectNode = nil
            clearQuadNodes(); pondQuad = []
            stage = .pondCornerB
        case .done:
            stage = .seats
        }
        refreshUI()
    }

    @objc private func primaryTapped() {
        switch stage {
        case .handPostA where handPostA != nil: stage = .handPostB
        case .handPostB where handPostB != nil: stage = .pondCornerA
        case .pondCornerA where pondCornerA != nil: stage = .pondCornerB
        case .pondCornerB where pondCornerB != nil: stage = .seats
        case .edit:
            // Apply: keep the quad fill as the pond viz, hide the corner
            // handles + seat markers + the old rect preview.
            exitEditInPlace()
        case .seats: stage = .done
        case .done: complete()
        default: break
        }
        refreshUI()
    }

    private func complete() {
        guard let planeAnchor = calibrationPlaneAnchor else { return }
        let extentMetres = Double(max(planeAnchor.planeExtent.width, planeAnchor.planeExtent.height))
        // Emit the frame-invariant whole-table AUTO-PARTITION (central pond +
        // nearest-edge fill), generated purely from the plane extent + seat
        // wind. Because it carries no positional corners, it lands correctly in
        // the LIVE tracking frame — sidestepping the calibration-session ↔
        // live-session coordinate mismatch that previously threw the
        // pinch-marked pond off the table (raw `planeAnchor.transform` vs the
        // live centered + yaw-aligned lock). The pinch marks still drive the
        // on-screen preview; positional editing that survives the session
        // transfer is a fast follow.
        let geometry = TableCalibrationGeometry.autoPartition(extentMetres: extentMetres,
                                                              mySeatWind: mySeatWind)
        onComplete?(geometry)
    }
}
