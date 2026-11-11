import Darwin
import Foundation

/// Per-core CPU load from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
public final class CPUCoreSampler {
    private let host = mach_host_self()
    private var last: [CPUTicks]?
    private let efficiencyCount: Int
    private let performanceCount: Int

    public init() {
        (efficiencyCount, performanceCount) = Self.coreClasses()
    }

    public func reset() { last = nil }

    /// Load per core since the previous call; nil on the first call or when the kernel call fails.
    public func sample() -> CPUCoreLoad? {
        guard let ticks = readTicks() else { return nil }
        defer { last = ticks }
        guard let last, last.count == ticks.count else { return nil }
        let loads = zip(last, ticks).map { CPUTicks.usage(from: $0, to: $1) }
        // On Intel (or if the classes do not add up) everything counts as one class.
        let efficient = efficiencyCount + performanceCount == loads.count ? efficiencyCount : 0
        return CPUCoreLoad(perCore: loads, efficiencyCoreCount: efficient,
                           performanceCoreCount: loads.count - efficient)
    }

    private func readTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { core in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[core * stride + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// (efficiency, performance) logical core counts from `hw.perflevelN`. Level 0 is the fastest
    /// class; Intel Macs have no perflevels and report (0, all cores).
    static func coreClasses() -> (efficiency: Int, performance: Int) {
        func value(_ name: String) -> Int? {
            var result: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &result, &size, nil, 0) == 0 ? Int(result) : nil
        }
        guard let performance = value("hw.perflevel0.logicalcpu") else {
            return (0, value("hw.logicalcpu") ?? 0)
        }
        return (value("hw.perflevel1.logicalcpu") ?? 0, performance)
    }
}
