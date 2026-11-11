import Foundation

/// Identifies one measured quantity. Open set: a new quantity is just a new key, no migration.
/// Units are fixed per key: bytes for sizes, 0…100 for percentages, bytes/s for rates.
public struct MetricKey: RawRepresentable, Hashable, Sendable, Codable, Comparable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whole-machine CPU, 0…100.
    public static let cpuTotal: MetricKey = "cpu.total"
    /// Used memory in bytes.
    public static let memoryUsed: MetricKey = "memory.used"
    /// Used memory as share of installed memory, 0…100.
    public static let memoryPercent: MetricKey = "memory.percent"
    /// Memory pressure level: 0 normal, 1 warning, 2 critical.
    public static let memoryPressure: MetricKey = "memory.pressure"
    /// 1 while pressure is warning or worse, else 0. The average of a bucket is the share of time
    /// under pressure, which stays exact at every resolution.
    public static let memoryUnderPressure: MetricKey = "memory.underPressure"
    public static let swapUsed: MetricKey = "swap.used"
    /// Free disk space in bytes.
    public static let diskFree: MetricKey = "disk.free"
    public static let netDown: MetricKey = "net.down"
    public static let netUp: MetricKey = "net.up"
    public static let batteryPercent: MetricKey = "battery.percent"
    /// 0 nominal, 1 fair, 2 serious, 3 critical.
    public static let thermalLevel: MetricKey = "thermal.level"
    /// GPU device utilization, 0…100.
    public static let gpuPercent: MetricKey = "gpu.percent"
    /// System memory in use by the GPU, bytes.
    public static let gpuMemory: MetricKey = "gpu.memory"
    /// Mean load of the efficiency / performance cores, 0…100.
    public static let cpuEfficiency: MetricKey = "cpu.efficiency"
    public static let cpuPerformance: MetricKey = "cpu.performance"
    /// Mean and maximum CPU/SoC die temperature, °C.
    public static let cpuTempAvg: MetricKey = "temp.cpu.avg"
    public static let cpuTempMax: MetricKey = "temp.cpu.max"
    public static let batteryTemp: MetricKey = "temp.battery"
    /// Whole-system power in watts.
    public static let powerSystem: MetricKey = "power.system"
    public static let powerCPU: MetricKey = "power.cpu"
    public static let powerGPU: MetricKey = "power.gpu"
    /// Fastest fan, rpm.
    public static let fanMax: MetricKey = "fan.max"
    /// Disk throughput in bytes/s.
    public static let diskRead: MetricKey = "disk.read"
    public static let diskWrite: MetricKey = "disk.write"
    /// 1-minute load average.
    public static let load1: MetricKey = "load.1m"
}

/// One raw measurement.
public struct MetricSample: Sendable, Equatable {
    public let key: MetricKey
    public let value: Double

    public init(_ key: MetricKey, _ value: Double) {
        self.key = key
        self.value = value
    }

    /// Maps the current snapshot onto metrics. To record a new field, add one line here.
    public static func samples(from snapshot: SystemSnapshot) -> [MetricSample] {
        var out: [MetricSample] = [
            MetricSample(.cpuTotal, snapshot.cpuPercent),
            MetricSample(.memoryUsed, Double(snapshot.memoryUsedBytes)),
            MetricSample(.memoryPercent, snapshot.memoryFraction * 100),
            MetricSample(.memoryPressure, snapshot.memoryPressure.historyLevel),
            MetricSample(.memoryUnderPressure, snapshot.memoryPressure >= .warning ? 1 : 0),
            MetricSample(.swapUsed, Double(snapshot.swapUsedBytes)),
            MetricSample(.thermalLevel, Double(snapshot.thermal.rawValue)),
        ]
        if let disk = snapshot.disk { out.append(MetricSample(.diskFree, Double(disk.availableBytes))) }
        if let net = snapshot.network {
            out.append(MetricSample(.netDown, net.downBytesPerSecond))
            out.append(MetricSample(.netUp, net.upBytesPerSecond))
        }
        if let percent = snapshot.power.batteryPercent { out.append(MetricSample(.batteryPercent, Double(percent))) }
        // Extended metrics: a row only where the Mac reports a value, never a stand-in 0.
        if let gpu = snapshot.gpu {
            out.append(MetricSample(.gpuPercent, gpu.utilizationPercent))
            if let used = gpu.memoryUsedBytes { out.append(MetricSample(.gpuMemory, Double(used))) }
        }
        if let value = snapshot.cpuCores?.efficiencyPercent { out.append(MetricSample(.cpuEfficiency, value)) }
        if let value = snapshot.cpuCores?.performancePercent { out.append(MetricSample(.cpuPerformance, value)) }
        if let value = snapshot.thermals?.cpuAverageCelsius { out.append(MetricSample(.cpuTempAvg, value)) }
        if let value = snapshot.thermals?.cpuMaxCelsius { out.append(MetricSample(.cpuTempMax, value)) }
        if let value = snapshot.thermals?.batteryCelsius { out.append(MetricSample(.batteryTemp, value)) }
        if let value = snapshot.powerDraw?.systemWatts { out.append(MetricSample(.powerSystem, value)) }
        if let value = snapshot.powerDraw?.cpuWatts { out.append(MetricSample(.powerCPU, value)) }
        if let value = snapshot.powerDraw?.gpuWatts { out.append(MetricSample(.powerGPU, value)) }
        if let value = snapshot.fans.map(\.rpm).max() { out.append(MetricSample(.fanMax, value)) }
        if let io = snapshot.diskThroughput {
            out.append(MetricSample(.diskRead, io.readBytesPerSecond))
            out.append(MetricSample(.diskWrite, io.writeBytesPerSecond))
        }
        if let load = snapshot.runtime?.loadAverage { out.append(MetricSample(.load1, load.one)) }
        return out
    }
}

private extension MemoryPressure {
    var historyLevel: Double {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

/// Storage tier. Each coarser tier is derived from the finer one.
public enum Resolution: Int, Sendable, Codable, CaseIterable, Comparable {
    case minute = 0, quarterHour = 1, day = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Bucket width; days vary with daylight saving, 86 400 s is the nominal value.
    public var nominalSeconds: TimeInterval {
        switch self {
        case .minute: 60
        case .quarterHour: 900
        case .day: 86_400
        }
    }

    /// The finest tier that yields at most `maxPoints` buckets for `range` seconds.
    /// Falls back to the coarsest tier when none fits.
    public static func choose(range: TimeInterval, maxPoints: Int) -> Resolution {
        let limit = Double(max(maxPoints, 1))
        return allCases.first { range / $0.nominalSeconds <= limit } ?? .day
    }
}

/// One bucket of a series. `avg` is weighted by the number of raw samples.
public struct HistoryPoint: Sendable, Equatable, Codable {
    /// Start of the bucket.
    public let date: Date
    public let min: Double
    public let avg: Double
    public let max: Double
    /// Raw samples behind this bucket.
    public let count: Int
    public let resolution: Resolution
    /// Real bucket width in seconds (a day is 23 or 25 hours when the clocks change).
    public let span: TimeInterval

    public init(date: Date, min: Double, avg: Double, max: Double, count: Int,
                resolution: Resolution, span: TimeInterval) {
        self.date = date
        self.min = min
        self.avg = avg
        self.max = max
        self.count = count
        self.resolution = resolution
        self.span = span
    }
}

/// How long each tier is kept.
public struct RetentionPolicy: Sendable, Equatable {
    public var minute: TimeInterval = 48 * 3600
    public var quarterHour: TimeInterval = 30 * 86_400
    public var day: TimeInterval = 730 * 86_400
    public var events: TimeInterval = 90 * 86_400
    public var processes: TimeInterval = 30 * 86_400

    public init() {}
    public static let standard = RetentionPolicy()
}
