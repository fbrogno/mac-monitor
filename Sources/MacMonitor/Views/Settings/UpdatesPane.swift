import MonitorCore
import SwiftUI

enum AppLinks {
    static let github = URL(string: "https://github.com/fbrogno/mac-monitor")!
    static let license = URL(string: "https://github.com/fbrogno/mac-monitor#lizenz")!
    static var copyright: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String) ?? "© 2026 Fabio Brogno"
    }
}

/// "Updates & Info": version, update switch, links and the privacy statement.
struct UpdatesPane: View {
    @Bindable var model: AppModel
    @State private var autoUpdate = false

    var body: some View {
        PaneForm {
            Section {
                LabeledContent("MacMonitor", value: UpdateController.versionText)
                Toggle("Automatisch nach Updates suchen", isOn: $autoUpdate)
                    .disabled(!model.updater.isConfigured)
                    .onChange(of: autoUpdate) { _, on in model.updater.automaticallyChecks = on }
                HStack {
                    Button("Nach Updates suchen …") { model.updater.checkForUpdates() }
                        .disabled(!model.updater.isConfigured)
                    if !model.updater.isConfigured { SettingsNote("In dieser Version nicht verfügbar.") }
                }
            } header: {
                Text("Updates")
            }

            Section {
                Link(destination: AppLinks.github) { Label("MacMonitor auf GitHub", systemImage: "arrow.up.right.square") }
                Link(destination: AppLinks.license) { Label("Lizenz: privat, alle Rechte vorbehalten", systemImage: "doc.text") }
                HStack {
                    Button("Willkommensfenster zeigen") { model.handle(.welcome) }
                    Spacer()
                }
            } header: {
                Text("Info")
            }

            Section {
                Label {
                    Text("MacMonitor sendet keine Daten; nur die Update-Prüfung fragt GitHub.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "lock.shield") }
                SettingsNote("Alle Messwerte und der Verlauf bleiben auf diesem Mac.")
            } header: {
                Text("Datenschutz")
            }
        }
        .onAppear { autoUpdate = model.updater.isConfigured && model.updater.automaticallyChecks }
    }
}
