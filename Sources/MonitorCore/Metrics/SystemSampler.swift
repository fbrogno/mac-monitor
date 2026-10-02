import Darwin
import Foundation

/// Cumulative CPU ticks across all cores, as reported by `HOST_CPU_LOAD_INFO`.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share between two readings, 0…100. Counter wrap or no elapsed ticks yield 0.
    public static func usage(from old: CPUTicks, to new: CPUTicks) -> Double {
        guard new.user >= old.user, new.system >= old.system,
              new.idle >= old.idle, new.nice >= old.nice else { return 0 }
        let busy = (new.user - old.user) + (new.system - old.system) + (new.nice - old.nice)
        let total = busy + (new.idle - old.idle)
        return total == 0 ? 0 : Double(busy) / Double(total) * 100
    }
}

/// Machine-wide metrics straight from Mach and sysctl — no helper processes.
public final class SystemSampler {
    private let host = mach_host_self()
    private var lastTicks: CPUTicks?

    public init() {}

    public func reset() { lastTicks = nil }

    /// CPU usage since the previous call. The first call returns 0.
    public func cpuPercent() -> Double {
        guard let ticks = readTicks() else { return 0 }
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return 0 }
        return CPUTicks.usage(from: last, to: ticks)
    }

    private func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// Used memory as Activity Monitor counts it: app memory + wired + compressed.
    public func memoryUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    public var memoryTotalBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    public func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    public func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}
