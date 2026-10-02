import Foundation

/// One process as seen in a single sample. `cpuPercent` uses the Activity Monitor scale:
/// 100 means one fully busy core, so values above 100 are possible.
public struct ProcessStat: Sendable, Hashable, Identifiable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let footprintBytes: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, footprintBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

/// Mirrors `kern.memorystatus_vm_pressure_level`.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DiskStat: Sendable, Equatable {
    public let availableBytes: UInt64
    public let totalBytes: UInt64

    public init(availableBytes: UInt64, totalBytes: UInt64) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    public var freeFraction: Double {
        totalBytes == 0 ? 1 : Double(availableBytes) / Double(totalBytes)
    }
}

public struct PowerState: Sendable, Equatable {
    public let onBattery: Bool
    public let batteryPercent: Int?
    public let lowPowerMode: Bool
    public var isCharging: Bool = false
    /// macOS estimate while on battery; nil while it is still calculating or on AC.
    public var minutesRemaining: Int?
    public var health: BatteryHealth?

    public init(onBattery: Bool, batteryPercent: Int?, lowPowerMode: Bool,
                isCharging: Bool = false, minutesRemaining: Int? = nil, health: BatteryHealth? = nil) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.lowPowerMode = lowPowerMode
        self.isCharging = isCharging
        self.minutesRemaining = minutesRemaining
        self.health = health
    }

    public static let unknown = PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: false)
}

public struct BatteryHealth: Sendable, Equatable {
    public let cycleCount: Int
    /// Current full-charge capacity relative to design capacity, 0…100.
    public let capacityPercent: Int

    public init(cycleCount: Int, capacityPercent: Int) {
        self.cycleCount = cycleCount
        self.capacityPercent = capacityPercent
    }
}

public struct SystemSnapshot: Sendable {
    public let date: Date
    /// Whole machine, 0…100.
    public let cpuPercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let memoryPressure: MemoryPressure
    public let swapUsedBytes: UInt64
    public let thermal: ThermalLevel
    public let disk: DiskStat?
    public let isOnline: Bool
    public let network: NetworkRate?
    public let power: PowerState
    public let sleepBlockers: [SleepBlocker]
    /// Sorted by CPU, highest first.
    public let processes: [ProcessStat]

    public init(
        date: Date,
        cpuPercent: Double,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        memoryPressure: MemoryPressure,
        swapUsedBytes: UInt64,
        thermal: ThermalLevel,
        disk: DiskStat?,
        isOnline: Bool,
        network: NetworkRate? = nil,
        power: PowerState,
        sleepBlockers: [SleepBlocker] = [],
        processes: [ProcessStat]
    ) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.thermal = thermal
        self.disk = disk
        self.isOnline = isOnline
        self.network = network
        self.power = power
        self.sleepBlockers = sleepBlockers
        self.processes = processes
    }

    /// The same snapshot without a process that was just ended, so the UI updates at once
    /// instead of waiting for the next sample.
    public func removing(pid: Int32) -> SystemSnapshot {
        SystemSnapshot(date: date, cpuPercent: cpuPercent, memoryUsedBytes: memoryUsedBytes,
                       memoryTotalBytes: memoryTotalBytes, memoryPressure: memoryPressure,
                       swapUsedBytes: swapUsedBytes, thermal: thermal, disk: disk, isOnline: isOnline,
                       network: network, power: power,
                       sleepBlockers: sleepBlockers.filter { $0.pid != pid },
                       processes: processes.filter { $0.pid != pid })
    }

    public var memoryFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}
