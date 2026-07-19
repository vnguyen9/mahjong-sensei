import SwiftUI
import DesignSystem

/// Prominent center-feed staged-loading card (Lane A1). The LIVE pill's own
/// "Starting…" spinner (`LiveFeedPane.livePill`) proved too subtle — users
/// tapping Start and seeing nothing prominent happen reported "Start
/// tracking did nothing." This overlay is the loud counterpart: it reads
/// `session.startupStage` and shows until the real-path loop promotes it to
/// `.ready` (see `CoachLiveSession.startLoop`'s transition sites).
///
/// Lane B chunk H adds two more branches that read `session.arCapture?
/// .captureStage` DIRECTLY rather than through `startupStage` — both can
/// happen well after the session first reaches `.ready` (a mid-session
/// relocalization, or a "Rescan table" restart), which `startupStage`'s
/// once-through startup waterfall has no room to express. They're checked
/// FIRST, ahead of the `startupStage` gate, so they take over the slot
/// whenever active regardless of where startup itself landed.
///
/// Hidden entirely once none of the three conditions hold — which is also
/// the mock path's permanent state (`CoachLiveMock` never calls `begin()`'s
/// real branch and never sets an `arCapture`), so every MJ_SCREEN scene
/// renders with no overlay at all. The outer `.allowsHitTesting(false)`
/// keeps the plain status cards from blocking the chrome/brackets
/// underneath; the sweep card overrides it locally since its "Done" link
/// needs to be tappable.
struct StartupStatusOverlay: View {
    @Environment(CoachLiveSession.self) private var session
    /// One-time caption on the sweep card's first-ever show (persisted via
    /// `CoachLivePrefs.hasSeenPluggedInHint`, same pattern as
    /// `CorrectionHintBanner`'s `hasSeenCorrectionHint`) — flips true the
    /// instant `captureStage` first transitions to `.sweeping` while the
    /// pref hasn't been marked seen yet, then stays visible for the rest of
    /// this view's lifetime (the whole live session).
    @State private var showsPluggedInHint = false

    var body: some View {
        Group {
            if session.arCapture?.captureStage == .relocalizing {
                statusCard("Hold on — re-finding your table…")
            } else if session.arCapture?.captureStage == .sweeping {
                sweepCard
                    .allowsHitTesting(true)
            } else if session.startupStage != .ready {
                statusCard(stageText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .onChange(of: session.arCapture?.captureStage) { _, newStage in
            guard newStage == .sweeping, !CoachLivePrefs.hasSeenPluggedInHint else { return }
            showsPluggedInHint = true
            CoachLivePrefs.hasSeenPluggedInHint = true
        }
    }

    private var stageText: String {
        switch session.startupStage {
        case .ready: return ""
        case .startingCamera: return "Starting camera…"
        case .findingTable: return "Finding your table — point at it and move slightly"
        case .loadingDetector: return "Loading detector…"
        case .lookingForTiles: return "Looking for tiles…"
        }
    }

    private func statusCard(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(MJColor.gold)
            Text(text)
                .font(MJFont.ui(15, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 220, maxWidth: 260)
        .mjCard(cornerRadius: 20)
        .transition(.opacity)
    }

    /// Lane B chunk H item 1's guided-sweep card — richer than the plain
    /// `statusCard` (a progress affordance + a "Done" link to skip ahead),
    /// shown for both the initial post-lock sweep and any later "Rescan
    /// table" restart (`CoachLiveView`'s state-pane link).
    private var sweepCard: some View {
        VStack(spacing: 14) {
            ProgressView(value: sweepProgress)
                .tint(MJColor.gold)
                .frame(width: 140)
            Text("Table found — pan slowly across it once so I can read every tile")
                .font(MJFont.ui(15, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
                .multilineTextAlignment(.center)
            Button("Done") { session.finishSweepEarly() }
                .font(MJFont.ui(13, weight: .semibold))
                .foregroundStyle(MJColor.gold)
                .buttonStyle(.plain)
            if showsPluggedInHint {
                Text("Long session? Keep the phone plugged in.")
                    .font(MJFont.ui(10.5))
                    .foregroundStyle(MJColor.cream(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(minWidth: 220, maxWidth: 280)
        .mjCard(cornerRadius: 20)
        .transition(.opacity)
    }

    private var sweepProgress: Double {
        Double(session.sweepZonesSeen.count) / Double(TableZoneID.allCases.count)
    }
}
