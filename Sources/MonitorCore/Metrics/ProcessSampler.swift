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
    /// Cumulative energy in nanojoules (`ri_energy_nj`); 0 where the kernel does not count it.
    public let energyNj: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let threads: Int

    public init(pid: Int32, startTime: UInt64, cpuTimeNs: UInt64, footprintBytes: UInt64,
                energyNj: UInt64 = 0, diskReadBytes: UInt64 = 0, diskWriteBytes: UInt64 = 0, threads: Int = 0) {
        self.pid = pid
        self.startTime = startTime
        self.cpuTimeNs = cpuTimeNs
        self.footprintBytes = footprintBytes
        self.energyNj = energyNj
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.threads = threads
    }
}

/// Per-process rates between two consecutive samples.
public struct ProcessRate: Sendable, Equatable {
    /// 100 = one fully busy core.
    public var cpuPercent: Double
    public var energyMilliwatts: Double
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
}

/// Turns cumulative per-process counters into rates by diffing consecutive samples.
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
        updateRates(readings, nowNs: nowNs).mapValues(\.cpuPercent)
    }

    /// CPU, energy and disk rates per PID. Energy is nanojoules per nanosecond, i.e. watts, reported
    /// in milliwatts. A counter that went backwards is treated as 0 for that metric.
    public mutating func updateRates(_ readings: [ProcessReading], nowNs: UInt64) -> [Int32: ProcessRate] {
        defer {
            previous = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
            previousTimeNs = nowNs
        }
        guard let lastNs = previousTimeNs, nowNs > lastNs else { return [:] }
        let elapsed = Double(nowNs - lastNs)
        let seconds = elapsed / 1e9
        func delta(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double(new - old) : 0 }
        var result: [Int32: ProcessRate] = [:]
        for reading in readings {
            guard let old = previous[reading.pid], old.startTime == reading.startTime,
                  reading.cpuTimeNs >= old.cpuTimeNs else { continue }
            result[reading.pid] = ProcessRate(
                cpuPercent: Double(reading.cpuTimeNs - old.cpuTimeNs) / elapsed * 100,
                energyMilliwatts: delta(reading.energyNj, old.energyNj) / elapsed * 1000,
                diskReadBytesPerSecond: delta(reading.diskReadBytes, old.diskReadBytes) / seconds,
                diskWriteBytesPerSecond: delta(reading.diskWriteBytes, old.diskWriteBytes) / seconds)
        }
        return result
    }
}

/// Lists processes via libproc. Without root, other users' processes are skipped
/// (the kernel denies `proc_pid_rusage` for them); machine totals still include them.
public final class ProcessSampler {
    private var tracker = ProcessCPUTracker()
    private var identities: [Int32: (startTime: UInt64, identity: ProcessIdentity)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64)
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private let responsiblePID: ResponsiblePID?

    /// Number of processes in the system (including ones this user cannot inspect) at the latest sample.
    public private(set) var systemProcessCount = 0
    /// Threads of the processes that could be inspected at the latest sample.
    public private(set) var visibleThreadCount = 0

    public init() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(info.denom))
        // Private libsystem call that tells which process is accountable for another (the app behind its helpers).
        responsiblePID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsiblePID.self) }
    }

    public func reset() { tracker.reset() }

    public func sample() -> [ProcessStat] {
        let readings = read()
        let rates = tracker.updateRates(readings, nowNs: machToNs(mach_absolute_time()))

        let live = Set(readings.map(\.pid))
        identities = identities.filter { live.contains($0.key) }
        let ids = readings.map { identity(for: $0) }
        let groups = AppGrouping.assign(ids)
        visibleThreadCount = readings.reduce(0) { $0 + $1.threads }

        return zip(readings, ids).map { reading, id in
            let rate = rates[reading.pid]
            let group = groups[reading.pid]
            return ProcessStat(
                pid: reading.pid,
                name: id.name,
                cpuPercent: rate?.cpuPercent ?? 0,
                footprintBytes: reading.footprintBytes,
                energyMilliwatts: rate?.energyMilliwatts ?? 0,
                threads: reading.threads,
                diskReadBytesPerSecond: rate?.diskReadBytesPerSecond ?? 0,
                diskWriteBytesPerSecond: rate?.diskWriteBytesPerSecond ?? 0,
                appKey: group?.key ?? "",
                appName: group?.name ?? id.name
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
        systemProcessCount = Int(count)

        var readings: [ProcessReading] = []
        readings.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard ok == 0 else { continue }
            readings.append(ProcessReading(
                pid: pid,
                startTime: info.ri_proc_start_abstime,
                cpuTimeNs: machToNs(info.ri_user_time &+ info.ri_system_time),
                footprintBytes: info.ri_phys_footprint,
                energyNj: info.ri_energy_nj,
                diskReadBytes: info.ri_diskio_bytesread,
                diskWriteBytes: info.ri_diskio_byteswritten,
                threads: threadCount(pid)
            ))
        }
        return readings
    }

    private func threadCount(_ pid: pid_t) -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? Int(info.pti_threadnum) : 0
    }

    private func identity(for reading: ProcessReading) -> ProcessIdentity {
        if let cached = identities[reading.pid], cached.startTime == reading.startTime {
            return cached.identity
        }
        let resolved = resolveIdentity(pid: reading.pid)
        identities[reading.pid] = (reading.startTime, resolved)
        return resolved
    }

    private func resolveIdentity(pid: Int32) -> ProcessIdentity {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : nil

        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            name = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : "PID \(pid)"
        }

        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let parent = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size ? Int32(bsd.pbi_ppid) : 0
        let responsible = responsiblePID?(pid)
        return ProcessIdentity(pid: pid, parentPid: parent,
                               responsiblePid: responsible.flatMap { $0 > 0 ? $0 : nil },
                               name: name, path: path)
    }

    private func machToNs(_ ticks: UInt64) -> UInt64 {
        timebase.numer == timebase.denom ? ticks : ticks / timebase.denom * timebase.numer
    }
}
