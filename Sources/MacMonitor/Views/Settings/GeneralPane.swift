import MonitorCore
import SwiftUI

struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var notificationWarning = ""

    var body: some View {
        PaneForm {
            Section {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .disabled(!LoginItem.isInstalled)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
                if !LoginItem.isInstalled {
                    SettingsNote("Verfügbar, sobald die App im Ordner „Programme“ liegt.")
                }
                LabeledContent("Menüleiste") {
                    HStack(spacing: 10) {
                        Text(menuBarSummary).foregroundStyle(.secondary)
                        Button("Ändern …") { model.settingsTab = .menuBar }
                    }
                }
                LabeledContent("Sprache") {
                    Text("Folgt der Systemsprache").foregroundStyle(.secondary)
                }
            } header: {
                Text("Allgemein")
            }

            Section {
                Picker("Zusätzliches Hinweisfenster", selection: $model.settings.overlayMode) {
                    ForEach(OverlayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsNote("macOS zeigt Mitteilungen nur auf dem Hauptbildschirm. Das Hinweisfenster erscheint zusätzlich dort, wo du gerade arbeitest.")
                Picker("Erinnern, wenn es anhält", selection: $model.settings.reminderInterval) {
                    Text("alle 15 min").tag(TimeInterval(900))
                    Text("alle 30 min").tag(TimeInterval(1800))
                    Text("jede Stunde").tag(TimeInterval(3600))
                    Text("nie").tag(TimeInterval(365 * 86400))
                }
                HStack {
                    Button("Testmitteilung senden") { model.sendTest() }
                    Spacer()
                    Button("Mitteilungs-Einstellungen von macOS …") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
                if !notificationWarning.isEmpty { SettingsNote(verbatim: notificationWarning, tint: Palette.warn) }
            } header: {
                Text("Meldungen")
            }
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
        .task {
            let status = await model.notifier.currentStatus()
            notificationWarning = status == .denied
                ? String(localized: "Mitteilungen sind für MacMonitor in den Systemeinstellungen ausgeschaltet. Ohne sie siehst du nur das Hinweisfenster.")
                : ""
        }
    }

    private var menuBarSummary: String {
        model.settings.menuBarItems.isEmpty
            ? String(localized: "Nur Symbol")
            : model.settings.menuBarItems.map(\.title).joined(separator: ", ")
    }
}
