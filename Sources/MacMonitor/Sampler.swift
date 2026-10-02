import Foundation
import MonitorCore

/// Collects one `SystemSnapshot`. Not thread-safe: `@unchecked Sendable` only because it is
/// confined to `AppModel`'s serial sampling queue.
final class Sampler: @unchecked Sendable {
    private let system = SystemSampler()
    private let processes = ProcessSampler()
    private var disk: DiskStat?
    private var diskSampledAt: Date = .distantPast
    private let diskInterval: TimeInterval = 300

    func reset() {
        system.reset()
        processes.reset()
    }

    func collect(isOnline: Bool) -> SystemSnapshot {
        let now = Date()
        if now.timeIntervalSince(diskSampledAt) >= diskInterval {
            disk = DiskSampler.sample()
            diskSampledAt = now
        }
        return SystemSnapshot(
            date: now,
            cpuPercent: system.cpuPercent(),
            memoryUsedBytes: system.memoryUsedBytes(),
            memoryTotalBytes: system.memoryTotalBytes,
            memoryPressure: system.memoryPressure(),
            swapUsedBytes: system.swapUsedBytes(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            disk: disk,
            isOnline: isOnline,
            power: PowerSampler.sample(),
            processes: processes.sample()
        )
    }
}
