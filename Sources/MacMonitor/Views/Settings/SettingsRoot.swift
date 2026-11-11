import MonitorCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, menuBar, rules, customRules, quiet, ignored, data, about

    var id: String { rawValue }

    /// Name used in `macmonitor://settings/<slug>`.
    var slug: String { rawValue }

    init?(slug: String) {
        switch slug.lowercased() {
        case "allgemein": self = .general
        case "menueleiste", "menüleiste": self = .menuBar
        case "regeln": self = .rules
        case "eigene-regeln", "eigene": self = .customRules
        case "ruhe": self = .quiet
        case "ignoriert": self = .ignored
        case "daten": self = .data
        case "info", "updates": self = .about
        default:
            guard let tab = SettingsTab(rawValue: slug) else { return nil }
            self = tab
        }
    }

    var title: String {
        switch self {
        case .general: String(localized: "Allgemein")
        case .menuBar: String(localized: "Menüleiste")
        case .rules: String(localized: "Regeln")
        case .customRules: String(localized: "Eigene Regeln")
        case .quiet: String(localized: "Ruhe")
        case .ignored: String(localized: "Ignoriert")
        case .data: String(localized: "Daten")
        case .about: String(localized: "Updates & Info")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .rules: "bell.badge"
        case .customRules: "wand.and.stars"
        case .quiet: "moon"
        case .ignored: "eye.slash"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .menuBar: Palette.accent
        case .rules: Palette.warn
        case .customRules: .purple
        case .quiet: .indigo
        case .ignored: .secondary
        case .data: Palette.ok
        case .about: .blue
        }
    }
}

/// The settings window: sidebar like the system settings, one pane at a time. Drawn in plain SwiftUI
/// (no split-view container) so the same view also renders for the README images.
struct SettingsRoot: View {
    @Bindable var model: AppModel
    /// Opens the rule editor with this rule at once (README image only).
    var previewRule: CustomRule?

    init(model: AppModel, previewRule: CustomRule? = nil) {
        self.model = model
        self.previewRule = previewRule
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .overlay(alignment: .bottom) {
            if let feedback = model.feedback {
                FeedbackBanner(feedback: feedback) { model.feedback = nil }
                    .frame(maxWidth: 520)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
            }
        }
        .confirmationAlert(model: model, host: .settings)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == model.settingsTab
                Button { model.settingsTab = tab } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .frame(width: 210)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder private var detail: some View {
        switch model.settingsTab {
        case .general: GeneralPane(model: model)
        case .menuBar: MenuBarPane(model: model)
        case .rules: RulesPane(model: model)
        case .customRules: CustomRulesPane(model: model, previewRule: previewRule)
        case .quiet: QuietPane(model: model)
        case .ignored: IgnoredPane(model: model)
        case .data: DataPane(model: model)
        case .about: UpdatesPane(model: model)
        }
    }
}
