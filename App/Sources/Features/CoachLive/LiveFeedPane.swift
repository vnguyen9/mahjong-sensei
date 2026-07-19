import SwiftUI
import DesignSystem
import MahjongCore

/// The live-feed pane (UI plan §7). The camera preview is a **fixed,
/// full-screen** layer — only the pane's clip height animates as the split
/// breathes, so the `AVCaptureVideoPreviewLayer` never relayouts (no per-frame
/// video-gravity re-crop) and `AspectFillMapping` gets a constant
/// `previewBounds`, letting the zone brackets survive split changes.
///
/// Layer order (bottom → top): fixed preview · backdrop blur · staged-loading
/// overlay (`StartupStatusOverlay`, A1) · zone brackets · chrome (back /
/// torch / LivePill). On the Simulator (no camera) the preview
/// falls back to `ScreenBackground(.live)` so every state is still
/// screenshot-able; on device the preview attaches to the session's running
/// `CameraCapture`.
struct LiveFeedPane: View {
    @Environment(CoachLiveSession.self) private var session

    /// The full-screen size the fixed layer is pinned to (from the parent
    /// GeometryReader — physical top down to the safe-area bottom).
    let fullSize: CGSize
    /// Top safe-area inset — the pane bleeds under it, so the chrome is padded
    /// down to clear the notch/status bar.
    let safeTop: CGFloat
    /// Whether the privacy blur is installed (live-reactive, UI plan §13).
    let blursFeed: Bool
    let onExit: () -> Void
    let onTapUnresolved: () -> Void
    let onTapZoneChip: (ZoneKind) -> Void

    /// The captured global frame of the fixed preview — the constant
    /// `previewBounds` the brackets map against.
    @State private var previewFrame: CGRect = .zero
    @State private var torchOn = false
    @State private var pulse = false
    /// Dev-only diagnostics overlay, toggled by a triple-tap on the LIVE
    /// pill — see `debugHUD`. Not a Settings entry; a bisect aid only.
    @State private var showHUD = false

    var body: some View {
        ZStack(alignment: .top) {
            feedLayer
                .frame(width: fullSize.width, height: fullSize.height)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) },
                                  action: { previewFrame = $0 })

            if blursFeed {
                FeedBlurBackdrop()
                    .frame(width: fullSize.width, height: fullSize.height)
                    .transition(.opacity)
            }

            StartupStatusOverlay()
                .frame(width: fullSize.width, height: fullSize.height)
                .animation(.easeInOut(duration: 0.25), value: session.startupStage)

            ZoneBracketsOverlay(previewBounds: previewFrame, onTapUnresolved: onTapUnresolved,
                                onTapZoneChip: onTapZoneChip)
                .frame(width: fullSize.width, height: fullSize.height)

            chrome
                .frame(width: fullSize.width, height: fullSize.height, alignment: .top)
        }
        .frame(width: fullSize.width, height: fullSize.height, alignment: .top)
        .animation(.easeInOut(duration: 0.25), value: blursFeed)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
            #if !targetEnvironment(simulator)
            // Device, image-space (fallback) path only: ensure the
            // (coordinator-hoisted, §5) camera is live so this fixed preview
            // attaches to the already-running session — a zero-blink
            // transition since Scan never stopped it. Idempotent (guarded by
            // `configured`/`isRunning`). AR mode must NOT do this — ARKit
            // owns the capture device (`ScanCoordinator.startCoachLive`
            // stopped `camera` before starting it), and calling
            // `requestAndStart()` here would fight ARKit for it.
            if session.arCapture == nil { session.camera.requestAndStart() }
            #endif
        }
    }

    // MARK: - Fixed feed layer

    @ViewBuilder private var feedLayer: some View {
        #if targetEnvironment(simulator)
        ScreenBackground(.live)
        #else
        if let arCapture = session.arCapture {
            ARCameraPreview(capture: arCapture)
        } else {
            CameraPreview(session: session.camera.session)
        }
        #endif
    }

    // MARK: - Chrome (pinned to the pane, notch-aware)

    private var chrome: some View {
        VStack(spacing: 10) {
            HStack {
                circleButton(system: "chevron.left", tint: MJColor.cream(0.85),
                             border: MJColor.gold(0.2), action: onExit)
                    .accessibilityLabel("End Coach Live session")
                Spacer()
                torchButton
            }
            livePill
            // Lane B chunk D: "Hold steady…" (the camera is visibly moving)
            // and the dark-table suggestion both live in this same slot —
            // they can't both be relevant at once, and cameraMoving wins
            // (there's no point suggesting the torch while the frame itself
            // is unusable for tracking).
            if session.cameraMoving {
                holdSteadyChip
                    .transition(.opacity)
            } else if let prompt = session.rescanPrompt {
                rescanPromptChip(prompt)
                    .transition(.opacity)
            } else if session.isDark && !torchOn && !session.torchSuggestionDismissed {
                darkTableChip
                    .transition(.opacity)
            }
            if showHUD {
                debugHUD.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 12)
        .animation(.easeInOut(duration: 0.2), value: session.isDark)
        .animation(.easeInOut(duration: 0.2), value: session.cameraMoving)
        .animation(.easeInOut(duration: 0.2), value: session.rescanPrompt)
    }

    /// Lane B chunk D's "hold steady" chip — same capsule styling family as
    /// `darkTableChip`, purely informational (no tap targets: there's
    /// nothing to confirm or dismiss, it just clears itself once the phone
    /// settles).
    private var holdSteadyChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Hold steady…")
                .font(MJFont.ui(12, weight: .semibold))
        }
        .foregroundStyle(MJColor.cream)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(Color(hex: 0x0A241D, alpha: 0.6))
        }
        .overlay { Capsule().strokeBorder(MJColor.gold(0.3), lineWidth: 1) }
    }

    /// Lane B chunk H item 2's directional rescan-prompt chip — same
    /// capsule family as `holdSteadyChip`/`darkTableChip`, priority between
    /// them (a moving camera always wins; a stale zone the tracker is
    /// invested in outranks a mere lighting suggestion). The label itself
    /// isn't a tap target — there's nowhere useful to route a tap, panning
    /// is a physical action — only the trailing "×" dismisses.
    private func rescanPromptChip(_ prompt: CoachLiveSession.RescanPrompt) -> some View {
        HStack(spacing: 8) {
            Text(prompt.text)
                .font(MJFont.ui(12, weight: .semibold))
                .foregroundStyle(MJColor.cream)

            Button {
                session.dismissRescanPrompt()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MJColor.cream(0.5))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss rescan suggestion")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(Color(hex: 0x0A241D, alpha: 0.6))
        }
        .overlay { Capsule().strokeBorder(MJColor.gold(0.3), lineWidth: 1) }
    }

    /// A5's "Dark table — turn on flash?" chip — mirrors `livePill`'s capsule
    /// styling (ultraThinMaterial + dark fill + hairline border), swapped to
    /// the amber zone tint so it reads as a suggestion, not status. Two
    /// independent tap targets: the label turns the torch on, the trailing
    /// "×" dismisses for the rest of the session (`torchSuggestionDismissed`).
    private var darkTableChip: some View {
        HStack(spacing: 8) {
            Button {
                torchOn = true
                session.setTorch(true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Dark table — turn on flash?")
                        .font(MJFont.ui(12, weight: .semibold))
                }
                .foregroundStyle(MJColor.cream)
            }
            .buttonStyle(.plain)

            Button {
                session.torchSuggestionDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MJColor.cream(0.5))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss dark table suggestion")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(Color(hex: 0x0A241D, alpha: 0.6))
        }
        .overlay { Capsule().strokeBorder(MJColor.amberZone.opacity(0.45), lineWidth: 1) }
    }

    private var torchButton: some View {
        Button {
            torchOn.toggle()
            session.setTorch(torchOn)
        } label: {
            circleContent(system: torchOn ? "bolt.fill" : "bolt.slash.fill",
                          tint: torchOn ? MJColor.gold : MJColor.cream(0.85),
                          border: MJColor.gold(torchOn ? 0.5 : 0.2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(torchOn ? "Turn flash off" : "Turn flash on")
    }

    private func circleButton(system: String, tint: Color, border: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { circleContent(system: system, tint: tint, border: border) }
            .buttonStyle(.plain)
    }

    /// The ScanView torch-button recipe: ultra-thin material + jade tint disc,
    /// gold hairline border.
    private func circleContent(system: String, tint: Color, border: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background {
                Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                Circle().fill(Color(hex: 0x0A241D, alpha: 0.55))
            }
            .overlay { Circle().strokeBorder(border, lineWidth: 1) }
    }

    /// Amber "cooling" treatment also covers `detectorUnavailable` (plan §2:
    /// "reuse the existing thermal/cooling pill treatment") — both are
    /// "the loop is up but not doing useful inference" states, just for
    /// different reasons.
    private var pillIsDegraded: Bool { session.thermal == .throttled || session.detectorUnavailable }

    private var pillText: String {
        if session.isWarmingUp { return "Starting…" }
        if session.detectorUnavailable { return "LIVE · detector unavailable" }
        if session.thermal == .throttled { return "LIVE · cooling" }
        return "LIVE · \(session.liveTileCount) tiles seen"
    }

    private var livePill: some View {
        HStack(spacing: 7) {
            // Warm-up (camera + detector loading) shows a spinner instead of the
            // pulsing red dot, so slow phones read as "starting", not "frozen".
            if session.isWarmingUp {
                ProgressView()
                    .controlSize(.mini)
                    .tint(MJColor.cream)
            } else {
                Circle().fill(pillIsDegraded ? MJColor.amberZone : MJColor.liveRed)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.35)
            }
            Text(pillText)
                .font(MJFont.ui(13, weight: .semibold)).foregroundStyle(MJColor.cream)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background {
            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            Capsule().fill(Color(hex: 0x0A241D, alpha: 0.6))
        }
        .overlay { Capsule().strokeBorder(MJColor.gold(0.3), lineWidth: 1) }
        // Debug HUD toggle (plan §3) — a deliberately obscure gesture, no
        // Settings entry; three quick taps on the pill.
        .onTapGesture(count: 3) { showHUD.toggle() }
        .accessibilityAddTraits(.isButton)
    }

    /// Triple-tap debug overlay (plan §3): loop/motion/cadence/inference/
    /// tracker diagnostics the live loop records on the session every tick,
    /// plus the last pipeline error — everything needed to bisect "why does
    /// the pill say 0 tiles seen" without a debugger attached (mirrored to
    /// Console.app too, via `CoachLiveSession`'s `os.Logger`).
    private var debugHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ticks \(session.diagnostics.loopTicks) · nilBuf \(session.diagnostics.nilBufferCount)")
            Text("motion \(session.diagnostics.motionLevel, specifier: "%.3f") · nilMotion \(session.diagnostics.nilMotionSampleCount)")
            Text("infer \(session.diagnostics.inferDecisions) · skip \(session.diagnostics.skipDecisions) · suspend \(session.diagnostics.suspendDecisions)")
            Text("ran \(session.diagnostics.inferencesRun) · raw \(session.diagnostics.lastRawDetectionCount)")
            Text("top: \(session.diagnostics.lastTopDetections.isEmpty ? "—" : session.diagnostics.lastTopDetections.joined(separator: ", "))")
            Text("tracker live \(session.trackerDiagnostics.live) · tent \(session.trackerDiagnostics.tentative) · missing \(session.trackerDiagnostics.missing)")
            Text("rec: \(session.diagnostics.recognizerType) · mode \(session.arCapture != nil && !session.usingFallbackCapture ? "AR" : "2D")")
            Text(session.diagnostics.roiPlan)
            Text("err(\(session.recognizerErrorCount)): \(session.lastPipelineError ?? "—")")
            #if DEBUG
            Text("census: \(session.shadowCensusSummary)")
            let geo = session.calibratedTableGeometry
            Text("cal: \(geo.map { String(format: "ext %.2f · band %.2f · pond %.2f", $0.extent, $0.handBandDepth, $0.pondRadius) } ?? "—")")
            Button("Calibrate table (AR)") { session.beginARCalibration() }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MJColor.cream(1))
            #endif
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(MJColor.cream(0.9))
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: 0x0A241D, alpha: 0.75))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MJColor.gold(0.2), lineWidth: 1)
        }
    }
}
