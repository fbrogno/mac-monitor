import MonitorCore
import SwiftUI

/// The pane of the selected history area with its notices. Title, range and feedback belong to the window;
/// rendered directly for the README.
struct DashboardDetail: View {
    let model: AppModel
    /// Apps shown expanded; only the offline renderer sets this.
    var expandedApps: Set<String> = []

    private var dashboard: DashboardModel { model.dashboard }

    private var data: DashboardData {
        dashboard.data ?? DashboardData(
            key: dashboard.currentKey,
            from: Date().addingTimeInterval(-dashboard.range.duration), to: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            historyNotice
            pane
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var historyNotice: some View {
        switch model.historyState {
        case .unavailable(let reason):
            NoticeBanner(symbol: "exclamationmark.triangle.fill", tint: Palette.warn,
                         text: String(localized: "Der Verlauf ist nicht verfügbar, die App misst weiter, speichert aber nichts. \(reason)"))
        default:
            if let error = data.error ?? data.writeError {
                NoticeBanner(symbol: "exclamationmark.triangle.fill", tint: Palette.warn,
                             text: String(localized: "Beim Speichern oder Lesen des Verlaufs trat ein Fehler auf: \(error)"))
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch dashboard.section {
        case .overview: OverviewPane(model: model, data: data)
        case .cpu: CPUPane(model: model, data: data)
        case .memory: MemoryPane(model: model, data: data)
        case .energy: EnergyPane(model: model, data: data)
        case .sensors: SensorsPane(model: model, data: data)
        case .network: NetworkPane(model: model, data: data)
        case .apps: AppsPane(model: model, data: data, expanded: expandedApps)
        case .events: EventsPane(model: model, data: data)
        case .report: ReportPane(model: model, data: data)
        }
    }
}

struct NoticeBanner: View {
    var symbol: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Series helpers shared by the panes.
extension DashboardData {
    func line(_ key: MetricKey, _ name: String, _ color: Color, band: Bool = true) -> ChartLine {
        ChartLine(id: key.rawValue, name: name, color: color, points: points(key), showsBand: band)
    }

    func hasSeries(_ keys: MetricKey...) -> Bool { keys.contains { !points($0).measured.isEmpty } }
}

/// The same points multiplied by `factor`, e.g. a 0…1 share drawn as percent.
func scaled(_ points: [HistoryPoint], by factor: Double) -> [HistoryPoint] {
    points.map {
        HistoryPoint(date: $0.date, min: $0.min * factor, avg: $0.avg * factor, max: $0.max * factor,
                     count: $0.count, resolution: $0.resolution, span: $0.span)
    }
}
