#if DEBUG
import SwiftUI
import DesignSystem

/// Dev-only detector-model selection screen (Debug builds). Lists every bundled
/// ``DetectorModel``; tapping one sets the override the recognizer reads on its next
/// scan. Reached from the Settings "Detector model" row, which in Debug replaces the
/// production "Higher accuracy" toggle. Scales as more models are added.
struct ModelPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ScreenBackground(.content)
            VStack(spacing: 0) {
                MJBackHeader(title: "Detector model") { dismiss() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Which bundled detector the scanner loads. Dev only — overrides “Higher accuracy” in this build; the change takes effect on the next scan.")
                            .font(MJFont.ui(12))
                            .foregroundStyle(MJColor.cream(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)

                        VStack(spacing: 0) {
                            ForEach(Array(DetectorModel.allCases.enumerated()), id: \.element.id) { index, model in
                                if index > 0 { Divider().overlay(MJColor.gold(0.12)) }
                                Button { app.devDetectorModel = model } label: {
                                    modelRow(model, selected: model == app.devDetectorModel)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .mjCard(padding: 4)
                    }
                    .padding(20)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func modelRow(_ model: DetectorModel, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.label)
                    .font(MJFont.ui(14, weight: .medium))
                    .foregroundStyle(MJColor.creamHeading)
                Text(model.subtitle)
                    .font(MJFont.ui(11))
                    .foregroundStyle(MJColor.cream(0.5))
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MJColor.gold)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
#endif
