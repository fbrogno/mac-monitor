import Foundation
import IOKit

public enum VolumeSampler {
    /// All mounted local, browsable volumes (system-internal ones such as /System/Volumes/VM are
    /// hidden), boot volume first.
    public static func sample() -> [VolumeStat] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                      .volumeIsBrowsableKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeStat? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeStat(name: v.volumeName ?? url.lastPathComponent, path: url.path,
                              availableBytes: UInt64(max(available, 0)), totalBytes: UInt64(total),
                              isInternal: v.volumeIsInternal ?? false)
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }
}

/// Cumulative storage byte counters at one moment.
struct DiskCounters: Equatable {
    var read: UInt64
    var written: UInt64
    var time: TimeInterval

    /// Throughput between two readings; counter resets (a drive disappeared) yield nil.
    static func throughput(from old: DiskCounters, to new: DiskCounters) -> DiskThroughput? {
        let elapsed = new.time - old.time
        guard elapsed > 0, new.read >= old.read, new.written >= old.written else { return nil }
        return DiskThroughput(readBytesPerSecond: Double(new.read - old.read) / elapsed,
                              writeBytesPerSecond: Double(new.written - old.written) / elapsed)
    }
}

/// System-wide read/write throughput from the `IOBlockStorageDriver` statistics. Mounted disk
/// images are skipped because their traffic is already counted on the physical drive below them.
public final class DiskIOSampler {
    private var last: DiskCounters?

    public init() {}

    public func reset() { last = nil }

    public func sample() -> DiskThroughput? {
        guard let counters = Self.readCounters() else { return nil }
        defer { last = counters }
        guard let last else { return nil }
        return DiskCounters.throughput(from: last, to: counters)
    }

    static func readCounters() -> DiskCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var found = false
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard !isDiskImage(driver),
                  let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            found = true
        }
        return found ? DiskCounters(read: read, written: written, time: ProcessInfo.processInfo.systemUptime) : nil
    }

    private static func isDiskImage(_ entry: io_registry_entry_t) -> Bool {
        var current = entry
        IOObjectRetain(current)
        while true {
            if IOObjectConformsTo(current, "AppleDiskImageDevice") != 0 {
                IOObjectRelease(current)
                return true
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS else { return false }
            current = parent
        }
    }
}

/// NVMe SMART summary through the `NVMeSMARTLib` plug-in of the internal SSD. Works without root.
public enum SSDHealthSampler {
    public static func sample() -> SSDHealth? {
        let match = ["IOPropertyMatch": ["NVMe SMART Capable": true]] as CFDictionary
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let data = readSMART(service), let health = parse(data) { return health }
        }
        return nil
    }

    /// 512-byte SMART log page via the plug-in's `SMARTReadData`.
    private static func readSMART(_ service: io_service_t) -> [UInt8]? {
        let userClientType = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                                            0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
        let plugInInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                             0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let smartInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                                            0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, userClientType, plugInInterface, &plugin, &score) == KERN_SUCCESS,
              let plugin, let table = plugin.pointee else { return nil }
        defer { _ = table.pointee.Release(plugin) }

        var raw: LPVOID?
        guard table.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &raw) == 0, let raw else { return nil }
        // `IONVMeSMARTInterface`: IUnknown (4 pointers), version + revision (padded to 8), then `SMARTReadData`.
        typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
        let vtable = raw.load(as: UnsafeRawPointer.self)
        let readData = unsafeBitCast(vtable.load(fromByteOffset: 40, as: UnsafeRawPointer.self), to: ReadData.self)
        var page = [UInt8](repeating: 0, count: 512)
        let status = page.withUnsafeMutableBytes { readData(raw, $0.baseAddress) }
        // Release the smart interface (same IUnknown vtable layout: slot 3).
        typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        _ = unsafeBitCast(vtable.load(fromByteOffset: 24, as: UnsafeRawPointer.self), to: Release.self)(raw)
        return status == 0 ? page : nil
    }

    /// Pure parser for the NVMe SMART / health log page (NVM Express 1.x, section 5.14.1.2).
    static func parse(_ page: [UInt8]) -> SSDHealth? {
        guard page.count >= 512 else { return nil }
        func u16(_ o: Int) -> Int { Int(page[o]) | Int(page[o + 1]) << 8 }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(page[o + $1]) << UInt64(8 * $1) } }
        let kelvin = u16(1)
        let units = u64(48) // data units written, each 1000 x 512 bytes
        return SSDHealth(
            isVerified: page[0] == 0,
            percentageUsed: Int(page[5]),
            availableSparePercent: Int(page[3]),
            temperatureCelsius: kelvin > 0 ? Double(kelvin) - 273.15 : nil,
            powerOnHours: u64(128),
            bytesWritten: units.multipliedReportingOverflow(by: 512_000).overflow ? nil : units * 512_000)
    }
}

public enum RuntimeSampler {
    /// Uptime since boot including sleep, like the `uptime` command.
    public static func uptimeSeconds() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }

    public static func loadAverage() -> LoadAverage? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return LoadAverage(one: loads[0], five: loads[1], fifteen: loads[2])
    }
}
