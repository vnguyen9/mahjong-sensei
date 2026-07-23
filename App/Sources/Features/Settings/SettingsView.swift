import SwiftUI
import UIKit
import DesignSystem

/// Lane 5 · Settings (spec screen 22). Wrapped in its own `NavigationStack`; the
/// "House rules" row pushes `HouseRulesView` (spec screen 21).
struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return NavigationStack {
            ZStack {
                ScreenBackground(.content)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Settings")
                            .font(MJFont.serif(26, weight: .bold))
                            .foregroundStyle(MJColor.creamHeading)
                            .padding(.top, 8)

                        VStack(spacing: 0) {
                            SettingRow(name: "Language", value: "English")
                            Divider().overlay(MJColor.gold(0.12))
                            NavigationLink { TileThemeSettingsView() } label: {
                                SettingRow(name: "Appearance", value: app.tileTheme?.displayName ?? "Auto")
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(MJColor.gold(0.12))
                            NavigationLink { HouseRulesView() } label: {
                                SettingRow(name: "House rules", value: "Family default")
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(MJColor.gold(0.12))
                            SettingRow(name: "Camera", value: "Allowed")
                        }
                        .mjCard(padding: 4)

                        VStack(spacing: 0) {
                            NavigationLink { AdvancedSettingsView() } label: {
                                SettingRow(name: "Advanced", value: "")
                            }
                            .buttonStyle(.plain)
                        }
                        .mjCard(padding: 4)

                        VStack(spacing: 0) {
                            SettingToggleRow(
                                name: "Blur the live feed",
                                subtitle: "Coach Live softens the camera for privacy.",
                                isOn: $app.blursLiveFeed)
                        }
                        .mjCard(padding: 4)

                        VStack(spacing: 0) {
                            SettingRow(name: "About", value: "")
                            Divider().overlay(MJColor.gold(0.12))
                            SettingRow(name: "Send feedback", value: "")
                        }
                        .mjCard(padding: 4)

                        Text("Everything runs on-device · no account · images never leave your phone.")
                            .font(MJFont.ui(11))
                            .foregroundStyle(MJColor.cream(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 6)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Advanced remains discoverable in every build. Experimental gameplay stays
/// Debug-only until it is ready to become a supported user-facing feature.
struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var coachCoordinator = ScanCoordinator()

    var body: some View {
        @Bindable var coachCoordinator = coachCoordinator
        return NavigationStack(path: $coachCoordinator.path) {
            ZStack {
                ScreenBackground(.content)
                VStack(spacing: 0) {
                    MJBackHeader(title: "Advanced") { dismiss() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(spacing: 0) {
                            Button {
                                coachCoordinator.startCoachLive()
                            } label: {
                                SettingRow(
                                    name: "Coach Live",
                                    value: coachCoordinator.isCoachLiveAvailable
                                        ? "Start session" : "Requires LiDAR iPad"
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!coachCoordinator.isCoachLiveAvailable)
                            .accessibilityHint("Starts live table coaching and calibration.")
                            Divider().overlay(MJColor.gold(0.12))
                            NavigationLink { DetectionSettingsView() } label: {
                                SettingRow(
                                    name: "Detection settings",
                                    value: detectionSummary
                                )
                            }
                            .buttonStyle(.plain)
                            #if DEBUG
                            // PROMOTION: Move this link outside DEBUG when the experimental game is ready for production users.
                            Divider().overlay(MJColor.gold(0.12))
                            NavigationLink { GameLauncherView() } label: {
                                SettingRow(name: "Mahjong game · Experimental", value: "")
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(MJColor.gold(0.12))
                            NavigationLink { ModelLabView() } label: {
                                SettingRow(name: "Model Lab · Live detectors", value: "")
                            }
                            .buttonStyle(.plain)
                            #endif
                            }
                            .mjCard(padding: 4)

                            Text("Advanced options affect on-device detection and experimental tools.")
                                .font(MJFont.ui(12))
                                .foregroundStyle(MJColor.cream(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(20)
                        .padding(.bottom, 100)
                    }
                }
            }
            .navigationDestination(for: ScanRoute.self) { route in
                switch route {
                case .correct: CorrectView()
                case .context: ContextView()
                case .result:
                    ResultView(session: coachCoordinator.session) {
                        coachCoordinator.restart()
                    }
                }
            }
        }
        .environment(coachCoordinator)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $coachCoordinator.coachLive) { session in
            CoachLiveFlowView(
                session: session,
                onExit: { coachCoordinator.endCoachLive() },
                onScoreHandoff: { coachCoordinator.beginScoreHandoff(from: session) }
            )
        }
    }

    private var detectionSummary: String {
        #if DEBUG
        app.devDetectorModel.label
        #else
        app.prefersHighAccuracy ? "Higher accuracy" : "Standard"
        #endif
    }
}

struct DetectionSettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        return ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Detection settings") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        #if DEBUG
                        Text("Detector model")
                            .font(MJFont.ui(13, weight: .semibold))
                            .foregroundStyle(MJColor.creamHeading)
                        Text("Choose which bundled detector loads on the next scan. This direct model control is available in Debug builds.")
                            .font(MJFont.ui(12))
                            .foregroundStyle(MJColor.cream(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            ForEach(Array(DetectorModel.allCases.enumerated()), id: \.element.id) { index, model in
                                if index > 0 { Divider().overlay(MJColor.gold(0.12)) }
                                Button {
                                    app.devDetectorModel = model
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    DetectorModelSettingRow(
                                        model: model,
                                        selected: model == app.devDetectorModel
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(model == app.devDetectorModel ? "Selected" : "Not selected")
                            }
                        }
                        .mjCard(padding: 4)

                        VStack(spacing: 0) {
                            SettingToggleRow(
                                name: "Tracker Developer Mode",
                                subtitle: "Shows the Pro input, exact confidence, timing, and guide diagnostics after a Tracker scan.",
                                isOn: $app.trackerDeveloperMode
                            )
                        }
                        .mjCard(padding: 4)
                        #else
                        VStack(spacing: 0) {
                            SettingToggleRow(
                                name: "Higher accuracy",
                                subtitle: "Reads tiles more precisely. A little slower.",
                                isOn: $app.prefersHighAccuracy
                            )
                        }
                        .mjCard(padding: 4)
                        #endif
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

#if DEBUG
private struct DetectorModelSettingRow: View {
    let model: DetectorModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.label)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                Text(model.subtitle)
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .foregroundStyle(MJColor.gold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
#endif

/// A settings row with a trailing switch and an optional explanatory subtitle.
struct SettingToggleRow: View {
    let name: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                Text(subtitle)
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(MJColor.gold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct SettingRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack {
            Text(name)
                .font(MJFont.ui(14, weight: .medium))
                .foregroundStyle(MJColor.creamHeading)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(MJFont.ui(13))
                    .foregroundStyle(MJColor.gold)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MJColor.cream(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
