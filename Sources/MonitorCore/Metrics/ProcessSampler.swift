import Darwin
import Foundation

/// Raw per-process counters from one read.
public struct ProcessReading: Sendable, Equatable {
    public let pid: Int32
    /// Distinguishes a reused PID from the process that held it before.
    public let startTime: UInt64
    /// User + system CPU time in nanoseconds.
    public let cpuTimeNs: UInt64
    public let footprintBytes: UInt64

    public init(pid: Int32, startTime: UInt64, cpuTimeNs: UInt64, footprintBytes: UInt64) {
        self.pid = pid
        self.startTime = startTime
        self.cpuTimeNs = cpuTimeNs
        self.footprintBytes = footprintBytes
    }
}

/// Turns cumulative CPU times into percentages by diffing consecutive samples.
public struct ProcessCPUTracker: Sendable {
    private var previous: [Int32: ProcessReading] = [:]
    private var previousTimeNs: UInt64?

    public init() {}

    public mutating func reset() {
        previous = [:]
        previousTimeNs = nil
    }

    /// CPU percent per PID (100 = one core). Processes seen for the first time, or whose PID
    /// was reused since the last sample, report 0 until the next sample.
    public mutating func update(_ readings: [ProcessReading], nowNs: UInt64) -> [Int32: Double] {
        defer {
            previous = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
            previousTimeNs = nowNs
        }
        guard let lastNs = previousTimeNs, nowNs > lastNs else { return [:] }
        let elapsed = Double(nowNs - lastNs)
        var result: [Int32: Double] = [:]
        for reading in readings {
            guard let old = previous[reading.pid], old.startTime == reading.startTime,
                  reading.cpuTimeNs >= old.cpuTimeNs else { continue }
            result[reading.pid] = Double(reading.cpuTimeNs - old.cpuTimeNs) / elapsed * 100
        }
        return result
    }
}

/// Lists processes via libproc. Without root, other users' processes are skipped
/// (the kernel denies `proc_pid_rusage` for them); machine totals still include them.
public final class ProcessSampler {
    private var tracker = ProcessCPUTracker()
    private var names: [Int32: (startTime: UInt64, name: String)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)

    public init() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(info.denom))
    }

    public func reset() { tracker.reset() }

    public func sample() -> [ProcessStat] {
        let readings = read()
        let cpu = tracker.update(readings, nowNs: machToNs(mach_absolute_time()))

        let live = Set(readings.map(\.pid))
        names = names.filter { live.contains($0.key) }

        return readings.map { reading in
            ProcessStat(
                pid: reading.pid,
                name: name(for: reading),
                cpuPercent: cpu[reading.pid] ?? 0,
                footprintBytes: reading.footprintBytes
            )
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func read() -> [ProcessReading] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var readings: [ProcessReading] = []
        readings.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            readings.append(ProcessReading(
                pid: pid,
                startTime: info.ri_proc_start_abstime,
                cpuTimeNs: machToNs(info.ri_user_time &+ info.ri_system_time),
                footprintBytes: info.ri_phys_footprint
            ))
        }
        return readings
    }

    private func name(for reading: ProcessReading) -> String {
        if let cached = names[reading.pid], cached.startTime == reading.startTime {
            return cached.name
        }
        let resolved = Self.resolveName(pid: reading.pid)
        names[reading.pid] = (reading.startTime, resolved)
        return resolved
    }

    private static func resolveName(pid: Int32) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            let path = String(cString: pathBuffer)
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
            return String(cString: nameBuffer)
        }
        return "PID \(pid)"
    }

    private func machToNs(_ ticks: UInt64) -> UInt64 {
        timebase.numer == timebase.denom ? ticks : ticks / timebase.denom * timebase.numer
    }
}
