import AppIntents
import AppKit
import MonitorCore

// Kurzbefehle, Spotlight und Siri. The intents run in the app process (the app is the intent
// provider), so they can use the live model; `SystemReader` falls back to a one-off measurement.

// MARK: - Entities

struct SystemStatusEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Systemstatus")
    static let defaultQuery = SystemStatusQuery()

    var id: String

    @Property(title: "CPU-Auslastung (%)") var cpuPercent: Double
    @Property(title: "RAM-Auslastung (%)") var memoryPercent: Double
    @Property(title: "GPU-Auslastung (%)") var gpuPercent: Double?
    @Property(title: "Temperatur (°C)") var temperatureCelsius: Double?
    @Property(title: "Leistung (W)") var powerWatts: Double?
    @Property(title: "Akku (%)") var batteryPercent: Int?
    @Property(title: "Freier Speicherplatz (GB)") var freeDiskGigabytes: Double?
    @Property(title: "Anzahl Auffälligkeiten") var anomalyCount: Int
    @Property(title: "Zusammenfassung") var summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Systemstatus", subtitle: "\(summary)")
    }

    init(_ s: StatusSummary) {
        id = "status"
        cpuPercent = s.cpuPercent.rounded()
        memoryPercent = s.memoryPercent.rounded()
        gpuPercent = s.gpuPercent?.rounded()
        temperatureCelsius = s.temperatureCelsius?.rounded()
        powerWatts = s.powerWatts.map { ($0 * 10).rounded() / 10 }
        batteryPercent = s.batteryPercent
        freeDiskGigabytes = s.freeDiskBytes.map { (Double($0) / 1_073_741_824).rounded() }
        anomalyCount = s.anomalyCount
        summary = IntentText.summary(s)
    }
}

struct SystemStatusQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SystemStatusEntity] { [] }
}

struct ConsumerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "App")
    static let defaultQuery = ConsumerQuery()

    var id: String

    @Property(title: "Name") var name: String
    @Property(title: "CPU (%)") var cpuPercent: Double
    @Property(title: "RAM (MB)") var memoryMegabytes: Int
    @Property(title: "Energie (mW)") var energyMilliwatts: Int

    var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    init(_ row: ConsumerRanking.Row, metric: ConsumerRanking.Metric) {
        detail = IntentText.detail(row, metric: metric)
        id = row.name
        name = row.name
        cpuPercent = row.cpuPercent.rounded()
        memoryMegabytes = Int(row.memoryBytes / 1_048_576)
        energyMilliwatts = Int(row.energyMilliwatts.rounded())
    }
}

struct ConsumerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ConsumerEntity] { [] }
}

enum AnomalySeverity: String, AppEnum {
    case info, warning, critical

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Schweregrad")
    static let caseDisplayRepresentations: [AnomalySeverity: DisplayRepresentation] = [
        .info: "Hinweis", .warning: "Warnung", .critical: "Kritisch",
    ]

    init(_ severity: Severity) {
        switch severity {
        case .info: self = .info
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }
}

struct AnomalyEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Auffälligkeit")
    static let defaultQuery = AnomalyQuery()

    var id: String

    @Property(title: "Titel") var title: String
    @Property(title: "Schweregrad") var severity: AnomalySeverity
    @Property(title: "Beschreibung") var detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: LocalizedStringResource(stringLiteral: IntentText.severityName(severity)))
    }

    init(_ condition: Condition) {
        id = condition.key
        title = condition.title
        severity = AnomalySeverity(condition.severity)
        detail = condition.body
    }
}

struct AnomalyQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AnomalyEntity] { [] }
}

// MARK: - Parameters

enum ConsumerMetricOption: String, AppEnum {
    case cpu, memory, energy

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sortierung")
    static let caseDisplayRepresentations: [ConsumerMetricOption: DisplayRepresentation] = [
        .cpu: "CPU", .memory: "Arbeitsspeicher", .energy: "Energie",
    ]

    var metric: ConsumerRanking.Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .energy
        }
    }
}

enum DashboardArea: String, AppEnum {
    case overview, cpu, memory, energy, sensors, network, apps, events, report

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bereich")
    static let caseDisplayRepresentations: [DashboardArea: DisplayRepresentation] = [
        .overview: "Überblick", .cpu: "CPU und GPU", .memory: "Speicher", .energy: "Energie und Akku",
        .sensors: "Sensoren", .network: "Netzwerk und Laufwerke", .apps: "Apps", .events: "Ereignisse",
        .report: "Bericht",
    ]
}

// MARK: - Intents

struct GetSystemStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Systemstatus abrufen"
    static let description = IntentDescription(
        "Liefert CPU, RAM, GPU, Temperatur, Leistung, Akku, freien Speicherplatz und die Anzahl der Auffälligkeiten.",
        categoryName: "Status")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SystemStatusEntity> & ProvidesDialog {
        let reading = await SystemReader.current()
        let entity = SystemStatusEntity(StatusSummary(reading.snapshot, anomalyCount: reading.conditions.count))
        return .result(value: entity, dialog: IntentDialog(stringLiteral: entity.summary))
    }
}

struct GetTopConsumersIntent: AppIntent {
    static let title: LocalizedStringResource = "Größte Verbraucher abrufen"
    static let description = IntentDescription("Liefert die Apps mit der höchsten Last, nach CPU, Arbeitsspeicher oder Energie sortiert.",
                                               categoryName: "Status")

    @Parameter(title: "Sortieren nach", default: .cpu)
    var metric: ConsumerMetricOption

    @Parameter(title: "Anzahl", default: 5, inclusiveRange: (1, 20))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Die \(\.$count) größten Verbraucher nach \(\.$metric)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConsumerEntity]> & ProvidesDialog {
        let reading = await SystemReader.current()
        let rows = ConsumerRanking.top(reading.snapshot, by: metric.metric, limit: count)
        let entities = rows.map { ConsumerEntity($0, metric: metric.metric) }
        return .result(value: entities, dialog: IntentDialog(stringLiteral: IntentText.consumers(rows, metric: metric.metric)))
    }
}

struct GetAnomaliesIntent: AppIntent {
    static let title: LocalizedStringResource = "Auffälligkeiten abrufen"
    static let description = IntentDescription("Liefert die aktuellen Auffälligkeiten mit Titel und Schweregrad.", categoryName: "Status")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AnomalyEntity]> & ProvidesDialog {
        let reading = await SystemReader.current()
        let conditions = reading.conditions.sorted { $0.severity > $1.severity }
        return .result(value: conditions.map(AnomalyEntity.init),
                       dialog: IntentDialog(stringLiteral: IntentText.anomalies(conditions)))
    }
}

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Dashboard öffnen"
    static let description = IntentDescription("Öffnet das Dashboard im gewählten Bereich.", categoryName: "Öffnen")
    static let openAppWhenRun = true

    @Parameter(title: "Bereich", default: .overview)
    var area: DashboardArea

    static var parameterSummary: some ParameterSummary {
        Summary("Dashboard öffnen: \(\.$area)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The app's URL handler does the work, so a cold start and a running app behave the same.
        if let url = URL(string: "macmonitor://dashboard/\(area.rawValue)") { NSWorkspace.shared.open(url) }
        return .result()
    }
}

struct OpenOverviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Übersicht öffnen"
    static let description = IntentDescription("Öffnet die Übersicht mit den aktuellen Auffälligkeiten.", categoryName: "Öffnen")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "macmonitor://overview") { NSWorkspace.shared.open(url) }
        return .result()
    }
}

struct MuteAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Meldungen stummschalten"
    static let description = IntentDescription("Schaltet die Meldungen von MacMonitor für eine Weile stumm.", categoryName: "Meldungen")

    @Parameter(title: "Dauer", defaultValue: 1, defaultUnit: .hours, supportsNegativeNumbers: false)
    var duration: Measurement<UnitDuration>

    static var parameterSummary: some ParameterSummary {
        Summary("Meldungen stummschalten für \(\.$duration)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let seconds = duration.converted(to: .seconds).value
        guard let end = PauseState().pause(for: seconds) else {
            return .result(dialog: "Die Stummschaltung ist aufgehoben.")
        }
        return .result(dialog: IntentDialog(stringLiteral: IntentText.muted(until: end)))
    }
}

struct UnmuteAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Stummschaltung aufheben"
    static let description = IntentDescription("Hebt die Stummschaltung der Meldungen auf.", categoryName: "Meldungen")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PauseState().resume()
        return .result(dialog: "Meldungen sind wieder aktiv.")
    }
}

// MARK: - Shortcuts, Spotlight, Siri

struct MacMonitorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetSystemStatusIntent(),
                    phrases: ["Systemstatus abrufen in \(.applicationName)", "Wie geht es meinem Mac in \(.applicationName)"],
                    shortTitle: "Systemstatus", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: GetTopConsumersIntent(),
                    phrases: ["Größte Verbraucher in \(.applicationName)", "Was bremst meinen Mac mit \(.applicationName)"],
                    shortTitle: "Größte Verbraucher", systemImageName: "list.number")
        AppShortcut(intent: GetAnomaliesIntent(),
                    phrases: ["Auffälligkeiten in \(.applicationName)", "Gibt es Auffälligkeiten in \(.applicationName)"],
                    shortTitle: "Auffälligkeiten", systemImageName: "exclamationmark.triangle")
        AppShortcut(intent: OpenOverviewIntent(),
                    phrases: ["Übersicht öffnen in \(.applicationName)"],
                    shortTitle: "Übersicht öffnen", systemImageName: "rectangle.grid.2x2")
        AppShortcut(intent: OpenDashboardIntent(),
                    phrases: ["Dashboard öffnen in \(.applicationName)"],
                    shortTitle: "Dashboard öffnen", systemImageName: "chart.xyaxis.line")
        AppShortcut(intent: MuteAlertsIntent(),
                    phrases: ["Meldungen stummschalten in \(.applicationName)"],
                    shortTitle: "Meldungen stummschalten", systemImageName: "bell.slash")
        AppShortcut(intent: UnmuteAlertsIntent(),
                    phrases: ["Stummschaltung aufheben in \(.applicationName)"],
                    shortTitle: "Stummschaltung aufheben", systemImageName: "bell")
    }
}

// MARK: - Texts (pure, so the headless proof can print them)

enum IntentText {
    static func summary(_ s: StatusSummary) -> String {
        var parts = [
            String(localized: "CPU \(Format.percent(s.cpuPercent))"),
            String(localized: "RAM \(Format.percent(s.memoryPercent))"),
        ]
        if let gpu = s.gpuPercent { parts.append(String(localized: "GPU \(Format.percent(gpu))")) }
        if let t = s.temperatureCelsius { parts.append(Format.celsius(t)) }
        if let w = s.powerWatts { parts.append(Format.watts(w)) }
        if let b = s.batteryPercent { parts.append(String(localized: "Akku \(Format.percent(Double(b)))")) }
        if let free = s.freeDiskBytes { parts.append(String(localized: "\(Format.bytes(free)) frei")) }
        let anomalies = s.anomalyCount == 0
            ? String(localized: "Keine Auffälligkeiten.")
            : String(localized: "\(s.anomalyCount) Auffälligkeiten.")
        return parts.joined(separator: ", ") + ". " + anomalies
    }

    static func detail(_ row: ConsumerRanking.Row, metric: ConsumerRanking.Metric) -> String {
        switch metric {
        case .cpu: Format.percent(row.cpuPercent) + " CPU"
        case .memory: Format.bytes(row.memoryBytes)
        case .energy: Format.milliwatts(row.energyMilliwatts)
        }
    }

    static func consumers(_ rows: [ConsumerRanking.Row], metric: ConsumerRanking.Metric) -> String {
        guard !rows.isEmpty else { return String(localized: "Keine Apps mit nennenswerter Last.") }
        return rows.map { "\($0.name) (\(detail($0, metric: metric)))" }.joined(separator: ", ")
    }

    static func severityName(_ severity: AnomalySeverity) -> String {
        switch severity {
        case .info: String(localized: "Hinweis")
        case .warning: String(localized: "Warnung")
        case .critical: String(localized: "Kritisch")
        }
    }

    static func anomalies(_ conditions: [Condition]) -> String {
        guard !conditions.isEmpty else { return String(localized: "Keine Auffälligkeiten.") }
        return conditions.map(\.title).joined(separator: "; ") + "."
    }

    static func muted(until end: Date) -> String {
        String(localized: "Meldungen sind stumm bis \(end.formatted(date: .abbreviated, time: .shortened)).")
    }
}
