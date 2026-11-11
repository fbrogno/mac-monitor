import MonitorCore
import SwiftUI

/// List of the user's own rules; one at a time is opened in the editor.
struct CustomRulesPane: View {
    @Bindable var model: AppModel
    @State private var editing: CustomRule?
    @State private var isNew = false
    private let previewing: Bool

    init(model: AppModel, previewRule: CustomRule? = nil) {
        self.model = model
        _editing = State(initialValue: previewRule)
        _isNew = State(initialValue: previewRule != nil)
        previewing = previewRule != nil
    }

    var body: some View {
        if let draft = editing {
            RuleEditor(model: model, draft: draft, isNew: isNew, showErrorsAtOnce: previewing) { editing = nil }
                .id(draft.id)
        } else {
            list
        }
    }

    private var list: some View {
        PaneForm {
            Section {
                if model.settings.customRules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Noch keine eigenen Regeln").fontWeight(.medium)
                        SettingsNote("Mit einer eigenen Regel sagst du MacMonitor, worauf es achten soll und was dann passieren soll, zum Beispiel eine Mitteilung zeigen, einen Kurzbefehl starten oder ein Programm drosseln. Starte am besten mit einer Vorlage.")
                    }
                    .padding(.vertical, 4)
                }
                ForEach($model.settings.customRules) { $rule in
                    CustomRuleRow(rule: $rule, onEdit: { isNew = false; editing = rule }, onDelete: { confirmDelete(rule) })
                }
            } header: {
                Text("Eigene Regeln")
            } footer: {
                HStack {
                    Menu {
                        Button("Leere Regel") { add(CustomRule(name: "", metric: .cpuTotal, threshold: 80)) }
                        Divider()
                        Section("Aus Vorlage") {
                            ForEach(CustomRule.templates) { template in
                                Button(template.name) { add(template.instantiated()) }
                            }
                        }
                    } label: {
                        Label("Regel hinzufügen", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    Spacer()
                }
            }

            Section {
                SettingsNote("Eigene Regeln melden nur das, was du in ihren Aktionen festlegst. Programme des Systems und MacMonitor selbst werden nie beendet oder gedrosselt. „Prozess beenden“ fragt auf Wunsch vorher nach.")
            }
        }
    }

    private func add(_ rule: CustomRule) {
        isNew = true
        editing = rule
    }

    private func confirmDelete(_ rule: CustomRule) {
        model.ask(Confirmation(
            title: String(localized: "Regel „\(rule.name)“ löschen?"),
            message: String(localized: "Die Regel wird entfernt. Das lässt sich nicht rückgängig machen."),
            confirmTitle: String(localized: "Löschen"),
            action: { [weak model] in model?.settings.customRules.removeAll { $0.id == rule.id } }), host: .settings)
    }
}

private struct CustomRuleRow: View {
    @Binding var rule: CustomRule
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $rule.isEnabled) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!rule.isValid)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name.isEmpty ? String(localized: "Ohne Namen") : rule.name).fontWeight(.medium)
                SettingsNote(LocalizedStringKey(RuleSummary.text(for: rule)))
                if !rule.isValid {
                    SettingsNote("Diese Regel ist unvollständig und läuft nicht. Öffne sie, um das zu beheben.", tint: Palette.warn)
                }
            }
            Spacer(minLength: 8)
            Button(action: onEdit) { Image(systemName: "pencil") }.help("Bearbeiten")
            Button(action: onDelete) { Image(systemName: "trash") }.help("Löschen")
        }
        .buttonStyle(.borderless)
    }
}

/// One sentence that says what a rule does.
enum RuleSummary {
    static func text(for rule: CustomRule) -> String {
        let subject = rule.metric.needsProcess && !(rule.processName ?? "").isEmpty
            ? "\(rule.metric.title) von „\(rule.processName ?? "")“" : rule.metric.title
        let condition = String(localized: "\(subject) \(rule.comparison.title) \(rule.metric.format(rule.threshold)), mindestens \(DurationPicker.text(rule.minDuration)).")
        let actions = rule.actions.map { $0.kind.title }.joined(separator: ", ")
        return actions.isEmpty ? condition : condition + " " + String(localized: "Dann: \(actions).")
    }
}
