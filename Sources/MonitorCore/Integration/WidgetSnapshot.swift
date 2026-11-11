import Foundation
import Security

/// Everything the widgets show, in one small JSON file. The app writes it, the (sandboxed) widget
/// extension only reads it. Plain values only, so the file stays tiny and versionable.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Anomaly: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        /// `Severity.rawValue`.
        public var severity: Int

        public init(key: String, title: String, severity: Int) {
            self.key = key
            self.title = title
            self.severity = severity
        }
    }

    public struct TopApp: Codable, Equatable, Sendable {
        public var name: String
        public var cpuPercent: Double
        public var memoryBytes: UInt64
        public var energyMilliwatts: Double

        public init(name: String, cpuPercent: Double, memoryBytes: UInt64, energyMilliwatts: Double) {
            self.name = name
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
            self.energyMilliwatts = energyMilliwatts
        }
    }

    public struct Battery: Codable, Equatable, Sendable {
        public var percent: Int
        public var onBattery: Bool
        public var isCharging: Bool
        public var minutesRemaining: Int?
        public var healthPercent: Int?
        public var cycleCount: Int?

        public init(percent: Int, onBattery: Bool, isCharging: Bool, minutesRemaining: Int? = nil,
                    healthPercent: Int? = nil, cycleCount: Int? = nil) {
            self.percent = percent
            self.onBattery = onBattery
            self.isCharging = isCharging
            self.minutesRemaining = minutesRemaining
            self.healthPercent = healthPercent
            self.cycleCount = cycleCount
        }
    }

    /// Bumped when the layout changes incompatibly; a reader ignores files of another version.
    public static let currentVersion = 1
    /// After this long without an update the widgets say the app is not running.
    public static let staleAfter: TimeInterval = 5 * 60
    /// Number of points kept per series: one per minute, the last hour.
    public static let seriesLength = 60

    public var version: Int = WidgetSnapshot.currentVersion
    public var date: Date
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var gpuPercent: Double?
    public var temperatureCelsius: Double?
    public var powerWatts: Double?
    public var battery: Battery?
    public var diskFreeBytes: UInt64?
    public var diskTotalBytes: UInt64?
    public var anomalies: [Anomaly]
    public var topApps: [TopApp]
    public var cpuSeries: [Double]
    public var memorySeries: [Double]
    public var gpuSeries: [Double]

    public init(date: Date, cpuPercent: Double, memoryPercent: Double, memoryUsedBytes: UInt64 = 0,
                memoryTotalBytes: UInt64 = 0, gpuPercent: Double? = nil, temperatureCelsius: Double? = nil,
                powerWatts: Double? = nil, battery: Battery? = nil, diskFreeBytes: UInt64? = nil,
                diskTotalBytes: UInt64? = nil, anomalies: [Anomaly] = [], topApps: [TopApp] = [],
                cpuSeries: [Double] = [], memorySeries: [Double] = [], gpuSeries: [Double] = []) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.gpuPercent = gpuPercent
        self.temperatureCelsius = temperatureCelsius
        self.powerWatts = powerWatts
        self.battery = battery
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.anomalies = anomalies
        self.topApps = topApps
        self.cpuSeries = cpuSeries
        self.memorySeries = memorySeries
        self.gpuSeries = gpuSeries
    }

    /// Worst severity among the anomalies; nil when everything is calm.
    public var worstSeverity: Severity? {
        anomalies.compactMap { Severity(rawValue: $0.severity) }.max()
    }

    /// Whether the values are too old to be shown as current.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(date) > Self.staleAfter
    }

    /// Whether `self` looks different from `old` on screen. Widgets show rounded values, so small
    /// moves do not justify a timeline reload (macOS budgets them).
    public func isVisiblyDifferent(from old: WidgetSnapshot) -> Bool {
        if Set(anomalies.map(\.key)) != Set(old.anomalies.map(\.key)) { return true }
        if abs(cpuPercent - old.cpuPercent) >= 3 || abs(memoryPercent - old.memoryPercent) >= 3 { return true }
        if differs(gpuPercent, old.gpuPercent, by: 3) || differs(temperatureCelsius, old.temperatureCelsius, by: 2)
            || differs(powerWatts, old.powerWatts, by: 1) { return true }
        if battery?.percent != old.battery?.percent || battery?.isCharging != old.battery?.isCharging
            || battery?.onBattery != old.battery?.onBattery { return true }
        switch (diskFreeBytes, old.diskFreeBytes) {
        case let (a?, b?):
            if (a > b ? a - b : b - a) >= 1_000_000_000 { return true }
        case (nil, nil): break
        default: return true
        }
        return topApps.map(\.name) != old.topApps.map(\.name)
    }

    private func differs(_ a: Double?, _ b: Double?, by limit: Double) -> Bool {
        switch (a, b) {
        case let (a?, b?): abs(a - b) >= limit
        case (nil, nil): false
        default: true
        }
    }

    /// Adds this sample's point to the series of `previous`, keeping only the last hour.
    public func appending(to previous: WidgetSnapshot?) -> WidgetSnapshot {
        var copy = self
        func carry(_ old: [Double]?, _ value: Double?) -> [Double] {
            guard let value else { return [] }
            return Array(((old ?? []) + [value]).suffix(Self.seriesLength))
        }
        copy.cpuSeries = carry(previous?.cpuSeries, cpuPercent)
        copy.memorySeries = carry(previous?.memorySeries, memoryPercent)
        copy.gpuSeries = carry(previous?.gpuSeries, gpuPercent)
        return copy
    }
}

/// Where the snapshot file lives and how it is read and written.
public struct WidgetStore: Sendable {
    public static let appGroupSuffix = "com.fbrogno.macmonitor"
    public static let fileName = "widget-snapshot.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// The shared group container, or nil when this process has no matching App-Groups entitlement
    /// (ad-hoc builds, `swift run`). The group id is read from the process's own entitlements, so no
    /// team ID is compiled into the code: it is `<TEAMID>.com.fbrogno.macmonitor` and is put into the
    /// entitlements at signing time.
    public static func shared() -> WidgetStore? {
        guard let group = ownGroupIdentifier(),
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetStore(directory: url)
    }

    public static func ownGroupIdentifier() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix("." + appGroupSuffix) }
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// nil when the file is missing, unreadable or from another format version.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}

/// What a widget has to show for a given moment.
public enum WidgetContent: Equatable, Sendable {
    /// No file, or no group container at all.
    case noData
    /// The file is older than `WidgetSnapshot.staleAfter`: show "MacMonitor läuft nicht" and when it was last seen.
    case stale(lastSeen: Date, snapshot: WidgetSnapshot)
    case live(WidgetSnapshot)

    public static func resolve(_ snapshot: WidgetSnapshot?, at now: Date) -> WidgetContent {
        guard let snapshot else { return .noData }
        return snapshot.isStale(at: now) ? .stale(lastSeen: snapshot.date, snapshot: snapshot) : .live(snapshot)
    }
}
