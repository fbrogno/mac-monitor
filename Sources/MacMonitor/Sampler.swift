import Foundation
import MonitorCore

/// Collects one `SystemSnapshot`. Not thread-safe: `@unchecked Sendable` only because it is
/// confined to `AppModel`'s serial sampling queue.
final class Sampler: @unchecked Sendable {
    private let system = SystemSampler()
    private let processes = ProcessSampler()
    private let network = NetworkSampler()
    private let cores = CPUCoreSampler()
    private let smc = SMCSampler()
    private let thermal: ThermalSampler
    private let energy = EnergySampler()
    private let diskIO = DiskIOSampler()
    private let activeInterface = ActiveInterfaceSampler()

    /// True while a window or popover shows the detail views; sensors are then refreshed more often.
    var detailsVisible = false {
        didSet { processes.detailsVisible = detailsVisible }
    }

    /// Slow-changing values are refreshed less often than the main tick.
    private var disk = Cached<DiskStat?>(every: 300) { DiskSampler.sample() }
    private var battery = Cached<BatteryHealth?>(every: 300) { PowerSampler.batteryHealth() }
    private var blockers = Cached<[SleepBlocker]>(every: 60) { SleepAssertionSampler.sample() }
    private var volumes = Cached<[VolumeStat]>(every: 300) { VolumeSampler.sample() }
    /// The GPU is read on every sample while details are visible, otherwise every 30 s (enough for the history).
    private var gpu = Cached<GPUStat?>(every: 30) { GPUSampler.sample() }
    private var ssd = Cached<SSDHealth?>(every: 300) { SSDHealthSampler.sample() }
    // Sensors and power: every 5-10 s while details are visible, every 30-60 s otherwise.
    private var batteryDetail = Cached<BatteryDetail?>(every: 10) { PowerSampler.batteryDetail() }
    private var fans: Cached<[FanStat]>
    private var thermals: Cached<ThermalSensors?>
    private var powerDraw: Cached<SystemPowerDraw?>
    private var primaryInterface: Cached<ActiveInterface?>

    init() {
        let smc = self.smc
        let thermal = ThermalSampler(smc: smc)
        let energy = self.energy
        let activeInterface = self.activeInterface
        self.thermal = thermal
        processes.detailsVisible = false
        fans = Cached(every: 5) { smc.fans() }
        thermals = Cached(every: 5) { thermal.sample() }
        powerDraw = Cached(every: 5) {
            let board = smc.boardPower()
            let parts = energy?.sample()
            guard board.system != nil || board.adapterInput != nil || parts != nil else { return nil }
            return SystemPowerDraw(systemWatts: board.system, adapterInputWatts: board.adapterInput,
                                   cpuWatts: parts?.cpuWatts, gpuWatts: parts?.gpuWatts,
                                   aneWatts: parts?.aneWatts, dramWatts: parts?.dramWatts)
        }
        primaryInterface = Cached(every: 10) { activeInterface.sample() }
    }

    /// Forces a fresh read of sleep blockers on the next sample, e.g. right after ending one.
    func invalidateSleepBlockers() { blockers.invalidate() }

    func reset() {
        system.reset()
        processes.reset()
        network.reset()
        cores.reset()
        energy?.reset()
        diskIO.reset()
    }

    func collect(isOnline: Bool) -> SystemSnapshot {
        let now = Date()
        let sensorEvery: TimeInterval = detailsVisible ? 5 : 30
        let detail = batteryDetail.value(at: now, every: detailsVisible ? 10 : 60)
        let processList = processes.sample()
        let networkRate = network.sample()
        return SystemSnapshot(
            date: now,
            cpuPercent: system.cpuPercent(),
            memoryUsedBytes: system.memoryUsedBytes(),
            memoryTotalBytes: system.memoryTotalBytes,
            memoryPressure: system.memoryPressure(),
            swapUsedBytes: system.swapUsedBytes(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            disk: disk.value(at: now),
            isOnline: isOnline,
            network: networkRate,
            power: PowerSampler.sample(health: battery.value(at: now)),
            sleepBlockers: blockers.value(at: now),
            processes: processList,
            cpuCores: cores.sample(),
            gpu: gpu.value(at: now, every: detailsVisible ? 0 : 30),
            thermals: thermals.value(at: now, every: sensorEvery).map { sensors in
                // The smart battery's own reading beats the HID gas-gauge sensor.
                ThermalSensors(cpuAverageCelsius: sensors.cpuAverageCelsius, cpuMaxCelsius: sensors.cpuMaxCelsius,
                               batteryCelsius: detail?.temperatureCelsius ?? sensors.batteryCelsius,
                               sensors: sensors.sensors)
            },
            fans: fans.value(at: now, every: sensorEvery),
            powerDraw: powerDraw.value(at: now, every: sensorEvery),
            batteryDetail: detail,
            networkDetail: NetworkDetail(primary: primaryInterface.value(at: now, every: detailsVisible ? 10 : 30),
                                         interfaces: network.interfaceRates),
            volumes: volumes.value(at: now),
            diskThroughput: diskIO.sample(),
            ssdHealth: ssd.value(at: now),
            runtime: RuntimeStat(uptimeSeconds: RuntimeSampler.uptimeSeconds() ?? 0,
                                 loadAverage: RuntimeSampler.loadAverage(),
                                 processCount: processes.systemProcessCount,
                                 threadCount: processes.visibleThreadCount)
        )
    }
}

private struct Cached<Value> {
    let interval: TimeInterval
    let load: () -> Value
    private var stored: Value?
    private var loadedAt: Date = .distantPast

    init(every interval: TimeInterval, load: @escaping () -> Value) {
        self.interval = interval
        self.load = load
    }

    mutating func invalidate() { loadedAt = .distantPast }

    /// `override` replaces the default interval for this call, so one cache can follow the UI state.
    mutating func value(at now: Date, every override: TimeInterval? = nil) -> Value {
        if let stored, now.timeIntervalSince(loadedAt) < (override ?? interval) { return stored }
        let fresh = load()
        stored = fresh
        loadedAt = now
        return fresh
    }
}
