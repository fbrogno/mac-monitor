import Foundation
import IOKit

public enum GPUSampler {
    /// Utilization from the accelerator's `PerformanceStatistics`. With several GPUs the busiest wins.
    public static func sample() -> GPUStat? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: GPUStat?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let stat = parse(stats) else { continue }
            if best == nil || stat.utilizationPercent > best!.utilizationPercent { best = stat }
        }
        return best
    }

    /// Pure parser for the `PerformanceStatistics` dictionary.
    static func parse(_ stats: [String: Any]) -> GPUStat? {
        guard let utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
        func bytes(_ key: String) -> UInt64? { (stats[key] as? NSNumber).map { $0.uint64Value } }
        return GPUStat(utilizationPercent: min(100, max(0, utilization)),
                       memoryUsedBytes: bytes("In use system memory"),
                       memoryAllocatedBytes: bytes("Alloc system memory"))
    }
}
