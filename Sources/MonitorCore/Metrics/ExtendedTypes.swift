import Foundation

/// Per-core CPU load. On Apple Silicon the kernel lists efficiency cores first, then performance cores.
public struct CPUCoreLoad: Sendable, Equatable {
    /// 0…100 per logical core, in kernel order.
    public let perCore: [Double]
    public let efficiencyCoreCount: Int
    public let performanceCoreCount: Int

    public init(perCore: [Double], efficiencyCoreCount: Int, performanceCoreCount: Int) {
        self.perCore = perCore
        self.efficiencyCoreCount = efficiencyCoreCount
        self.performanceCoreCount = performanceCoreCount
    }

    /// Cores that belong to the efficiency class (empty on Intel Macs).
    public var efficiencyCores: ArraySlice<Double> { perCore.prefix(efficiencyCoreCount) }
    /// The remaining cores; on Intel Macs all of them.
    public var performanceCores: ArraySlice<Double> { perCore.dropFirst(efficiencyCoreCount) }

    /// Mean load of the efficiency cores, nil when the machine has none.
    public var efficiencyPercent: Double? { Self.mean(efficiencyCores) }
    public var performancePercent: Double? { Self.mean(performanceCores) }

    private static func mean(_ values: ArraySlice<Double>) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public struct GPUStat: Sendable, Equatable {
    /// "Device Utilization %" from the accelerator, 0…100.
    public let utilizationPercent: Double
    /// System memory currently in use by the GPU (unified memory on Apple Silicon).
    public let memoryUsedBytes: UInt64?
    public let memoryAllocatedBytes: UInt64?

    public init(utilizationPercent: Double, memoryUsedBytes: UInt64? = nil, memoryAllocatedBytes: UInt64? = nil) {
        self.utilizationPercent = utilizationPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryAllocatedBytes = memoryAllocatedBytes
    }
}

public struct TemperatureReading: Sendable, Equatable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct ThermalSensors: Sendable, Equatable {
    /// Mean and maximum over the CPU/SoC die sensors; nil when none were found.
    public let cpuAverageCelsius: Double?
    public let cpuMaxCelsius: Double?
    /// Battery temperature from the smart battery (or the gas-gauge sensor).
    public let batteryCelsius: Double?
    /// All valid sensors, one entry per name, sorted by name — for a detail view.
    public let sensors: [TemperatureReading]

    public init(cpuAverageCelsius: Double?, cpuMaxCelsius: Double?, batteryCelsius: Double?,
                sensors: [TemperatureReading]) {
        self.cpuAverageCelsius = cpuAverageCelsius
        self.cpuMaxCelsius = cpuMaxCelsius
        self.batteryCelsius = batteryCelsius
        self.sensors = sensors
    }
}

public struct FanStat: Sendable, Equatable {
    public let index: Int
    public let rpm: Double
    public let minRpm: Double
    public let maxRpm: Double

    public init(index: Int, rpm: Double, minRpm: Double, maxRpm: Double) {
        self.index = index
        self.rpm = rpm
        self.minRpm = minRpm
        self.maxRpm = maxRpm
    }

    /// Current speed as a share of the maximum, 0…1.
    public var fraction: Double { maxRpm > 0 ? min(1, max(0, rpm / maxRpm)) : 0 }
}

/// Power in watts. Every field is nil when the Mac does not report it.
public struct SystemPowerDraw: Sendable, Equatable {
    /// Whole-system power (SMC `PSTR`).
    public let systemWatts: Double?
    /// Power taken from the adapter (SMC `PDTR`); includes battery charging.
    public let adapterInputWatts: Double?
    /// Average over the last interval, from the IOReport "Energy Model".
    public let cpuWatts: Double?
    public let gpuWatts: Double?
    public let aneWatts: Double?
    public let dramWatts: Double?

    public init(systemWatts: Double? = nil, adapterInputWatts: Double? = nil, cpuWatts: Double? = nil,
                gpuWatts: Double? = nil, aneWatts: Double? = nil, dramWatts: Double? = nil) {
        self.systemWatts = systemWatts
        self.adapterInputWatts = adapterInputWatts
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.dramWatts = dramWatts
    }
}

public enum BatteryCondition: String, Sendable, Equatable {
    case normal = "Normal"
    case serviceRecommended = "Service empfohlen"
}

public struct BatteryDetail: Sendable, Equatable {
    public let designCapacityMah: Int
    /// Current full-charge capacity.
    public let maxCapacityMah: Int
    public let currentCapacityMah: Int?
    public let temperatureCelsius: Double?
    public let condition: BatteryCondition
    public let minutesToFull: Int?
    public let voltageMillivolts: Int?
    /// Signed: positive while charging, negative while discharging.
    public let amperageMilliamps: Int?
    /// Rated power of the connected adapter.
    public let adapterWatts: Int?

    public init(designCapacityMah: Int, maxCapacityMah: Int, currentCapacityMah: Int? = nil,
                temperatureCelsius: Double? = nil, condition: BatteryCondition = .normal,
                minutesToFull: Int? = nil, voltageMillivolts: Int? = nil, amperageMilliamps: Int? = nil,
                adapterWatts: Int? = nil) {
        self.designCapacityMah = designCapacityMah
        self.maxCapacityMah = maxCapacityMah
        self.currentCapacityMah = currentCapacityMah
        self.temperatureCelsius = temperatureCelsius
        self.condition = condition
        self.minutesToFull = minutesToFull
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamps = amperageMilliamps
        self.adapterWatts = adapterWatts
    }

    /// Power flowing into the battery, nil unless charging.
    public var chargeWatts: Double? { Self.watts(voltageMillivolts, amperageMilliamps).flatMap { $0 > 0 ? $0 : nil } }
    /// Power drawn from the battery, nil unless discharging.
    public var dischargeWatts: Double? { Self.watts(voltageMillivolts, amperageMilliamps).flatMap { $0 < 0 ? -$0 : nil } }

    static func watts(_ millivolts: Int?, _ milliamps: Int?) -> Double? {
        guard let millivolts, let milliamps else { return nil }
        return Double(millivolts) * Double(milliamps) / 1_000_000
    }
}

public enum InterfaceKind: String, Sendable, Equatable {
    case wifi, ethernet, other
}

public struct ActiveInterface: Sendable, Equatable {
    public let name: String
    public let kind: InterfaceKind
    public let ipv4: String?

    public init(name: String, kind: InterfaceKind, ipv4: String?) {
        self.name = name
        self.kind = kind
        self.ipv4 = ipv4
    }
}

public struct InterfaceRate: Sendable, Equatable {
    public let name: String
    public let rate: NetworkRate

    public init(name: String, rate: NetworkRate) {
        self.name = name
        self.rate = rate
    }
}

public struct NetworkDetail: Sendable, Equatable {
    /// The interface that carries the default route, if any.
    public let primary: ActiveInterface?
    /// Throughput per interface, busiest first.
    public let interfaces: [InterfaceRate]

    public init(primary: ActiveInterface?, interfaces: [InterfaceRate]) {
        self.primary = primary
        self.interfaces = interfaces
    }
}

public struct VolumeStat: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let availableBytes: UInt64
    public let totalBytes: UInt64
    public let isInternal: Bool

    public var id: String { path }

    public init(name: String, path: String, availableBytes: UInt64, totalBytes: UInt64, isInternal: Bool) {
        self.name = name
        self.path = path
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.isInternal = isInternal
    }

    public var freeFraction: Double { totalBytes == 0 ? 1 : Double(availableBytes) / Double(totalBytes) }
}

public struct DiskThroughput: Sendable, Equatable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

/// NVMe SMART summary of the internal SSD.
public struct SSDHealth: Sendable, Equatable {
    /// True when the drive reports no critical warning ("Verified").
    public let isVerified: Bool
    /// Wear estimate, 0 = new; may exceed 100.
    public let percentageUsed: Int
    public let availableSparePercent: Int
    public let temperatureCelsius: Double?
    public let powerOnHours: UInt64?
    /// Lifetime host writes.
    public let bytesWritten: UInt64?

    public init(isVerified: Bool, percentageUsed: Int, availableSparePercent: Int,
                temperatureCelsius: Double? = nil, powerOnHours: UInt64? = nil, bytesWritten: UInt64? = nil) {
        self.isVerified = isVerified
        self.percentageUsed = percentageUsed
        self.availableSparePercent = availableSparePercent
        self.temperatureCelsius = temperatureCelsius
        self.powerOnHours = powerOnHours
        self.bytesWritten = bytesWritten
    }
}

public struct LoadAverage: Sendable, Equatable {
    public let one: Double
    public let five: Double
    public let fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

public struct RuntimeStat: Sendable, Equatable {
    /// Since boot, sleep included (like `uptime`).
    public let uptimeSeconds: TimeInterval
    public let loadAverage: LoadAverage?
    public let processCount: Int
    /// Sum over the processes this user may inspect; other users' processes are not visible without root.
    public let threadCount: Int

    public init(uptimeSeconds: TimeInterval, loadAverage: LoadAverage?, processCount: Int, threadCount: Int) {
        self.uptimeSeconds = uptimeSeconds
        self.loadAverage = loadAverage
        self.processCount = processCount
        self.threadCount = threadCount
    }
}
