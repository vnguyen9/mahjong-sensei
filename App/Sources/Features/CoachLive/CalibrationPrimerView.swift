import SwiftUI
import DesignSystem

/// First-run illustrated primer (spec screen 1) — explains WHY Coach needs to
/// learn the table before the camera/AR starts, and doubles as the soft
/// camera-permission ask (the OS prompt fires when the AR session starts, right
/// after "Set up table"). Shown once, ever (`CoachLivePrefs.hasSeenARPrimer`);
/// re-reachable from Settings.
struct CalibrationPrimerView: View {
    var onContinue: () -> Void
    var onCancel: () -> Void

    private let steps: [(n: Int, title: String, detail: String)] = [
        (1, "Mark your hand row", "Tap or pinch one end of your tiles, then the other."),
        (2, "Mark the pond", "Tap or pinch two opposite corners of the discard area."),
        (3, "Review your table", "Move the iPad slightly, then drag any label that does not line up."),
    ]

    var body: some View {
        ZStack {
            ScreenBackground(.live)
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("FIRST-RUN SETUP").eyebrowStyle()
                    Text("Teach Coach your table")
                        .font(MJFont.serif(24, weight: .bold))
                        .foregroundStyle(MJColor.creamHeading)
                        .multilineTextAlignment(.center)
                    Text("Coach watches the game through your camera. First it needs to know where you sit and where the pond is — so it can tell your tiles from everyone else's.")
                        .font(MJFont.ui(13))
                        .foregroundStyle(MJColor.cream(0.65))
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    ForEach(steps, id: \.n) { step in
                        HStack(spacing: 14) {
                            Text("\(step.n)")
                                .font(MJFont.ui(15, weight: .bold))
                                .foregroundStyle(MJColor.inkOnGold)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(MJColor.gold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(MJFont.ui(14, weight: .semibold))
                                    .foregroundStyle(MJColor.creamHeading)
                                Text(step.detail)
                                    .font(MJFont.ui(12))
                                    .foregroundStyle(MJColor.cream(0.6))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text("Camera is used live only. Nothing is recorded or uploaded.")
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.45))
                    .multilineTextAlignment(.center)

                GoldButton("Set up table", action: onContinue)
                TextLink("Cancel", action: onCancel)
            }
            .padding(24)
            .frame(maxWidth: 360)
            .mjCard(cornerRadius: 20)
            .padding(20)
        }
    }
}
