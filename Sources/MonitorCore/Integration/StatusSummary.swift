import Foundation

/// The values the "Systemstatus" intent reports, taken from one snapshot.
public struct StatusSummary: Equatable, Sendable {
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var gpuPercent: Double?
    public var temperatureCelsius: Double?
    public var powerWatts: Double?
    public var batteryPercent: Int?
    public var freeDiskBytes: UInt64?
    public var anomalyCount: Int

    public init(_ snapshot: SystemSnapshot, anomalyCount: Int) {
        cpuPercent = snapshot.cpuPercent
        memoryPercent = snapshot.memoryFraction * 100
        gpuPercent = snapshot.gpu?.utilizationPercent
        temperatureCelsius = snapshot.thermals?.cpuAverageCelsius
        powerWatts = snapshot.powerDraw?.systemWatts
        batteryPercent = snapshot.power.batteryPercent
        freeDiskBytes = snapshot.disk?.availableBytes
        self.anomalyCount = anomalyCount
    }
}

/// Ranking of apps (helpers summed up) by one resource.
public enum ConsumerRanking {
    public enum Metric: Sendable { case cpu, memory, energy }

    public struct Row: Equatable, Sendable {
        public let name: String
        public let cpuPercent: Double
        public let memoryBytes: UInt64
        public let energyMilliwatts: Double
    }

    public static func top(_ snapshot: SystemSnapshot, by metric: Metric, limit: Int) -> [Row] {
        let key: (AppUsage) -> Double = {
            switch metric {
            case .cpu: $0.cpuPercent
            case .memory: Double($0.footprintBytes)
            case .energy: $0.energyMilliwatts
            }
        }
        return AppGrouping.aggregate(snapshot.processes)
            .sorted { key($0) > key($1) }
            .prefix(max(0, limit))
            .map { Row(name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.footprintBytes,
                       energyMilliwatts: $0.energyMilliwatts) }
    }
}

extension WidgetSnapshot {
    /// Builds the widget file content from a sample and the conditions currently reported.
    /// Series are filled by `appending(to:)`.
    public init(snapshot s: SystemSnapshot, conditions: [Condition]) {
        let battery: Battery? = s.power.batteryPercent.map {
            Battery(percent: $0, onBattery: s.power.onBattery, isCharging: s.power.isCharging,
                    minutesRemaining: s.power.minutesRemaining, healthPercent: s.power.health?.capacityPercent,
                    cycleCount: s.power.health?.cycleCount)
        }
        self.init(
            date: s.date, cpuPercent: s.cpuPercent, memoryPercent: s.memoryFraction * 100,
            memoryUsedBytes: s.memoryUsedBytes, memoryTotalBytes: s.memoryTotalBytes,
            gpuPercent: s.gpu?.utilizationPercent, temperatureCelsius: s.thermals?.cpuAverageCelsius,
            powerWatts: s.powerDraw?.systemWatts, battery: battery,
            diskFreeBytes: s.disk?.availableBytes, diskTotalBytes: s.disk?.totalBytes,
            anomalies: conditions.sorted { $0.severity > $1.severity }
                .map { Anomaly(key: $0.key, title: $0.title, severity: $0.severity.rawValue) },
            topApps: ConsumerRanking.top(s, by: .cpu, limit: 3).map {
                TopApp(name: $0.name, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes,
                       energyMilliwatts: $0.energyMilliwatts)
            })
    }
}
