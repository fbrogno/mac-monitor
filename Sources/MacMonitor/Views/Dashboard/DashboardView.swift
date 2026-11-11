import AppKit
import MonitorCore
import SwiftUI

/// The dashboard window: sidebar with the sections, details on the right.
struct DashboardView: View {
    let model: AppModel

    var body: some View {
        @Bindable var dashboard = model.dashboard
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $dashboard.section) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            ScrollView { DashboardDetail(model: model).padding(24) }
        }
        .frame(minWidth: 900, minHeight: 600)
        .confirmationAlert(model: model, host: .dashboard)
        .onAppear { model.isDashboardOpen = true }
        .onDisappear { model.isDashboardOpen = false }
        // Reloads while the window is on screen only; the task ends when the view goes away.
        .task(id: dashboard.currentKey) {
            var first = true
            while !Task.isCancelled {
                if first || Self.isWindowVisible { await model.dashboard.reload() }
                first = false
                try? await Task.sleep(for: model.dashboard.range.refreshInterval)
            }
        }
    }

    private static var isWindowVisible: Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("dashboard") == true }) else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
}

/// Header plus the pane of the selected section; rendered directly for the README.
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
        @Bindable var dashboard = model.dashboard
        VStack(alignment: .leading, spacing: 18) {
            DashboardHeader(title: dashboard.section.title, subtitle: subtitle, symbol: dashboard.section.symbol,
                            trailing: AnyView(headerControl))
            if let feedback = model.feedback {
                FeedbackBanner(feedback: feedback) { model.feedback = nil }
            }
            historyNotice
            pane
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var headerControl: some View {
        @Bindable var dashboard = model.dashboard
        switch dashboard.section {
        case .report:
            let selection = Binding<Int>(
                get: { ReportPeriod.allCases.firstIndex(of: dashboard.reportPeriod) ?? 0 },
                set: { dashboard.reportPeriod = ReportPeriod.allCases[$0] })
            MiniSegment(options: ReportPeriod.allCases.map(\.title), selection: selection)
        case .events, .apps:
            RangeSwitch(range: $dashboard.range)
        default:
            RangeSwitch(range: $dashboard.range)
        }
    }

    private var subtitle: String {
        switch dashboard.section {
        case .overview: String(localized: "Aktuelle Werte und Verlauf")
        case .cpu: String(localized: "Auslastung, Kerne und Grafikprozessor")
        case .memory: String(localized: "Belegung, Druck und Swap")
        case .energy: String(localized: "Leistungsaufnahme und Akku")
        case .sensors: String(localized: "Temperaturen, Lüfter und SSD-Zustand")
        case .network: String(localized: "Datendurchsatz und Speicherplatz")
        case .apps: String(localized: "Verbrauch nach App")
        case .events: String(localized: "Vorfälle und Protokoll")
        case .report: String(localized: "Auswertung, Export und Verlauf verwalten")
        }
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
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
