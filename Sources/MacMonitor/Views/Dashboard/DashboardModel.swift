import Foundation
import MonitorCore
import Observation

enum HistoryState: Equatable {
    case starting
    case active
    case unavailable(String)
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, cpu, memory, energy, sensors, network, apps, events, report

    var id: String { rawValue }

    /// Name used in `macmonitor://dashboard/<slug>`.
    var slug: String { rawValue }

    init?(slug: String) {
        let key = slug.lowercased()
        switch key {
        case "ueberblick", "überblick": self = .overview
        case "speicher", "ram": self = .memory
        case "energie", "akku": self = .energy
        case "netzwerk", "laufwerke": self = .network
        case "ereignisse": self = .events
        case "bericht": self = .report
        default:
            guard let section = DashboardSection(rawValue: key) else { return nil }
            self = section
        }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "Überblick")
        case .cpu: String(localized: "CPU & GPU")
        case .memory: String(localized: "Speicher")
        case .energy: String(localized: "Energie & Akku")
        case .sensors: String(localized: "Sensoren")
        case .network: String(localized: "Netzwerk & Laufwerke")
        case .apps: String(localized: "Apps")
        case .events: String(localized: "Ereignisse")
        case .report: String(localized: "Bericht")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .energy: "bolt.fill"
        case .sensors: "thermometer.medium"
        case .network: "network"
        case .apps: "app.badge"
        case .events: "bell"
        case .report: "doc.text"
        }
    }

    /// Series the section draws; only these are queried while it is shown.
    var metrics: [MetricKey] {
        switch self {
        case .overview: [.cpuTotal, .gpuPercent, .memoryPercent, .cpuTempAvg, .powerSystem, .batteryPercent,
                         .diskRead, .diskWrite, .netDown, .netUp]
        case .cpu: [.cpuTotal, .cpuEfficiency, .cpuPerformance, .gpuPercent, .gpuMemory, .load1]
        case .memory: [.memoryPercent, .memoryUsed, .swapUsed, .memoryUnderPressure]
        case .energy: [.powerSystem, .powerCPU, .powerGPU, .batteryPercent, .batteryTemp]
        case .sensors: [.cpuTempAvg, .cpuTempMax, .fanMax, .batteryTemp]
        case .network: [.netDown, .netUp, .diskRead, .diskWrite]
        case .apps, .events, .report: []
        }
    }
}

enum DashboardRange: String, CaseIterable, Identifiable {
    case hour, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: String(localized: "1 h")
        case .day: String(localized: "24 h")
        case .week: String(localized: "7 Tage")
        case .month: String(localized: "30 Tage")
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Upper bound of buckets per series. Chosen so the store picks the minute tier for 1 h,
    /// the 15-minute tier for 24 h, 7 days (672) and 30 days (2 880).
    var maxPoints: Int {
        switch self {
        case .hour: 120
        case .day: 500
        case .week: 800
        case .month: 3000
        }
    }

    /// Minimum time between reloads while the window is visible.
    var refreshInterval: Duration {
        switch self {
        case .hour: .seconds(10)
        case .day: .seconds(60)
        case .week: .seconds(300)
        case .month: .seconds(600)
        }
    }
}

enum ReportPeriod: String, CaseIterable, Identifiable {
    case day, week

    var id: String { rawValue }
    var title: String { self == .day ? String(localized: "Tag") : String(localized: "Woche") }
    var duration: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
}

/// Everything one dashboard section needs from the store, loaded in one go.
struct DashboardData: Sendable {
    struct Key: Hashable, Sendable {
        var section: DashboardSection
        var range: DashboardRange
        var period: ReportPeriod
    }

    var key: Key
    var from: Date
    var to: Date
    var series: [MetricKey: [HistoryPoint]] = [:]
    var incidents: [Incident] = []
    var events: [HistoryEvent] = []
    var top: TopProcesses = .empty
    var report: HistorySummary?
    var fileSizeBytes: Int64 = 0
    var writeError: String?
    var error: String?

    func points(_ key: MetricKey) -> [HistoryPoint] { series[key] ?? [] }
}

extension DashboardSection: Sendable {}
extension DashboardRange: Sendable {}
extension ReportPeriod: Sendable {}

@MainActor @Observable
final class DashboardModel {
    var section: DashboardSection = .overview
    var range: DashboardRange = .day
    var reportPeriod: ReportPeriod = .day
    /// Rule filter of the events section (`RuleID.rawValue`); nil shows all.
    var eventRule: String?
    private(set) var data: DashboardData?
    private(set) var isLoading = false
    /// Offline renderer only: shows the chart tooltip at this time.
    @ObservationIgnored var previewHover: Date?

    @ObservationIgnored var store: HistoryStore?

    var currentKey: DashboardData.Key { .init(section: section, range: range, period: reportPeriod) }

    /// Loads the current section. A result for settings the user has already left is dropped.
    func reload(now: Date = Date()) async {
        guard let store else { return }
        let key = currentKey
        isLoading = true
        let loaded = await Self.fetch(store: store, key: key, now: now)
        isLoading = false
        if key == currentKey { data = loaded }
    }

    /// Same as `reload`, but waits on the calling (main) thread; for the offline image renderer only.
    func reloadBlocking(now: Date = Date()) {
        guard let store else { return }
        let key = currentKey
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: DashboardData?
        Task.detached {
            result = await Self.fetch(store: store, key: key, now: now)
            semaphore.signal()
        }
        semaphore.wait()
        data = result
    }

    nonisolated static func fetch(store: HistoryStore, key: DashboardData.Key, now: Date) async -> DashboardData {
        let span = key.section == .report ? key.period.duration : key.range.duration
        let from = now.addingTimeInterval(-span)
        var data = DashboardData(key: key, from: from, to: now)
        data.fileSizeBytes = store.fileSizeBytes()
        do {
            for metric in key.section.metrics {
                let points = try await store.series(metric, from: from, to: now, maxPoints: key.range.maxPoints)
                if !points.isEmpty { data.series[metric] = points }
            }
            switch key.section {
            case .apps:
                data.top = try await store.topProcesses(from: from, to: now, limit: 8)
            case .events:
                data.incidents = try await store.incidents(from: from, to: now)
                data.events = try await store.events(from: from, to: now)
            case .report:
                data.report = try await store.report(for: DateInterval(start: from, end: now), now: now)
            default: break
            }
            data.writeError = await store.lastWriteError
        } catch {
            data.error = "\(error)"
        }
        return data
    }

    // MARK: Export and delete

    enum ExportFormat { case csv, json }

    func export(_ format: ExportFormat, from: Date, to: Date) async throws -> Data {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        switch format {
        case .csv: return try await store.exportCSV(from: from, to: to)
        case .json: return try await store.exportJSON(from: from, to: to)
        }
    }

    func deleteAll() async throws {
        guard let store else { return }
        try await store.deleteAll()
        await reload()
    }
}
