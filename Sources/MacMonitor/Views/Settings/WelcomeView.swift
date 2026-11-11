import MonitorCore
import SwiftUI
import UserNotifications

/// Shown once on the first start (and via `macmonitor://welcome`): what the app does, notifications,
/// launch at login and the menu bar display, then "Fertig".
struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var launchAtLogin = LoginItem.isEnabled
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIconView(size: 64, padded: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Willkommen bei MacMonitor").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Dein Mac im Blick, ohne dass du hinschauen musst.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                point("waveform.path.ecg", "Misst im Hintergrund", "CPU, Speicher, Temperatur, Akku, Netzwerk und mehr, sparsam und ohne Hilfsprozesse.")
                point("bell.badge", "Meldet sich nur bei Auffälligem", "Ein hängendes Programm, zu wenig Platz oder Hitze lösen eine Mitteilung aus. Sonst bleibt es still.")
                point("wand.and.stars", "Hilft beim Beheben", "Aus der Meldung heraus kannst du Programme beenden oder neu starten. Eigene Regeln erledigen das auf Wunsch von selbst.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mitteilungen").fontWeight(.medium)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(statusTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if status == .notDetermined {
                        Button("Mitteilungen erlauben") {
                            model.notifier.requestAuthorization()
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
                        }
                    } else if status == .denied {
                        Button("Systemeinstellungen öffnen") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                    }
                }
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .disabled(!LoginItem.isInstalled)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
                if !LoginItem.isInstalled {
                    Text("Verfügbar, sobald die App im Ordner „Programme“ liegt.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("In der Menüleiste zeigen").fontWeight(.medium)
                    Spacer()
                    Picker("In der Menüleiste zeigen", selection: styleBinding) {
                        Text("Nur Symbol").tag(MenuBarStyle.icon)
                        Text("Symbol und CPU").tag(MenuBarStyle.iconAndCPU)
                        Text("Symbol, CPU und RAM").tag(MenuBarStyle.iconCPUAndMemory)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Zahlen in der Menüleiste kosten etwas Strom. Mehr Auswahl gibt es später in den Einstellungen.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Button("Einstellungen …") { model.settingsTab = .general; model.showWindow("settings") }
                Spacer()
                Button("Fertig") {
                    Welcome.markSeen()
                    if status == .notDetermined { model.notifier.requestAuthorization() }
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task { await refresh() }
    }

    private var styleBinding: Binding<MenuBarStyle> {
        Binding(get: { model.settings.menuBarStyle }, set: { model.settings.menuBarStyle = $0 })
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: String(localized: "Erlaubt. Meldungen erscheinen als Mitteilung.")
        case .denied: String(localized: "In den Systemeinstellungen ausgeschaltet. Ohne Mitteilungen siehst du nur das Hinweisfenster.")
        default: String(localized: "Noch nicht gefragt. Ohne Erlaubnis kann MacMonitor keine Mitteilungen senden.")
        }
    }

    private var statusTint: Color { status == .denied ? Palette.warn : .secondary }

    private func refresh() async { status = await model.notifier.currentStatus() }
}
