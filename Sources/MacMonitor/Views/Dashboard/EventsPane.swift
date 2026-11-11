import MonitorCore
import SwiftUI

/// Incidents (from alert to resolution) filterable by rule, plus the raw log.
struct EventsPane: View {
    let model: AppModel
    let data: DashboardData

    private var rule: String? { model.dashboard.eventRule }

    private var incidents: [Incident] {
        data.incidents.filter { rule == nil || $0.rule == rule }.sorted { $0.start > $1.start }
    }

    private var events: [HistoryEvent] {
        data.events.filter { rule == nil || $0.rule == rule }.sorted { $0.date > $1.date }
    }

    /// Rules that occur in the loaded range, in rule order.
    private var presentRules: [String] {
        Array(Set(data.incidents.map(\.rule) + data.events.map(\.rule))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !presentRules.isEmpty { filter }
            incidentsCard
            logCard
        }
    }

    static func ruleTitle(_ rule: String) -> String { RuleID(rawValue: rule)?.title ?? rule }

    private var filter: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            chip(String(localized: "Alle"), selected: rule == nil) { model.dashboard.eventRule = nil }
            ForEach(presentRules, id: \.self) { id in
                chip(Self.ruleTitle(id), selected: rule == id) { model.dashboard.eventRule = id }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Palette.accent.opacity(0.85) : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var incidentsCard: some View {
        DashCard(String(localized: "Vorfälle"), subtitle: String(localized: "\(incidents.count) im Zeitraum")) {
            if incidents.isEmpty {
                Label("Keine Vorfälle in diesem Zeitraum.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.ok)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(incidents.prefix(100).enumerated()), id: \.offset) { index, incident in
                        if index > 0 { Divider().opacity(0.4) }
                        incidentRow(incident)
                    }
                }
            }
        }
    }

    private func incidentRow(_ incident: Incident) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: incident.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.severity(incident.severity)).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(incident.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.ruleTitle(incident.rule)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(shortStamp(incident.start)).font(.system(size: 12)).monospacedDigit()
                if incident.end == nil {
                    Text("läuft noch").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.warn)
                } else {
                    Text(durationText(incident.duration(asOf: data.to))).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 7)
    }

    private var logCard: some View {
        DashCard(String(localized: "Rohprotokoll"), subtitle: String(localized: "\(events.count) Einträge")) {
            if events.isEmpty {
                UnavailableNote(text: String(localized: "Keine Einträge in diesem Zeitraum."))
            } else {
                // A grid keeps the columns aligned at their natural width; only the title gives way.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(events.prefix(200).enumerated()), id: \.offset) { _, event in
                        GridRow {
                            Text(shortStamp(event.date)).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(.secondary).fixedSize()
                            Text(kindName(event.kind)).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(kindColor(event)).fixedSize()
                            Text(event.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func kindName(_ kind: EventKind) -> String {
        switch kind {
        case .fired: String(localized: "Ausgelöst")
        case .reminder: String(localized: "Erinnerung")
        case .escalated: String(localized: "Verschärft")
        case .resolved: String(localized: "Behoben")
        }
    }

    private func kindColor(_ event: HistoryEvent) -> Color {
        event.kind == .resolved ? Palette.ok : Palette.severity(event.severity)
    }
}
