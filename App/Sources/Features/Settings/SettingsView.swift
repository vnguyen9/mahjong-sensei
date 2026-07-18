import SwiftUI
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
                            SettingRow(name: "Appearance", value: "Jade · Dark")
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
                            SettingToggleRow(
                                name: "Higher accuracy",
                                subtitle: "Reads tiles more precisely. A little slower.",
                                isOn: $app.prefersHighAccuracy)
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

/// A settings row with a trailing switch and an optional explanatory subtitle.
private struct SettingToggleRow: View {
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
        .contentShape(Rectangle())
    }
}

private struct SettingRow: View {
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
        .contentShape(Rectangle())
    }
}
