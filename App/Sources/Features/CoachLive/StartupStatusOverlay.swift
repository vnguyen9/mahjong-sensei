import SwiftUI
import DesignSystem

/// Prominent center-feed staged-loading card (Lane A1). The LIVE pill's own
/// "Starting…" spinner (`LiveFeedPane.livePill`) proved too subtle — users
/// tapping Start and seeing nothing prominent happen reported "Start
/// tracking did nothing." This overlay is the loud counterpart: it reads
/// `session.startupStage` and shows until the real-path loop promotes it to
/// `.ready` (see `CoachLiveSession.startLoop`'s transition sites).
///
/// Relocalization reads `session.arCapture?.captureStage` directly because
/// it can happen after the once-through startup waterfall reaches `.ready`.
///
/// Hidden entirely once neither condition holds — which is also
/// the mock path's permanent state (`CoachLiveMock` never calls `begin()`'s
/// real branch and never sets an `arCapture`), so every MJ_SCREEN scene
/// renders with no overlay at all. The outer `.allowsHitTesting(false)`
/// keeps the status cards from blocking the chrome/brackets underneath.
struct StartupStatusOverlay: View {
    @Environment(CoachLiveSession.self) private var session

    var body: some View {
        Group {
            if session.spatialTrackingHealth == .trackingLimited
                || session.spatialTrackingHealth == .depthUnavailable {
                recoveringTrackingCard
            } else if session.arCapture?.captureStage == .relocalizing {
                relocalizingCard
            } else if session.startupStage != .ready {
                statusCard(stageText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
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

    /// Workstream G (spec screen 14): a calmer replacement for the plain
    /// `statusCard` during a mid-session relocalization — same card chrome,
    /// but a reassuring two-line copy ("still saved") instead of a bare
    /// "hold on" — since world-anchored geometry survives a relocalization,
    /// this really is just a brief interruption, not data loss. Paired with
    /// `LiveFeedPane`'s feed-dim scrim (`session.isRelocalizing`), which
    /// drives from the same `captureStage == .relocalizing` state so the two
    /// show/hide in lockstep with no separate timer.
    private var relocalizingCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(MJColor.gold)
            Text("Point back at the table — resuming automatically")
                .font(MJFont.ui(15, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
                .multilineTextAlignment(.center)
            Text("Your zones are still saved.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 220, maxWidth: 280)
        .mjCard(cornerRadius: 20)
        .transition(.opacity)
    }

    private var recoveringTrackingCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder.trianglebadge.exclamationmark")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(MJColor.gold)
            Text("Recovering table tracking…")
                .font(MJFont.ui(15, weight: .semibold))
                .foregroundStyle(MJColor.creamHeading)
            Text("Keep the table in view. Coach Live will recalibrate if tracking does not recover within 5 seconds.")
                .font(MJFont.ui(11.5))
                .foregroundStyle(MJColor.cream(0.65))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 240, maxWidth: 300)
        .mjCard(cornerRadius: 20)
        .transition(.opacity)
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

}
