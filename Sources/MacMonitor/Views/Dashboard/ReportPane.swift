import AppKit
import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// Day or week report with comparison to the period before, export and history management.
struct ReportPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report = data.report {
                summary(report)
                if !report.incidentsByRule.isEmpty { incidentsCard(report) }
                topCard(report.topProcesses)
            } else if model.historyState == .active {
                Text("Bericht wird erstellt …").font(.callout).foregroundStyle(.secondary)
            }
            manageCard
        }
    }

    // MARK: Summary

    private func summary(_ r: HistorySummary) -> some View {
        let delta: HistorySummary.Delta? = if case .delta(let d) = r.comparison { d } else { nil }
        return DashCard(String(localized: "Zusammenfassung"),
                        subtitle: "\(shortStamp(r.interval.start)) – \(shortStamp(r.interval.end))") {
            VStack(alignment: .leading, spacing: 10) {
                if r.cpu == nil && r.memory == nil {
                    Text("In diesem Zeitraum liegen keine Messwerte vor.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        reportRow(String(localized: "CPU Durchschnitt"), r.cpu.map { Format.percent($0.avg) }, delta?.cpuAvg.map(points))
                        reportRow(String(localized: "CPU Spitze"), r.cpu.map { Format.percent($0.peak) }, delta?.cpuPeak.map(points))
                        reportRow(String(localized: "Arbeitsspeicher Durchschnitt"), r.memory.map { Format.percent($0.avg) }, delta?.memoryAvg.map(points))
                        reportRow(String(localized: "Arbeitsspeicher Spitze"), r.memory.map { Format.percent($0.peak) }, delta?.memoryPeak.map(points))
                        reportRow(String(localized: "Zeit unter Speicherdruck"), r.pressureSeconds.map(durationText),
                                  delta?.pressureSeconds.map(signedDuration))
                        reportRow(String(localized: "Vorfälle"), "\(r.incidentCount)", delta.map { signedCount($0.incidentCount) })
                        reportRow(String(localized: "Dauer der Vorfälle"), durationText(r.incidentSeconds),
                                  delta.map { signedDuration($0.incidentSeconds) })
                    }
                }
                comparisonNote(r.comparison)
            }
        }
    }

    private func reportRow(_ label: String, _ value: String?, _ change: String?) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "–").font(.system(size: 12, weight: .medium)).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
            Text(change ?? "").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    @ViewBuilder private func comparisonNote(_ comparison: HistorySummary.Comparison) -> some View {
        switch comparison {
        case .noComparisonData:
            Label("Für die Zeit davor liegen keine Messwerte vor – ein Vergleich ist nicht möglich.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .delta:
            Text("Die Änderung zeigt den Unterschied zur Vorperiode gleicher Länge.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func points(_ value: Double) -> String {
        let text = Format.decimal(abs(value), digits: abs(value) < 10 ? 1 : 0)
        return (value < -0.05 ? "−" : value > 0.05 ? "+" : "±") + text + " Pkt."
    }

    private func signedDuration(_ seconds: TimeInterval) -> String {
        if abs(seconds) < 30 { return "±0 min" }
        return (seconds < 0 ? "−" : "+") + durationText(abs(seconds))
    }

    private func signedCount(_ value: Int) -> String {
        value == 0 ? "±0" : value > 0 ? "+\(value)" : "−\(abs(value))"
    }

    // MARK: Incidents and consumers

    private func incidentsCard(_ r: HistorySummary) -> some View {
        DashCard(String(localized: "Vorfälle je Regel")) {
            VStack(spacing: 6) {
                ForEach(r.incidentsByRule, id: \.rule) { item in
                    HStack {
                        Text(EventsPane.ruleTitle(item.rule)).font(.system(size: 12))
                        Spacer()
                        Text("\(item.count)×").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text(durationText(item.totalSeconds)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func topCard(_ top: TopProcesses) -> some View {
        DashCard(String(localized: "Größte Verbraucher")) {
            if top.byCPU.isEmpty && top.byMemory.isEmpty {
                Text("Keine Prozessdaten in diesem Zeitraum.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    list(String(localized: "CPU-Zeit"), top.byCPU.map { ($0.group, durationText($0.cpuSeconds)) })
                    list(String(localized: "Arbeitsspeicher (Spitze)"),
                         top.byMemory.map { ($0.group, Format.bytes($0.peakFootprintBytes)) })
                }
            }
        }
    }

    private func list(_ title: String, _ rows: [(name: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(rows.prefix(5), id: \.name) { row in
                FactRow(row.name, row.value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Export and delete

    private var manageCard: some View {
        DashCard(String(localized: "Verlauf verwalten")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ActionButton(title: String(localized: "Als CSV exportieren")) { export(.csv) }
                    ActionButton(title: String(localized: "Als JSON exportieren")) { export(.json) }
                    Spacer(minLength: 8)
                    ActionButton(title: String(localized: "Verlauf löschen …"), tint: Palette.critical, action: confirmDelete)
                }
                Text("Der Export enthält alle Messwerte und Ereignisse des gewählten Zeitraums.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().opacity(0.4)
                FactRow(String(localized: "Größe der Verlaufsdatei"), data.fileSizeBytes > 0 ? Self.sizeText(data.fileSizeBytes) : "–")
                FactRow(String(localized: "Aufbewahrung"), String(localized: "Minutenwerte 2 Tage · 15-Minuten-Werte 30 Tage · Tageswerte 2 Jahre"))
                if let error = data.writeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Palette.warn)
                }
            }
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        bytes < 1_048_576 ? "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB" : Format.bytes(UInt64(bytes))
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
                    } catch {
                        model?.feedback = Feedback(text: String(localized: "Der Verlauf konnte nicht gelöscht werden: \(error.localizedDescription)"), isError: true)
                    }
                }
            }), host: .dashboard)
    }

    private func export(_ format: DashboardModel.ExportFormat) {
        let from = data.from, to = data.to
        let panel = NSSavePanel()
        let stamp = from.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "MacMonitor-\(stamp).\(format == .csv ? "csv" : "json")"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        panel.begin { [weak model] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let bytes = try await model?.dashboard.export(format, from: from, to: to) ?? Data()
                    try bytes.write(to: url, options: .atomic)
                    model?.feedback = Feedback(text: String(localized: "Exportiert nach „\(url.lastPathComponent)“."))
                } catch {
                    model?.feedback = Feedback(text: String(localized: "Der Export ist fehlgeschlagen: \(error.localizedDescription)"), isError: true)
                }
            }
        }
    }
}
