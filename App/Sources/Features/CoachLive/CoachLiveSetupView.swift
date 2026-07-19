import SwiftUI
import DesignSystem
import MahjongCore
import Recognition

/// Round/seat wind quick setup — two taps over the live feed, no separate
/// screen (UI plan §6). Defaults East/East, matching `CoachLiveSession`'s
/// own defaults, so the common case is literally 0–2 taps + Start.
///
/// Plan A6 (persistence): a fresh (<12h) on-disk archive from a killed
/// session surfaces here as a secondary "Resume session →" option — checked
/// once per appearance (`.task`), never blocking Start.
struct CoachLiveSetupView: View {
    @Environment(CoachLiveSession.self) private var session
    @State private var roundWind: Wind = .east
    @State private var seatWind: Wind = .east
    /// Set synchronously the instant Start is tapped — `begin()` itself
    /// returns immediately (the real loop spins up in the background), so
    /// without this the button gives no feedback at all during the
    /// setup→live crossfade, which is exactly the "Start tracking did
    /// nothing" complaint the staged-loading overlay (A1) also targets.
    @State private var isStarting = false
    /// Non-nil ⇒ a fresh persisted session exists — shows the "Resume
    /// session →" option below Start. Loaded once in `.task`; nil on a
    /// clean setup card (no prior kill, or the archive aged out).
    @State private var resumable: PersistedCoachLiveSession?
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ScreenBackground(.live)
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("Coach Live").font(MJFont.serif(20, weight: .bold)).foregroundStyle(MJColor.creamHeading)
                    Text("Two taps and I'll watch the table.")
                        .font(MJFont.ui(13)).foregroundStyle(MJColor.cream(0.6))
                }

                labeled("Round wind") { WindPicker(selection: $roundWind) }
                labeled("Your seat") { WindPicker(selection: $seatWind) }

                // A local decoration over the shared `GoldButton` (not a
                // change to the component itself — other call sites are
                // unaffected): the title swaps to "Starting…" and a trailing
                // spinner overlays the label while `isStarting`, so the tap
                // reads as instantly registered on slow phones.
                GoldButton(isStarting ? "Starting…" : "Start tracking →") {
                    isStarting = true
                    session.begin(roundWind: roundWind, seatWind: seatWind)
                    onStart()
                }
                .overlay(alignment: .trailing) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(MJColor.inkOnGold)
                            .padding(.trailing, 18)
                    }
                }
                .disabled(isStarting)

                if let resumable {
                    VStack(spacing: 6) {
                        Text(resumeCaption(for: resumable))
                            .font(MJFont.ui(11)).foregroundStyle(MJColor.cream(0.5))
                        SecondaryButton("Resume session →") {
                            isStarting = true
                            session.resume(from: resumable)
                            onStart()
                        }
                        .disabled(isStarting)
                    }
                }

                TextLink("Cancel", action: onCancel)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .mjCard(cornerRadius: 20)
            .padding(20)
        }
        .task { await loadResumable() }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).eyebrowStyle()
            content()
        }
    }

    /// "South round · West seat · saved 14 minutes ago" — winds off the
    /// snapshot, relative time off the app-side `savedAt` wall clock (never
    /// off the tracker's monotonic timestamps, which this view never sees).
    private func resumeCaption(for resumable: PersistedCoachLiveSession) -> String {
        let ago = RelativeDateTimeFormatter().localizedString(for: resumable.savedAt, relativeTo: Date())
        return "\(windEnglish(resumable.snapshot.roundWind)) round · \(windEnglish(resumable.snapshot.mySeatWind)) seat · saved \(ago)"
    }

    private func loadResumable() async {
        #if DEBUG
        // Screenshot hook: force a synthetic resumable with no disk I/O so
        // `MJ_SCREEN=coach-live-setup-resume` renders the resume card
        // deterministically (RootView's mock scenes never write a real
        // archive for this card to legitimately pick up).
        if ProcessInfo.processInfo.environment["MJ_SCREEN"] == "coach-live-setup-resume" {
            resumable = Self.syntheticResumable
            return
        }
        #endif
        resumable = await CoachLiveSessionStore.shared.loadIfFresh()
    }

    #if DEBUG
    private static var syntheticResumable: PersistedCoachLiveSession {
        let snapshot = TrackerSnapshot(mySeatWind: .west, roundWind: .south, handIndex: 1,
                                       dealsSinceRoundStart: 1, events: [], tiles: [], savedAtMono: 0)
        return PersistedCoachLiveSession(snapshot: snapshot, savedAt: Date().addingTimeInterval(-14 * 60))
    }
    #endif
}
