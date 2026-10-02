import Foundation
import MonitorCore

/// Collects one `SystemSnapshot`. Not thread-safe: `@unchecked Sendable` only because it is
/// confined to `AppModel`'s serial sampling queue.
final class Sampler: @unchecked Sendable {
    private let system = SystemSampler()
    private let processes = ProcessSampler()
    private let network = NetworkSampler()

    /// Slow-changing values are refreshed less often than the main tick.
    private var disk = Cached<DiskStat?>(every: 300) { DiskSampler.sample() }
    private var battery = Cached<BatteryHealth?>(every: 300) { PowerSampler.batteryHealth() }
    private var blockers = Cached<[SleepBlocker]>(every: 60) { SleepAssertionSampler.sample() }

    func reset() {
        system.reset()
        processes.reset()
        network.reset()
    }

    func collect(isOnline: Bool) -> SystemSnapshot {
        let now = Date()
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
            network: network.sample(),
            power: PowerSampler.sample(health: battery.value(at: now)),
            sleepBlockers: blockers.value(at: now),
            processes: processes.sample()
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

    mutating func value(at now: Date) -> Value {
        if let stored, now.timeIntervalSince(loadedAt) < interval { return stored }
        let fresh = load()
        stored = fresh
        loadedAt = now
        return fresh
    }
}
