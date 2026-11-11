import AppKit
import MonitorCore
import SwiftUI

/// Editor for one custom rule. Saving only works for a valid rule; what is wrong is said in words
/// right at the field.
struct RuleEditor: View {
    @Bindable var model: AppModel
    @State var draft: CustomRule
    let isNew: Bool
    let onClose: () -> Void

    private let initial: CustomRule
    @State private var attempted: Bool
    @State private var shortcutNames: [String]?
    @State private var shortcutsUnavailable = false

    init(model: AppModel, draft: CustomRule, isNew: Bool, showErrorsAtOnce: Bool = false, onClose: @escaping () -> Void) {
        self.model = model
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.onClose = onClose
        initial = draft
        _attempted = State(initialValue: showErrorsAtOnce)
    }

    private var errors: [RuleValidationError] { draft.validate() }
    private var showErrors: Bool { attempted || draft != initial }

    private func messages(_ field: RuleField) -> [String] {
        showErrors ? errors.filter { $0.field == field }.map(\.message) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneForm {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("z. B. Chrome frisst RAM"))
                    FieldError(messages: messages(.name))
                } header: {
                    Text(isNew ? "Neue Regel" : "Regel bearbeiten")
                }

                Section {
                    Picker("Messgröße", selection: $draft.metric) {
                        ForEach(CustomMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if draft.metric.needsProcess { processRow }
                    Picker("Vergleich", selection: $draft.comparison) {
                        ForEach(CustomComparison.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Schwelle") {
                        HStack(spacing: 6) {
                            TextField("Schwelle", value: $draft.threshold, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text(draft.metric.unit.symbol).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        }
                    }
                    FieldError(messages: messages(.threshold))
                    DurationPicker(title: "Mindestens für", value: $draft.minDuration, options: [0, 30, 60, 120, 300, 600, 900, 1800, 3600])
                    FieldError(messages: messages(.duration))
                    Picker("Gilt", selection: $draft.powerCondition) {
                        ForEach(PowerCondition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Wenn")
                }

                Section {
                    Picker("Schweregrad", selection: $draft.severity) {
                        ForEach([Severity.info, .warning, .critical], id: \.self) { Text($0.germanTitle).tag($0) }
                    }
                    DurationPicker(title: "Abklingzeit", value: $draft.cooldown, options: [300, 900, 1800, 3600, 10_800, 43_200, 86_400])
                    SettingsNote("Nach einem Auslösen führt die Regel ihre Aktionen frühestens nach dieser Zeit wieder aus.")
                    FieldError(messages: messages(.cooldown))
                } header: {
                    Text("Wie wichtig")
                }

                Section {
                    ForEach(draft.actions.indices, id: \.self) { index in
                        ActionRow(action: $draft.actions[index], shortcutNames: shortcutNames, shortcutsUnavailable: shortcutsUnavailable) {
                            draft.actions.remove(at: index)
                        }
                    }
                    Menu {
                        ForEach(RuleAction.Kind.allCases, id: \.self) { kind in
                            Button(kind.title) { draft.actions.append(Self.newAction(kind)) }
                        }
                    } label: {
                        Label("Aktion hinzufügen", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    FieldError(messages: messages(.actions))
                } header: {
                    Text("Dann")
                }
            }

            Divider()
            HStack {
                Button("Abbrechen", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Speichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .task(id: draft.actions.contains { $0.kind == .runShortcut }) { await loadShortcutsIfNeeded() }
    }

    // MARK: Process choice

    private var processRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Programm") {
                HStack(spacing: 6) {
                    TextField("Programm", text: Binding(get: { draft.processName ?? "" }, set: { draft.processName = $0 }),
                              prompt: Text("Name des Programms"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 190)
                    Menu {
                        ForEach(runningNames, id: \.self) { name in
                            Button(name) { draft.processName = name }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Laufendes Programm auswählen")
                }
            }
            FieldError(messages: messages(.process))
        }
    }

    /// Apps that are open now plus the biggest processes, as suggestions for the name field.
    private var runningNames: [String] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        let processes = (model.snapshot?.processes ?? []).prefix(30).map { $0.appName.isEmpty ? $0.name : $0.appName }
        return Array(Set(apps + processes)).filter { !ProtectedProcesses.isProtected(name: $0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Actions

    private static func newAction(_ kind: RuleAction.Kind) -> RuleAction {
        switch kind {
        case .showNotification: .showNotification
        case .runShortcut: .runShortcut(name: "")
        case .quitProcess: .quitProcess(askFirst: true)
        case .throttleProcess: .throttleProcess
        case .openURL: .openURL("https://")
        }
    }

    private func loadShortcutsIfNeeded() async {
        guard draft.actions.contains(where: { $0.kind == .runShortcut }), shortcutNames == nil, !shortcutsUnavailable else { return }
        if let names = await ShortcutRunner.list() { shortcutNames = names } else { shortcutsUnavailable = true }
    }

    // MARK: Save

    private func save() {
        var rule = draft
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.processName = rule.metric.needsProcess ? rule.processName?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        rule.actions = rule.actions.map { action in
            switch action {
            case .runShortcut(let name): .runShortcut(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            case .openURL(let text): .openURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
            default: action
            }
        }
        guard rule.isValid else {
            draft = rule
            attempted = true
            return
        }
        if let index = model.settings.customRules.firstIndex(where: { $0.id == rule.id }) {
            model.settings.customRules[index] = rule
        } else {
            model.settings.customRules.append(rule)
        }
        onClose()
    }
}

private struct ActionRow: View {
    @Binding var action: RuleAction
    let shortcutNames: [String]?
    let shortcutsUnavailable: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(action.kind.title).fontWeight(.medium).frame(width: 150, alignment: .leading)
            detail
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Aktion entfernen")
        }
    }

    @ViewBuilder private var detail: some View {
        switch action {
        case .showNotification:
            SettingsNote("Zeigt eine Mitteilung mit dem Namen der Regel.")
        case .runShortcut:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Kurzbefehl", text: shortcutName, prompt: Text("Name des Kurzbefehls"))
                        .labelsHidden()
                    Menu {
                        ForEach(shortcutNames ?? [], id: \.self) { name in Button(name) { shortcutName.wrappedValue = name } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled((shortcutNames ?? []).isEmpty)
                    .help("Kurzbefehl auswählen")
                }
                if shortcutsUnavailable {
                    SettingsNote("Die Liste der Kurzbefehle ist nicht verfügbar. Gib den Namen von Hand ein.")
                } else if shortcutNames == nil {
                    SettingsNote("Lade Kurzbefehle …")
                }
            }
        case .quitProcess(let askFirst):
            Toggle("Vorher fragen", isOn: Binding(get: { askFirst }, set: { action = .quitProcess(askFirst: $0) }))
        case .throttleProcess:
            SettingsNote("Senkt die Priorität des Programms. Sie bleibt niedrig, bis es neu gestartet wird.")
        case .openURL:
            TextField("Adresse", text: urlText, prompt: Text("https://example.com"))
                .labelsHidden()
        }
    }

    private var shortcutName: Binding<String> {
        Binding(get: { if case .runShortcut(let n) = action { n } else { "" } }, set: { action = .runShortcut(name: $0) })
    }

    private var urlText: Binding<String> {
        Binding(get: { if case .openURL(let t) = action { t } else { "" } }, set: { action = .openURL($0) })
    }
}
