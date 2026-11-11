import Foundation

/// One process as seen in a single sample. `cpuPercent` uses the Activity Monitor scale:
/// 100 means one fully busy core, so values above 100 are possible.
public struct ProcessStat: Sendable, Hashable, Identifiable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let footprintBytes: UInt64
    /// Energy use in milliwatts, from the kernel's per-process energy counter (Apple Silicon only).
    public var energyMilliwatts: Double = 0
    public var threads: Int = 0
    public var diskReadBytesPerSecond: Double = 0
    public var diskWriteBytesPerSecond: Double = 0
    /// Identifies the app this process belongs to (see `AppGrouping`); helpers share the key of their app.
    public var appKey: String = ""
    public var appName: String = ""
    /// Kernel start time of the process (`ri_proc_start_abstime`); with the PID it tells a process from a later one
    /// that got the same PID. 0 when unknown.
    public var startTime: UInt64 = 0
    /// Executable path; empty when the system does not tell.
    public var path: String = ""
    /// The app bundle the executable itself lives in (outermost `*.app`), unlike `appKey`, which also follows
    /// the responsible process. Empty for plain tools.
    public var bundlePath: String = ""

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, footprintBytes: UInt64,
                energyMilliwatts: Double = 0, threads: Int = 0,
                diskReadBytesPerSecond: Double = 0, diskWriteBytesPerSecond: Double = 0,
                appKey: String = "", appName: String = "",
                startTime: UInt64 = 0, path: String = "", bundlePath: String = "") {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.energyMilliwatts = energyMilliwatts
        self.threads = threads
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.appKey = appKey
        self.appName = appName
        self.startTime = startTime
        self.path = path
        self.bundlePath = bundlePath
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
    // Extended metrics. Each is nil/empty when the Mac does not expose it.
    public let cpuCores: CPUCoreLoad?
    public let gpu: GPUStat?
    public let thermals: ThermalSensors?
    public let fans: [FanStat]
    public let powerDraw: SystemPowerDraw?
    public let batteryDetail: BatteryDetail?
    public let networkDetail: NetworkDetail?
    public let volumes: [VolumeStat]
    public let diskThroughput: DiskThroughput?
    public let ssdHealth: SSDHealth?
    public let runtime: RuntimeStat?

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
        processes: [ProcessStat],
        cpuCores: CPUCoreLoad? = nil,
        gpu: GPUStat? = nil,
        thermals: ThermalSensors? = nil,
        fans: [FanStat] = [],
        powerDraw: SystemPowerDraw? = nil,
        batteryDetail: BatteryDetail? = nil,
        networkDetail: NetworkDetail? = nil,
        volumes: [VolumeStat] = [],
        diskThroughput: DiskThroughput? = nil,
        ssdHealth: SSDHealth? = nil,
        runtime: RuntimeStat? = nil
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
        self.cpuCores = cpuCores
        self.gpu = gpu
        self.thermals = thermals
        self.fans = fans
        self.powerDraw = powerDraw
        self.batteryDetail = batteryDetail
        self.networkDetail = networkDetail
        self.volumes = volumes
        self.diskThroughput = diskThroughput
        self.ssdHealth = ssdHealth
        self.runtime = runtime
    }

    /// The same snapshot without a process that was just ended, so the UI updates at once
    /// instead of waiting for the next sample.
    public func removing(pid: Int32) -> SystemSnapshot {
        SystemSnapshot(date: date, cpuPercent: cpuPercent, memoryUsedBytes: memoryUsedBytes,
                       memoryTotalBytes: memoryTotalBytes, memoryPressure: memoryPressure,
                       swapUsedBytes: swapUsedBytes, thermal: thermal, disk: disk, isOnline: isOnline,
                       network: network, power: power,
                       sleepBlockers: sleepBlockers.filter { $0.pid != pid },
                       processes: processes.filter { $0.pid != pid },
                       cpuCores: cpuCores, gpu: gpu, thermals: thermals, fans: fans,
                       powerDraw: powerDraw, batteryDetail: batteryDetail, networkDetail: networkDetail,
                       volumes: volumes, diskThroughput: diskThroughput, ssdHealth: ssdHealth,
                       runtime: runtime)
    }

    public var memoryFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}
