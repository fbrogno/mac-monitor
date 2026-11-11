import MonitorCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var ignoredText = ""
    @State private var autoUpdate = false

    private let minutes: [TimeInterval] = [60, 120, 180, 300, 600]

    var body: some View {
        Form {
            Section("Allgemein") {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .disabled(!LoginItem.isInstalled)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
                if !LoginItem.isInstalled {
                    Text("Verfügbar, sobald die App im Ordner „Programme“ liegt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Menüleiste", selection: $model.settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Zusätzlicher Hinweis am aktiven Bildschirm", selection: $model.settings.overlayMode) {
                    ForEach(OverlayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Erinnern, wenn es anhält", selection: $model.settings.reminderInterval) {
                    Text("alle 15 min").tag(TimeInterval(900))
                    Text("alle 30 min").tag(TimeInterval(1800))
                    Text("jede Stunde").tag(TimeInterval(3600))
                    Text("nie").tag(TimeInterval(365 * 86400))
                }
                HStack {
                    Button("Testmitteilung senden") { model.sendTest() }
                    Spacer()
                    Button("Mitteilungs-Einstellungen …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }

            Section("Prozesse") {
                ruleToggle(.runawayProcess)
                if model.settings.isEnabled(.runawayProcess) {
                    Stepper(value: $model.settings.processCPUThreshold, in: 50...800, step: 10) {
                        LabeledContent("Ab CPU", value: Format.percent(model.settings.processCPUThreshold))
                    }
                    durationPicker("Für mindestens", $model.settings.processCPUSustain)
                }
                ruleToggle(.memoryHog)
                if model.settings.isEnabled(.memoryHog) {
                    Stepper(value: $model.settings.memoryHogFraction, in: 0.1...0.6, step: 0.05) {
                        LabeledContent("Ab Anteil am RAM", value: Format.percent(model.settings.memoryHogFraction * 100))
                    }
                }
            }

            Section("System") {
                ruleToggle(.cpuHigh)
                if model.settings.isEnabled(.cpuHigh) {
                    Stepper(value: $model.settings.cpuTotalThreshold, in: 50...100, step: 5) {
                        LabeledContent("Ab Gesamt-CPU", value: Format.percent(model.settings.cpuTotalThreshold))
                    }
                    durationPicker("Für mindestens", $model.settings.cpuTotalSustain)
                }
                ruleToggle(.memoryPressure)
                ruleToggle(.swap)
                if model.settings.isEnabled(.swap) {
                    Stepper(value: $model.settings.swapThresholdGB, in: 1...64, step: 1) {
                        LabeledContent("Ab Swap", value: "\(Int(model.settings.swapThresholdGB)) GB")
                    }
                }
                ruleToggle(.thermal)
                ruleToggle(.disk)
                if model.settings.isEnabled(.disk) {
                    Stepper(value: $model.settings.diskMinFreeGB, in: 5...200, step: 5) {
                        LabeledContent("Warnen unter", value: "\(Int(model.settings.diskMinFreeGB)) GB frei")
                    }
                }
                ruleToggle(.network)
                ruleToggle(.sleepBlocker)
                if model.settings.isEnabled(.sleepBlocker) {
                    Picker("Im Akkubetrieb länger als", selection: $model.settings.sleepBlockerSustain) {
                        ForEach([TimeInterval(600), 1800, 3600], id: \.self) { Text(Format.duration($0)).tag($0) }
                    }
                }
            }

            Section("Updates") {
                LabeledContent("MacMonitor", value: UpdateController.versionText)
                Toggle("Automatisch nach Updates suchen", isOn: $autoUpdate)
                    .disabled(!model.updater.isConfigured)
                    .onChange(of: autoUpdate) { _, on in model.updater.automaticallyChecks = on }
                HStack {
                    Button("Nach Updates suchen …") { model.updater.checkForUpdates() }
                        .disabled(!model.updater.isConfigured)
                    if !model.updater.isConfigured {
                        Text("In dieser Version nicht verfügbar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Prozessnamen, durch Komma getrennt", text: $ignoredText, axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit(saveIgnored)
                    .onChange(of: ignoredText) { _, _ in saveIgnored() }
            } header: {
                Text("Ignorierte Prozesse")
            } footer: {
                Text("Diese Prozesse lösen keine Prozess-Warnungen aus. Der genaue Name steht in der Prozessliste.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
        .onAppear {
            ignoredText = model.settings.ignoredProcesses.joined(separator: ", ")
            launchAtLogin = LoginItem.isEnabled
            autoUpdate = model.updater.isConfigured && model.updater.automaticallyChecks
        }
    }

    private func ruleToggle(_ rule: RuleID) -> some View {
        Toggle(rule.title, isOn: Binding(
            get: { model.settings.isEnabled(rule) },
            set: { on in
                if on { model.settings.enabledRules.insert(rule) } else { model.settings.enabledRules.remove(rule) }
            }))
    }

    private func durationPicker(_ title: String, _ value: Binding<TimeInterval>) -> some View {
        Picker(title, selection: value) {
            ForEach(minutes, id: \.self) { Text(Format.duration($0)).tag($0) }
        }
    }

    private func saveIgnored() {
        model.settings.ignoredProcesses = ignoredText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
