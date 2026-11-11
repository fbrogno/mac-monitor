import AppKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

struct DataPane: View {
    @Bindable var model: AppModel
    @State private var sizeText = "–"

    var body: some View {
        PaneForm {
            Section {
                LabeledContent("Größe der Verlaufsdatei", value: sizeText)
                LabeledContent("Aufbewahrung") {
                    Text(Self.retentionText).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                }
                switch model.historyState {
                case .unavailable:
                    SettingsNote("Der Verlauf ist gerade nicht verfügbar. MacMonitor misst trotzdem weiter.", tint: Palette.warn)
                default:
                    EmptyView()
                }
                HStack {
                    Button("Verlauf als CSV exportieren …") { exportHistory(.csv) }
                    Button("Als JSON exportieren …") { exportHistory(.json) }
                    Spacer()
                    Button("Verlauf löschen …", role: .destructive, action: confirmDelete)
                }
                .disabled(model.history == nil)
                HStack {
                    SettingsNote("Der Bericht im Dashboard exportiert auch einzelne Zeiträume.")
                    Spacer()
                    Button("Bericht im Dashboard öffnen") { model.openDashboard(section: .report) }
                        .controlSize(.small)
                }
            } header: {
                Text("Verlauf")
            }

            Section {
                HStack {
                    Button("Einstellungen exportieren …", action: exportSettings)
                    Button("Einstellungen importieren …", action: chooseImport)
                    Spacer()
                }
                SettingsNote("Die Datei enthält alle Einstellungen, auch deine eigenen Regeln und Tastenkürzel, als JSON. Du kannst sie auf einem anderen Mac wieder einlesen.")
            } header: {
                Text("Einstellungen sichern")
            }
        }
        .task { refreshSize() }
    }

    static var retentionText: String {
        let r = RetentionPolicy.standard
        func days(_ seconds: TimeInterval) -> String { String(localized: "\(Int(seconds / 86_400)) Tage") }
        return String(localized: "Minutenwerte \(days(r.minute)) · 15-Minuten-Werte \(days(r.quarterHour)) · Tageswerte 2 Jahre · Ereignisse \(days(r.events))")
    }

    private func refreshSize() {
        guard let bytes = model.history?.store.fileSizeBytes(), bytes > 0 else { return }
        sizeText = ReportPane.sizeText(bytes)
    }

    // MARK: History

    private func exportHistory(_ format: DashboardModel.ExportFormat) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "MacMonitor-\(stamp).\(format == .csv ? "csv" : "json")"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        panel.begin { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let now = Date()
                    let bytes = try await model?.dashboard.export(format, from: now.addingTimeInterval(-730 * 86_400), to: now) ?? Data()
                    try bytes.write(to: url, options: .atomic)
                    model?.feedback = Feedback(text: String(localized: "Exportiert nach „\(url.lastPathComponent)“."))
                } catch {
                    model?.feedback = Feedback(text: String(localized: "Der Export ist fehlgeschlagen: \(error.localizedDescription)"), isError: true)
                }
            }
        }
    }

    private func confirmDelete() {
        let dashboard = model.dashboard
        model.ask(Confirmation(
            title: String(localized: "Gesamten Verlauf löschen?"),
            message: String(localized: "Alle gespeicherten Messwerte, Ereignisse und Prozess-Ranglisten werden entfernt. Das lässt sich nicht rückgängig machen."),
            confirmTitle: String(localized: "Verlauf löschen"),
            action: { [weak model] in
                Task { @MainActor in
                    do {
                        try await dashboard.deleteAll()
                        model?.feedback = Feedback(text: String(localized: "Der Verlauf wurde gelöscht."))
                        refreshSize()
                    } catch {
                        model?.feedback = Feedback(text: String(localized: "Der Verlauf konnte nicht gelöscht werden: \(error.localizedDescription)"), isError: true)
                    }
                }
            }), host: .settings)
    }

    // MARK: Settings file

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacMonitor-Einstellungen.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { [weak model] response in
            guard response == .OK, let url = panel.url, let model else { return }
            Task { @MainActor in
                do {
                    try SettingsTransfer.export(model.settings).write(to: url, options: .atomic)
                    model.feedback = Feedback(text: String(localized: "Einstellungen exportiert nach „\(url.lastPathComponent)“."))
                } catch {
                    model.feedback = Feedback(text: String(localized: "Der Export ist fehlgeschlagen: \(error.localizedDescription)"), isError: true)
                }
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak model] response in
            guard response == .OK, let url = panel.url, let model else { return }
            Task { @MainActor in
                do {
                    let imported = try SettingsTransfer.importSettings(from: Data(contentsOf: url))
                    model.ask(Confirmation(
                        title: String(localized: "Einstellungen aus „\(url.lastPathComponent)“ übernehmen?"),
                        message: String(localized: "Deine jetzigen Einstellungen, auch die eigenen Regeln, werden dadurch ersetzt."),
                        confirmTitle: String(localized: "Übernehmen"), isDestructive: false,
                        action: { apply(imported, to: model) }), host: .settings)
                } catch let error as SettingsTransfer.ImportError {
                    model.feedback = Feedback(text: error.message, isError: true)
                } catch {
                    model.feedback = Feedback(text: String(localized: "Die Datei konnte nicht gelesen werden: \(error.localizedDescription)"), isError: true)
                }
            }
        }
    }

    private func apply(_ imported: SettingsTransfer.Imported, to model: AppModel) {
        model.settings = imported.settings
        model.feedback = imported.skippedRules == 0
            ? Feedback(text: String(localized: "Die Einstellungen wurden übernommen."))
            : Feedback(text: String(localized: "Die Einstellungen wurden übernommen. \(imported.skippedRules) unlesbare oder unvollständige eigene Regeln wurden übersprungen."))
    }
}
