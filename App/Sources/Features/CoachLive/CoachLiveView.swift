import SwiftUI
import UIKit
import DesignSystem
import MahjongCore
import Recognition

/// Compression level of the gameplay sheet's flexible tab-content region,
/// derived from its measured height. `LiveSegmentedBar`, `HandStrip`,
/// and `AdviceLine` are fixed-height rows; the tab-content region is the only
/// `.frame(maxHeight: .infinity)` member — so the VStack's own math enforces
/// "map shrinks first, hand + advice never hide".
enum LiveCompression: Equatable { case full, compact, minimal }

private struct LiveCompressionKey: EnvironmentKey {
    static let defaultValue: LiveCompression = .full
}
extension EnvironmentValues {
    var liveCompression: LiveCompression {
        get { self[LiveCompressionKey.self] }
        set { self[LiveCompressionKey.self] = newValue }
    }
}

/// One presentation idiom for all of Coach Live's sheets (UI plan §12).
enum CoachLiveSheet: Identifiable, Hashable {
    case assign
    case adjustCount(Tile)
    case fixEvent(UUID)
    case pickHandTile(TrackID)
    case pickUnknownTile(TrackID)
    case adviceDetail

    var id: String {
        switch self {
        case .assign:                 return "assign"
        case let .adjustCount(tile):  return "adjust-\(tile.classIndex)"
        case let .fixEvent(id):       return "fix-\(id)"
        case let .pickHandTile(id):   return "pick-\(id.raw)"
        case let .pickUnknownTile(id): return "unknown-\(id.raw)"
        case .adviceDetail:           return "advice"
        }
    }
}

/// Full-screen AR with a draggable Map ⇄ Counts ⇄ Events gameplay sheet.
/// The AR surface is mounted by `CoachLiveFlow`; this view supplies only
/// transparent live chrome and gameplay state, so sheet movement cannot resize
/// or replace the renderer.
struct CoachLiveView: View {
    @Environment(AppState.self) private var app
    let session: CoachLiveSession
    var initialTab: LiveTab = .map
    var initialSheet: CoachLiveSheet? = nil
    let onExit: () -> Void
    let onScoreHandoff: () -> Void

    @State private var tab: LiveTab
    @State private var sheet: CoachLiveSheet?
    /// Live begins with the table unobscured.  The gameplay surface is a
    /// bottom sheet, not a second half of the camera renderer, so dragging it
    /// can never crop/re-layout ARKit's camera or projected geometry.
    @State private var gameplaySheetExpanded = false
    @State private var showExitConfirm = false
    /// Non-nil while the bracket-reassign confirmation (A3) is up — which
    /// zone chip was tapped, so the dialog's copy and the confirm action
    /// both key off it.
    @State private var reassignZone: ZoneKind?

    init(session: CoachLiveSession, initialTab: LiveTab = .map, initialSheet: CoachLiveSheet? = nil,
        onExit: @escaping () -> Void, onScoreHandoff: @escaping () -> Void) {
        self.session = session
        self.initialTab = initialTab
        self.initialSheet = initialSheet
        self.onExit = onExit
        self.onScoreHandoff = onScoreHandoff
        _tab = State(initialValue: initialTab)
        _sheet = State(initialValue: initialSheet)
    }

    /// Compression from the space actually AVAILABLE to the state pane
    /// (`geo` remainder after the feed pane + seam), not from the pane's own
    /// rendered height — `tabContent`'s `minHeight: 84` floor means the pane
    /// can never legitimately measure smaller than its content's minimum, so
    /// measuring post-layout would be circular and never reach `.minimal`.
    /// Still device-size independent per the plan (§8) — a function of
    /// `geo.size.height`, not a hardcoded fraction breakpoint.
    private func compression(for availableHeight: CGFloat) -> LiveCompression {
        if availableHeight >= 300 { return .full }
        if availableHeight >= 236 { return .compact }
        return .minimal
    }

    /// Top inset used to push the feed chrome clear of the notch / Dynamic
    /// Island. The feed pane bleeds under the notch (`.ignoresSafeArea(edges:
    /// .top)` expands the GeometryReader, zeroing its reported
    /// `safeAreaInsets.top`), so this reads the window directly — but the
    /// session hides the status bar, which collapses the reported inset, so it
    /// is floored at 44pt to still clear the Island. Portrait-only, so the
    /// stable window read is sufficient.
    private var topSafeInset: CGFloat {
        let reported = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?.safeAreaInsets.top ?? 0
        // iPad has no notch/Island, so the 44pt iPhone floor would over-pad the
        // chrome — floor it lower there. iPhone keeps the Island clearance.
        let floor: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 20 : 44
        return max(reported, floor)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // The AR surface is below this transparent overlay.  The
                // pane supplies Live chrome, region actions and diagnostics;
                // it intentionally no longer owns/replaces an AR preview.
                LiveFeedPane(fullSize: geo.size,
                             safeTop: topSafeInset,
                             blursFeed: app.blursLiveFeed,
                             onExit: { showExitConfirm = true },
                             onTapUnresolved: { sheet = .assign },
                             onTapZoneChip: { reassignZone = $0 })
                    .frame(width: geo.size.width, height: geo.size.height)

                gameplaySheet(height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .ignoresSafeArea(edges: .top)
        .background {
            if !session.isARCaptureActive {
                ScreenBackground(.live).ignoresSafeArea()
            }
        }
        .environment(session)
        .sheet(item: $sheet) { sheetContent($0) }
        .confirmationDialog("Exit Coach Live?", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Exit and clear table", role: .destructive, action: onExit)
            Button("Keep watching", role: .cancel) {}
        } message: {
            Text("Current tile counts, hand progress, and table calibration will be cleared.")
        }
        .confirmationDialog(reassignDialogTitle, isPresented: reassignDialogPresented, titleVisibility: .visible) {
            Button(reassignDialogConfirmLabel) {
                if let reassignZone { session.reassignZoneBracket(reassignZone) }
                reassignZone = nil
            }
            Button("Cancel", role: .cancel) { reassignZone = nil }
        }
    }

    // MARK: - Full-screen AR + gameplay sheet

    private func gameplaySheet(height: CGFloat) -> some View {
        let collapsedHeight: CGFloat = 132
        let expandedHeight = min(height * 0.72, max(480, height - 120))
        let currentHeight = gameplaySheetExpanded ? expandedHeight : collapsedHeight

        return VStack(spacing: 0) {
            Capsule()
                .fill(MJColor.cream(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 9)
                .padding(.bottom, gameplaySheetExpanded ? 7 : 10)

            if gameplaySheetExpanded {
                statePane(compression: compression(for: expandedHeight - 22))
                    .environment(\.liveCompression, compression(for: expandedHeight - 22))
            } else {
                collapsedSheetSummary
            }
        }
        .frame(maxWidth: .infinity, minHeight: currentHeight, maxHeight: currentHeight, alignment: .top)
        .background(MJColor.deepJade.opacity(0.96))
        .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
        .overlay(alignment: .top) {
            Rectangle().fill(MJColor.gold(0.18)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !gameplaySheetExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    gameplaySheetExpanded = true
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.height < -36 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            gameplaySheetExpanded = true
                        }
                    } else if value.translation.height > 36 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                            gameplaySheetExpanded = false
                        }
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gameplaySheetExpanded ? "Gameplay details" : "Gameplay summary")
        .accessibilityHint(gameplaySheetExpanded ? "Swipe down to collapse." : "Swipe up for map, counts, and events.")
    }

    private var collapsedSheetSummary: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                gameplaySheetExpanded = true
            }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(MJColor.liveRed).frame(width: 7, height: 7)
                    Text(collapsedTrackingStatus)
                        .font(MJFont.ui(13, weight: .semibold))
                    Spacer()
                    Text("\(session.liveTileCount) physical tiles")
                        .font(MJFont.ui(13, weight: .bold))
                }
                .foregroundStyle(MJColor.creamHeading)
                Text("Swipe up for map, counts, and events")
                    .font(MJFont.ui(11, weight: .medium))
                    .foregroundStyle(MJColor.cream(0.58))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .buttonStyle(.plain)
    }

    private var collapsedTrackingStatus: String {
        if session.diagnostics.roiVerification.hasPrefix("verifying ") {
            return "Tracking table · \(session.diagnostics.roiVerification)"
        }
        return session.countSource == .spatialBootstrapping
            ? "Tracking table"
            : "Tracking live table"
    }

    // MARK: - Bracket-reassign confirmation (A3)

    private var reassignDialogPresented: Binding<Bool> {
        Binding(get: { reassignZone != nil }, set: { if !$0 { reassignZone = nil } })
    }

    /// POND chip tapped (`zone == .table`) → "these are my hand"; MINE chip
    /// tapped (`zone == .mine`) → "these are the pond". Same string serves as
    /// both the dialog's title and its confirm button — there's nothing more
    /// to say beyond stating the correction, matching the exit dialog's own
    /// question-as-title convention.
    private var reassignDialogTitle: String {
        switch reassignZone {
        case .table: return "These tiles are actually my hand"
        case .mine:  return "These tiles are actually the pond"
        case nil:    return ""
        }
    }
    private var reassignDialogConfirmLabel: String { reassignDialogTitle }

    // MARK: - State pane

    private func statePane(compression: LiveCompression) -> some View {
        VStack(spacing: 10) {
            LiveSegmentedBar(selection: $tab)
            CorrectionHintBanner()
            tabContent
                .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity)
            HandStrip(
                onTapTile: { id in sheet = .pickHandTile(id) },
                onTapUnknown: { id in sheet = .pickUnknownTile(id) }
            )
            AdviceLine { sheet = .adviceDetail }
            // Always-available one-shot recount affordance, AR mode only.
            if session.isARCaptureActive {
                // Rescan (force a fresh read) + manual hand-end (the AR path's
                // automatic table-clear detector is off, so ending a hand is a
                // deliberate tap).
                HStack(spacing: 18) {
                    Button("Rescan table") { session.rescanTable() }
                    Button("Recenter pond") { session.beginPondRecenter() }
                    Button("End hand") { session.requestHandEnd() }
                }
                .font(MJFont.ui(11, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.55))
                .buttonStyle(.plain)
            }
            // WaitChips fold at `.minimal` — excluded entirely (not just
            // emptied) so their VStack slot + spacing is reclaimed for the
            // tab-content region (e.g. keeps the Counts grid larger at 70%).
            if compression != .minimal {
                WaitChips()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        // Readable-width cap so the pane's rows don't stretch edge-to-edge on a
        // wide iPad; the deepJade background still fills the full width.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MJColor.deepJade)
        .overlay {
            // One end-of-hand prompt for either signal — a self-draw win or a
            // table-clear. `HandEndedCard` branches on which is set.
            if session.handBoundary != nil || session.winDetected != nil {
                HandEndedCard(onScoreHandoff: onScoreHandoff)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85),
                   value: session.handBoundary != nil || session.winDetected != nil)
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .map:
            MapTab(
                onTapUnresolved: { sheet = .assign },
                onTapUnknown: { id in sheet = .pickUnknownTile(id) }
            )
        case .counts: CountsTab { tile in sheet = .adjustCount(tile) }
        case .events: EventsTab { id in sheet = .fixEvent(id) }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ item: CoachLiveSheet) -> some View {
        switch item {
        case .assign:
            UnresolvedAssignSheet()
                .environment(session)
                .presentationDetents([.height(320)])
                .presentationBackground(.clear)
        case let .adjustCount(tile):
            CountAdjustSheet(
                tile: tile,
                initialCount: session.seenHistogram.indices.contains(tile.classIndex) ? session.seenHistogram[tile.classIndex] : 0,
                onApply: { session.setSeenCount(classIndex: tile.classIndex, count: $0) }
            )
            .environment(session)
            .presentationDetents([.height(300)])
            .presentationBackground(.clear)
        case let .fixEvent(id):
            if let event = session.events.first(where: { $0.id == id }) {
                EventFixSheet(event: event)
                    .environment(session)
                    .presentationDetents([.medium])
                    .presentationBackground(.clear)
            }
        case let .pickHandTile(id):
            CorrectionPicker(current: currentHandFace(id), confirmVerb: "Use", onConfirm: { tile in
                session.overrideHandTile(id, as: tile)
                sheet = nil
            }, onRemove: nil)
            .presentationDetents([.height(460)])
            .presentationBackground(.clear)
        case let .pickUnknownTile(id):
            CorrectionPicker(current: nil, confirmVerb: "Set tile", onConfirm: { tile in
                session.overrideSpatialUnknownTile(id, as: tile)
                sheet = nil
            }, onRemove: nil)
            .presentationDetents([.height(460)])
            .presentationBackground(.clear)
        case .adviceDetail:
            AdviceDetailSheet()
                .environment(session)
                .presentationDetents([.medium])
                .presentationBackground(.clear)
        }
    }

    private func currentHandFace(_ id: TrackID) -> Tile? {
        if let match = session.handTiles.first(where: { $0.id == id }) { return match.face }
        if session.drawnTile?.id == id { return session.drawnTile?.face }
        return nil
    }
}
