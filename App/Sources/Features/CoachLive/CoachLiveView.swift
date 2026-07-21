import SwiftUI
import UIKit
import Combine
import DesignSystem
import MahjongCore
import Recognition

/// Compression level of the gameplay sheet's flexible tab-content region,
/// derived from its measured height. `LiveSegmentedBar`, `HandStrip`,
/// and `AdviceLine` are fixed-height rows; the tab-content region is the only
/// `.frame(maxHeight: .infinity)` member — so the VStack's own math enforces
/// "map shrinks first, hand + advice never hide".
enum LiveCompression: Equatable { case full, compact, minimal }

/// The iPad drawer has room to make its editing surface genuinely larger, not
/// just taller.  Keep these values in one value type so every live control
/// responds to the same detent change and the phone layout stays exactly as
/// dense as before.
struct LiveControlMetrics: Equatable {
    let scale: CGFloat
    let segmentedHeight: CGFloat
    let paneWidthCap: CGFloat
    let countTileWidthCap: CGFloat
    let handTileWidth: CGFloat
    let pondTileWidth: CGFloat
    let meldTileWidth: CGFloat
    let minimumEditHitTarget: CGFloat

    static let phone = LiveControlMetrics(
        scale: 1,
        segmentedHeight: 30,
        paneWidthCap: 560,
        countTileWidthCap: 22,
        handTileWidth: 22,
        pondTileWidth: 16,
        meldTileWidth: 15,
        minimumEditHitTarget: 0
    )

    fileprivate static func iPad(detent: GameplayDrawerDetent) -> LiveControlMetrics {
        switch detent {
        case .small:
            return LiveControlMetrics(scale: 1.1, segmentedHeight: 40, paneWidthCap: 620,
                                      countTileWidthCap: 24, handTileWidth: 24,
                                      pondTileWidth: 18, meldTileWidth: 17,
                                      minimumEditHitTarget: 44)
        case .medium:
            return LiveControlMetrics(scale: 1.25, segmentedHeight: 46, paneWidthCap: 680,
                                      countTileWidthCap: 28, handTileWidth: 28,
                                      pondTileWidth: 20, meldTileWidth: 19,
                                      minimumEditHitTarget: 44)
        case .big:
            return LiveControlMetrics(scale: 1.45, segmentedHeight: 52, paneWidthCap: 760,
                                      countTileWidthCap: 32, handTileWidth: 32,
                                      pondTileWidth: 24, meldTileWidth: 22,
                                      minimumEditHitTarget: 48)
        }
    }
}

private struct LiveCompressionKey: EnvironmentKey {
    static let defaultValue: LiveCompression = .full
}
extension EnvironmentValues {
    var liveCompression: LiveCompression {
        get { self[LiveCompressionKey.self] }
        set { self[LiveCompressionKey.self] = newValue }
    }
}

private struct LiveControlMetricsKey: EnvironmentKey {
    static let defaultValue = LiveControlMetrics.phone
}
extension EnvironmentValues {
    var liveControlMetrics: LiveControlMetrics {
        get { self[LiveControlMetricsKey.self] }
        set { self[LiveControlMetricsKey.self] = newValue }
    }
}

/// One presentation idiom for all of Coach Live's sheets (UI plan §12).
enum CoachLiveSheet: Identifiable, Hashable {
    case assign
    case adjustCount(Tile)
    case fixEvent(UUID)
    case pickHandTile(TrackID)
    case editSpatialTrack(TrackID)
    case adviceDetail

    var id: String {
        switch self {
        case .assign:                 return "assign"
        case let .adjustCount(tile):  return "adjust-\(tile.classIndex)"
        case let .fixEvent(id):       return "fix-\(id)"
        case let .pickHandTile(id):   return "pick-\(id.raw)"
        case let .editSpatialTrack(id): return "spatial-\(id.raw)"
        case .adviceDetail:           return "advice"
        }
    }
}

/// The gameplay drawer always leaves a useful control surface on screen.
/// In particular, iPad never collapses it to a handle-only strip: Map,
/// Counts, and Events remain immediately reachable while the camera stays
/// full-screen behind it.
fileprivate enum GameplayDrawerDetent: Int, Comparable {
    case small
    case medium
    case big

    static func < (lhs: GameplayDrawerDetent, rhs: GameplayDrawerDetent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var next: GameplayDrawerDetent { GameplayDrawerDetent(rawValue: rawValue + 1) ?? self }
    var previous: GameplayDrawerDetent { GameplayDrawerDetent(rawValue: rawValue - 1) ?? self }
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
    @State private var gameplayDrawerDetent: GameplayDrawerDetent
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
        // Both devices start with the camera-first lowest detent. On iPad the
        // lowest detent still contains the selected Map / Counts / Events
        // content; iPhone retains its original lightweight summary.
        _gameplayDrawerDetent = State(initialValue: .small)
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

                LiveTrackIndicatorOverlay(session: session) { trackID in
                    sheet = .editSpatialTrack(trackID)
                }
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
        .onChange(of: tab) { _, _ in
            // The iPad peek already displays the selected tab's real content,
            // so changing tabs must not unexpectedly move the drawer. Keep
            // the legacy promotion only for a phone state where content is
            // intentionally summarized.
            if UIDevice.current.userInterfaceIdiom != .pad,
               gameplayDrawerDetent == .small {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    gameplayDrawerDetent = .medium
                }
            }
        }
    }

    // MARK: - Full-screen AR + gameplay sheet

    private func gameplaySheet(height: CGFloat) -> some View {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let metrics = isPad ? LiveControlMetrics.iPad(detent: gameplayDrawerDetent) : .phone
        // Small is a useful floor rather than a hidden handle. iPad's three
        // stops deliberately prioritize camera visibility: ~one third,
        // slightly above one third, and just above half of the screen.
        let smallHeight: CGFloat = isPad ? min(330, height * 0.32) : 132
        let mediumHeight: CGFloat = isPad
            ? max(smallHeight + 20, height * 0.34)
            : min(height * 0.58, max(360, height - 180))
        let bigHeight: CGFloat = isPad
            ? max(mediumHeight + 80, min(height * 0.56, height - 110))
            : min(height * 0.72, max(480, height - 120))
        let currentHeight: CGFloat
        switch gameplayDrawerDetent {
        case .small: currentHeight = smallHeight
        case .medium: currentHeight = mediumHeight
        case .big: currentHeight = bigHeight
        }

        return VStack(spacing: 0) {
            drawerHandle

            if !isPad, gameplayDrawerDetent == .small {
                phoneSmallSummary
            } else if gameplayDrawerDetent == .big {
                // Leave a realistic budget for the fixed tab/hand/action rows
                // before deciding which secondary controls Big can fit.
                let bigCompression = compression(for: currentHeight - 100)
                statePane(compression: bigCompression, metrics: metrics)
                    .environment(\.liveCompression, bigCompression)
            } else {
                compactDrawerPane(metrics: metrics)
                    .environment(\.liveCompression, .compact)
            }
        }
        .frame(maxWidth: .infinity, minHeight: currentHeight, maxHeight: currentHeight, alignment: .top)
        .environment(\.liveControlMetrics, metrics)
        .background(MJColor.deepJade.opacity(0.96))
        .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
        .overlay(alignment: .top) {
            Rectangle().fill(MJColor.gold(0.18)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gameplayDrawerDetent == .small ? "Gameplay controls" : "Gameplay details")
        .accessibilityHint(gameplayDrawerDetent == .small
            ? "Map, Counts, and Events remain available. Swipe up for more detail."
            : "Swipe down for a smaller gameplay drawer.")
    }

    /// The drag target is isolated from the drawer content so scrolling Events
    /// or tapping tiles never changes detents accidentally. Its 44pt frame is
    /// large enough for touch and VoiceOver while the visible capsule remains
    /// visually quiet.
    private var drawerHandle: some View {
        Capsule()
            .fill(MJColor.cream(0.35))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    gameplayDrawerDetent = gameplayDrawerDetent.next
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height < -36 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                                gameplayDrawerDetent = gameplayDrawerDetent.next
                            }
                        } else if value.translation.height > 36 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                                gameplayDrawerDetent = gameplayDrawerDetent.previous
                            }
                        }
                    }
            )
            .accessibilityLabel("Resize gameplay drawer")
            .accessibilityValue(drawerDetentAccessibilityValue)
            .accessibilityHint("Swipe up or down to resize the drawer")
            .accessibilityAddTraits(.isButton)
    }

    private var drawerDetentAccessibilityValue: String {
        switch gameplayDrawerDetent {
        case .small: return "Small"
        case .medium: return "Medium"
        case .big: return "Big"
        }
    }

    /// Small and Medium intentionally contain only the primary table surface:
    /// tab selection, a terse tracking row, the selected content, and the
    /// player's hand. Secondary advice, correction tips, actions, and waits
    /// are reserved for Big so these two stops cannot overstuff or overlap.
    private func compactDrawerPane(metrics: LiveControlMetrics) -> some View {
        VStack(spacing: 8) {
            LiveSegmentedBar(selection: $tab)
            HStack(spacing: 8) {
                Circle().fill(MJColor.liveRed).frame(width: 7, height: 7)
                Text(collapsedTrackingStatus)
                    .font(MJFont.ui(13, weight: .semibold))
                Spacer()
                Text("\(session.liveTileCount) physical tiles")
                    .font(MJFont.ui(13, weight: .bold))
            }
            .foregroundStyle(MJColor.creamHeading)
            tabContent
                .frame(maxWidth: .infinity,
                       minHeight: gameplayDrawerDetent == .small ? 44 : 84,
                       maxHeight: .infinity)
            HandStrip(
                onTapTile: openHandTileEditor,
                onTapUnknown: { id in sheet = .editSpatialTrack(id) }
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: metrics.paneWidthCap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var phoneSmallSummary: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                gameplayDrawerDetent = .medium
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

    private func statePane(compression: LiveCompression, metrics: LiveControlMetrics) -> some View {
        VStack(spacing: 10) {
            LiveSegmentedBar(selection: $tab)
            if compression == .full {
                CorrectionHintBanner()
            }
            tabContent
                .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity)
            HandStrip(
                onTapTile: openHandTileEditor,
                onTapUnknown: { id in sheet = .editSpatialTrack(id) }
            )
            if compression != .minimal {
                AdviceLine { sheet = .adviceDetail }
            }
            // Always-available one-shot recount affordance, AR mode only.
            if session.isARCaptureActive {
                // Rescan (force a fresh read) + manual hand-end (the AR path's
                // automatic table-clear detector is off, so ending a hand is a
                // deliberate tap).
                HStack(spacing: 18) {
                    Button("Rescan table") {
                        guard !session.recountState.isActive else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        session.requestRecount()
                    }
                        .frame(minHeight: metrics.minimumEditHitTarget)
                        .accessibilityHint("Requests one table recount after the camera is still")
                    Button("Recenter pond") { session.beginPondRecenter() }
                        .frame(minHeight: metrics.minimumEditHitTarget)
                    Button("End hand") { session.requestHandEnd() }
                        .frame(minHeight: metrics.minimumEditHitTarget)
                }
                .font(MJFont.ui(11 * metrics.scale, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.55))
                .buttonStyle(.plain)
            }
            // WaitChips fold at `.minimal` — excluded entirely (not just
            // emptied) so their VStack slot + spacing is reclaimed for the
            // tab-content region (e.g. keeps the Counts grid larger at 70%).
            if compression == .full {
                WaitChips()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        // Readable-width cap so the pane's rows don't stretch edge-to-edge on a
        // wide iPad; the deepJade background still fills the full width.
        .frame(maxWidth: metrics.paneWidthCap)
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
                onTapUnknown: { id in sheet = .editSpatialTrack(id) }
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
            NavigationStack {
                CoachLiveFacePicker(
                    current: currentHandFace(id),
                    statistics: { tile in
                        session.fallbackTileStatistics(
                            for: tile,
                            replacingHandTrack: id
                        )
                    },
                    onUse: { tile in
                        session.overrideHandTile(id, as: tile)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        sheet = nil
                    }
                )
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.clear)
        case let .editSpatialTrack(id):
            SpatialTrackEditorSheet(session: session, trackID: id)
            .presentationDetents([.medium, .large])
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

    private func openHandTileEditor(_ id: TrackID) {
        sheet = session.spatialTrackSnapshot(id) == nil
            ? .pickHandTile(id)
            : .editSpatialTrack(id)
    }
}

/// Compact, tappable production markers for the authoritative LiDAR census.
/// `TimelineView` drives display-cadence reprojection only; the recognizer and
/// census continue running at their existing cadence.
private struct LiveTrackIndicatorOverlay: View {
    let session: CoachLiveSession
    let onSelect: (TrackID) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            GeometryReader { proxy in
                ZStack {
                    ForEach(session.liveSpatialIndicatorTracks, id: \.id) { track in
                        if let point = session.projectSpatialTrack(
                            track,
                            viewportSize: proxy.size
                        ) {
                            Button {
                                UISelectionFeedbackGenerator().selectionChanged()
                                onSelect(TrackID(raw: track.id.value))
                            } label: {
                                SpatialTrackMarker(track: track)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .position(point)
                            .accessibilityLabel(track.accessibilityLabel)
                            .accessibilityHint("Opens face, region, and removal controls for this physical tile.")
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

private struct SpatialTrackMarker: View {
    let track: CensusTrackSnapshot

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.48))
                .frame(width: 23, height: 23)
            Circle()
                .stroke(track.semanticZone.indicatorColor, lineWidth: 3)
                .frame(width: 21, height: 21)
            if track.face == nil {
                Text("?")
                    .font(.caption2.bold())
                    .foregroundStyle(Color(uiColor: .systemOrange))
            } else {
                Circle()
                    .fill(Color(uiColor: .systemBlue))
                    .frame(width: 9, height: 9)
            }
        }
        .opacity(track.lifecycle == .confirmed ? 1 : 0.45)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }
}

/// One immediately-applied editor for a census identity. Region changes save
/// as soon as they are selected; choosing a face with Use publishes and pins
/// that face before closing the complete editor.
private struct SpatialTrackEditorSheet: View {
    let session: CoachLiveSession
    let trackID: TrackID

    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveConfirmation = false
    private let retirementCheck = Timer.publish(
        every: 0.25,
        on: .main,
        in: .common
    ).autoconnect()

    private var track: CensusTrackSnapshot? {
        session.spatialTrackSnapshot(trackID)
    }

    private var originalFace: Tile? {
        guard case let .tile(tile)? = track?.face else { return nil }
        return tile
    }

    private var suggestedFace: Tile? {
        guard case let .tile(tile)? = track?.faceSuggestion?.face else { return nil }
        return tile
    }

    private var displayedFace: Tile? { originalFace ?? suggestedFace }

    private var currentZone: SemanticZoneID {
        track?.semanticZone ?? .boundaryUnresolved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground(.content)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        faceCard
                        statisticsSection
                    }
                    .padding(20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Physical tile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SpatialEditorRoute.self) { _ in
                CoachLiveFacePicker(
                    current: displayedFace,
                    statistics: { tile in
                        session.censusTileStatistics(
                            for: tile,
                            applying: CensusTrackCorrectionDraft(
                                trackID: CensusTrackID(trackID.raw),
                                face: tile,
                                semanticZone: currentZone
                            )
                        )
                    },
                    onUse: { tile in
                        // "Use" confirms the face and region immediately and
                        // closes the complete editor, not just this route.
                        commit(face: tile)
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(retirementCheck) { _ in
            guard session.spatialTrackSnapshot(trackID) != nil else {
                dismiss()
                return
            }
        }
        .confirmationDialog(
            "Remove this physical tile?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove track", role: .destructive) {
                session.removeSpatialTrack(trackID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tile disappears from Coach Live immediately. It can be detected again if it remains on the table.")
        }
    }

    private var faceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Face")
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
            HStack(spacing: 14) {
                if let face = displayedFace {
                    MahjongTileView(face, theme: .jade, width: 46)
                        .opacity(originalFace == nil ? 0.72 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: .systemOrange), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 46, height: 62)
                        .overlay {
                            Text("?")
                                .font(.title2.bold())
                                .foregroundStyle(Color(uiColor: .systemOrange))
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(faceStatusTitle)
                        .font(MJFont.ui(14, weight: .semibold))
                        .foregroundStyle(MJColor.creamHeading)
                    Text(faceStatusDetail)
                        .font(MJFont.ui(12))
                        .foregroundStyle(MJColor.cream(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                faceActions
            }
            if let statistics = quickStatistics {
                quickStats(statistics)
            }
            Divider().overlay(MJColor.gold(0.12))
            regionPicker
            Divider().overlay(MJColor.gold(0.12))
            removeTrackButton
        }
        .mjCard()
    }

    /// Face commitment is intentionally beside the tile it changes. The
    /// previous navigation-only control made an unresolved question mark look
    /// like it had already been saved, while the real action lived one screen
    /// deeper in the picker.
    @ViewBuilder
    private var faceActions: some View {
        if let suggestedFace, originalFace == nil, !requiresManualResolution {
            VStack(spacing: 6) {
                Button {
                    commit(face: suggestedFace)
                } label: {
                    Text("Use \(suggestedFace.code)")
                        .frame(minWidth: 86, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(MJColor.jadeAccent)
                .accessibilityLabel("Use suggested face \(suggestedFace.code)")
                .accessibilityHint("Confirms this face and closes the editor")

                facePickerLink(title: "Change", systemImage: "square.grid.3x3")
            }
        } else if originalFace != nil, !isUserPinned {
            VStack(spacing: 6) {
                Button {
                    commit(face: originalFace)
                } label: {
                    Text("This is correct")
                        .frame(minWidth: 102, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(MJColor.jadeAccent)
                .accessibilityLabel("This tile is correct")
                .accessibilityHint("Pins the recognized face and closes the editor")

                facePickerLink(title: "Change", systemImage: "square.grid.3x3")
            }
        } else {
            facePickerLink(
                title: requiresManualResolution ? "Choose correct face" : (originalFace == nil ? "Choose face" : "Change face"),
                systemImage: "square.grid.3x3"
            )
        }
    }

    private func facePickerLink(title: String, systemImage: String) -> some View {
        NavigationLink(value: SpatialEditorRoute.face) {
            Label(title, systemImage: systemImage)
                .font(MJFont.ui(12, weight: .semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(MJColor.gold)
        .accessibilityLabel(title)
        .accessibilityHint("Opens the tile face picker")
    }

    private var faceStatusTitle: String {
        guard let track else { return "Face unavailable" }
        if track.faceIsUserPinned { return "Confirmed by you" }
        if originalFace != nil {
            return "Recognition confidence · \(percent(track.faceConfidence))"
        }
        if track.requiresManualFaceResolution {
            return "Conflicting confident reads"
        }
        if let suggestion = track.faceSuggestion,
           case .tile(let tile) = suggestion.face {
            return "Suggested: \(tile.code) · \(percent(suggestion.confidence))"
        }
        return "Face needed"
    }

    private var isUserPinned: Bool { track?.faceIsUserPinned == true }
    private var requiresManualResolution: Bool { track?.requiresManualFaceResolution == true }

    private var faceStatusDetail: String {
        guard let track else { return "This physical track is no longer available." }
        if track.requiresManualFaceResolution {
            return "Choose the correct face. This tile is not counted by face until you confirm it."
        }
        if originalFace != nil {
            return "This face contributes to Coach Live counts and statistics."
        }
        if track.faceSuggestion != nil {
            if track.strongFaceReadCount == 1,
               track.faceSuggestion?.confidence ?? 0 >= CoachLiveRecognitionPolicy.facePublicationConfidence {
                return "Needs one more confident read. Not counted until confirmed."
            }
            return "Not counted until confirmed. Review the suggestion before using it."
        }
        return "Choose the physical tile face without changing its AR identity."
    }

    private var quickStatistics: CoachLiveTileStatistics? {
        guard let face = displayedFace else { return nil }
        return session.censusTileStatistics(
            for: face,
            applying: CensusTrackCorrectionDraft(
                trackID: CensusTrackID(trackID.raw),
                face: face,
                semanticZone: currentZone
            )
        )
    }

    private func quickStats(_ statistics: CoachLiveTileStatistics) -> some View {
        let preview = originalFace == nil
        return VStack(alignment: .leading, spacing: 8) {
            if preview {
                Text("If used")
                    .font(MJFont.ui(10, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemOrange))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    quickStat(
                        "\(statistics.insight.liveCopies)",
                        "copies live"
                    )
                    Divider().frame(height: 34).overlay(MJColor.gold(0.15))
                    quickStat(
                        TileInsight.percent(statistics.insight.drawChance),
                        "next-draw odds"
                    )
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    quickStat("\(statistics.insight.liveCopies)", "copies live")
                    quickStat(TileInsight.percent(statistics.insight.drawChance), "next-draw odds")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(preview ? "If used. " : "")\(statistics.insight.liveCopies) copies live. \(TileInsight.percent(statistics.insight.drawChance)) next draw odds."
        )
    }

    private func quickStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(MJFont.serif(18, weight: .bold))
                .foregroundStyle(MJColor.lightGold)
            Text(label)
                .font(MJFont.ui(10, weight: .medium))
                .foregroundStyle(MJColor.cream(0.56))
        }
    }

    private var regionPicker: some View {
        HStack(spacing: 12) {
            Label("Table region", systemImage: "square.grid.2x2")
                .font(MJFont.ui(14, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
            Spacer(minLength: 8)
            Circle()
                .fill(currentZone.indicatorColor)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Picker("Table region", selection: regionBinding) {
                ForEach(SemanticZoneID.allCases, id: \.self) { zone in
                    Text(zone.editorName).tag(zone)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(MJColor.gold)
            .accessibilityLabel("Table region")
            .accessibilityValue(currentZone.editorName)
            .accessibilityHint("Changes this physical tile's table region immediately")
        }
        .frame(minHeight: 44)
    }

    private var regionBinding: Binding<SemanticZoneID> {
        Binding(
            get: { currentZone },
            set: { newZone in
                guard track != nil, newZone != currentZone else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                session.correctSpatialTrack(trackID, face: nil, zone: newZone)
            }
        )
    }

    private func percent(_ confidence: Float) -> String {
        "\(Int((max(0, min(1, confidence)) * 100).rounded()))%"
    }

    private var removeTrackButton: some View {
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove track", systemImage: "trash")
                .font(MJFont.ui(14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemRed))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(uiColor: .systemRed).opacity(0.55))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove physical tile")
        .accessibilityHint("Asks for confirmation before removing this track")
    }

    private func commit(face: Tile?) {
        guard track != nil else { return }
        session.correctSpatialTrack(trackID, face: face, zone: currentZone)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    @ViewBuilder
    private var statisticsSection: some View {
        if let displayedFace {
            VStack(alignment: .leading, spacing: 10) {
                if originalFace == nil {
                    Label(
                        "Preview for suggestion · not counted until Use",
                        systemImage: "questionmark.diamond"
                    )
                    .font(MJFont.ui(11, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                }
                CoachLiveTileStatsView(
                    statistics: session.censusTileStatistics(
                        for: displayedFace,
                        applying: CensusTrackCorrectionDraft(
                            trackID: CensusTrackID(trackID.raw),
                            face: displayedFace,
                            semanticZone: currentZone
                        )
                    )
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tile statistics")
                    .font(MJFont.ui(13, weight: .semibold))
                    .foregroundStyle(MJColor.creamHeading)
                Text("Choose a face to preview its live copies, draw odds, combinations, and pattern examples before using it.")
                    .font(MJFont.ui(12))
                    .foregroundStyle(MJColor.cream(0.66))
                    .fixedSize(horizontal: false, vertical: true)
                if let inventory = session.censusGameplayInventory(),
                   inventory.unknownFaceTrackCount > 0 {
                    unknownFaceDisclosure(inventory.unknownFaceTrackCount)
                }
            }
            .mjCard()
        }
    }
}

private enum SpatialEditorRoute: Hashable { case face }

/// The UI-ready slice of either a census inventory or the explicit mock/debug
/// fallback. Counts are values only: no editor control can step or mutate
/// them directly.
private struct CoachLiveTileStatistics {
    let tile: Tile
    let table: Int
    let yours: Int
    let unassigned: Int
    let unknownFaceCount: Int
    let resolvedCounts: [Tile: Int]

    var insight: LiveTileInsight {
        LiveTileInsight(tile: tile, resolvedCounts: resolvedCounts)
    }
}

/// Scrollable face selection with a continuously recomputed draft preview.
/// The navigation-bar Use action is the only face confirmation control.
private struct CoachLiveFacePicker: View {
    let current: Tile?
    let statistics: (Tile) -> CoachLiveTileStatistics
    let onUse: (Tile) -> Void

    @State private var suit: SuitTab
    @State private var selection: Tile

    init(
        current: Tile?,
        statistics: @escaping (Tile) -> CoachLiveTileStatistics,
        onUse: @escaping (Tile) -> Void
    ) {
        let initial = current ?? .m(1)
        self.current = current
        self.statistics = statistics
        self.onUse = onUse
        _suit = State(initialValue: SuitTab(for: initial))
        _selection = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TileFaceSelectionGrid(suit: $suit, selection: $selection)
                    CoachLiveTileStatsView(statistics: statistics(selection))
                }
                .padding(20)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Choose face")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Use") { onUse(selection) }
                    .fontWeight(.semibold)
                    .accessibilityHint("Saves this face and the selected table region")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CoachLiveTileStatsView: View {
    let statistics: CoachLiveTileStatistics

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 92), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Resolved copies")
                    .font(MJFont.ui(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(MJColor.gold(0.9))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    readOnlyCount(statistics.table, label: "Table")
                    readOnlyCount(statistics.yours, label: "Yours")
                    if statistics.unassigned > 0 {
                        readOnlyCount(statistics.unassigned, label: "Unassigned")
                    }
                    readOnlyCount(statistics.insight.liveCopies, label: "Live")
                }
                if statistics.unknownFaceCount > 0 {
                    unknownFaceDisclosure(statistics.unknownFaceCount)
                }
            }
            .mjCard()

            LiveTileStatsView(insight: statistics.insight)
        }
        .accessibilityElement(children: .contain)
    }

    private func readOnlyCount(_ value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(MJFont.serif(20, weight: .bold))
                .foregroundStyle(MJColor.lightGold)
            Text(label)
                .font(MJFont.ui(11, weight: .medium))
                .foregroundStyle(MJColor.cream(0.58))
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value) resolved copies")
    }
}

private func unknownFaceDisclosure(_ count: Int) -> some View {
    Label(
        "Based on resolved faces · \(count) physical tiles still need faces",
        systemImage: "questionmark.diamond"
    )
    .font(MJFont.ui(11, weight: .medium))
    .foregroundStyle(Color(uiColor: .systemOrange))
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityLabel(
        "Statistics based on resolved faces. \(count) physical tiles still need faces."
    )
}

private extension CoachLiveSession {
    @MainActor
    func censusTileStatistics(
        for tile: Tile,
        applying draft: CensusTrackCorrectionDraft? = nil
    ) -> CoachLiveTileStatistics {
        guard let inventory = censusGameplayInventory(applying: draft) else {
            return fallbackTileStatistics(for: tile, replacingHandTrack: nil)
        }
        return CoachLiveTileStatistics(
            tile: tile,
            table: inventory.tableCount(for: tile),
            yours: inventory.yoursCount(for: tile),
            unassigned: inventory.unassignedCount(for: tile),
            unknownFaceCount: inventory.unknownFaceTrackCount,
            resolvedCounts: inventory.resolvedCounts
        )
    }

    /// Face-only statistics for mock/debug sessions where a hand tile has no
    /// physical census identity. The draft replaces exactly one current hand
    /// face so candidate odds never double-count the edited tile.
    func fallbackTileStatistics(
        for tile: Tile,
        replacingHandTrack trackID: TrackID?
    ) -> CoachLiveTileStatistics {
        var tableCounts: [Tile: Int] = [:]
        var yoursCounts: [Tile: Int] = [:]
        var unassignedCounts: [Tile: Int] = [:]

        for entry in pond { tableCounts[entry.tile, default: 0] += 1 }
        for melds in opponentMelds.values {
            for face in melds.flatMap(\.tiles) { tableCounts[face, default: 0] += 1 }
        }
        for tracked in handTiles { yoursCounts[tracked.face, default: 0] += 1 }
        if let drawnTile { yoursCounts[drawnTile.face, default: 0] += 1 }
        for face in myMelds.flatMap(\.tiles) { yoursCounts[face, default: 0] += 1 }
        for item in unresolved {
            if let face = item.tile { unassignedCounts[face, default: 0] += 1 }
        }

        if let trackID {
            let oldFace = handTiles.first(where: { $0.id == trackID })?.face
                ?? (drawnTile?.id == trackID ? drawnTile?.face : nil)
            if let oldFace {
                yoursCounts[oldFace] = max(0, yoursCounts[oldFace, default: 0] - 1)
                if yoursCounts[oldFace] == 0 { yoursCounts.removeValue(forKey: oldFace) }
            }
            yoursCounts[tile, default: 0] += 1
        }

        let resolvedCounts = tableCounts
            .merging(yoursCounts, uniquingKeysWith: +)
            .merging(unassignedCounts, uniquingKeysWith: +)
        return CoachLiveTileStatistics(
            tile: tile,
            table: tableCounts[tile, default: 0],
            yours: yoursCounts[tile, default: 0],
            unassigned: unassignedCounts[tile, default: 0],
            unknownFaceCount: spatialUnknownTiles.count + unresolved.filter { $0.tile == nil }.count,
            resolvedCounts: resolvedCounts
        )
    }
}

private struct SettingLikeAction: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(MJFont.ui(14, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(MJColor.cream(0.5))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private extension CensusTrackSnapshot {
    var accessibilityLabel: String {
        let state = face == nil ? "Face needed" : "Recognized tile"
        let held = lifecycle == .confirmed ? "" : ", temporarily held"
        return "\(state), \(semanticZone.editorName)\(held)"
    }
}

private extension SemanticZoneID {
    var editorName: String {
        switch self {
        case .mineHand: return "My hand"
        case .mineMeld: return "My revealed tiles"
        case .tablePond: return "Pond"
        case .tableRevealedLeft: return "Left player revealed tiles"
        case .tableRevealedFar: return "Far player revealed tiles"
        case .tableRevealedRight: return "Right player revealed tiles"
        case .boundaryUnresolved: return "Unresolved"
        case .ignoredWall: return "Ignore wall or tile back"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .mineHand: return Color(uiColor: .systemYellow)
        case .mineMeld: return Color(uiColor: .systemOrange)
        case .tablePond: return Color(uiColor: .systemCyan)
        case .tableRevealedLeft: return Color(uiColor: .systemPurple)
        case .tableRevealedFar: return Color(uiColor: .systemTeal)
        case .tableRevealedRight: return Color(uiColor: .systemPink)
        case .boundaryUnresolved: return Color(uiColor: .systemOrange)
        case .ignoredWall: return Color(uiColor: .systemGray)
        }
    }
}
