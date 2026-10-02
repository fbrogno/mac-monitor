import Foundation

public enum DiskSampler {
    /// Free space on the boot volume as Finder reports it (includes purgeable space).
    public static func sample(path: String = "/") -> DiskStat? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return DiskStat(availableBytes: UInt64(max(available, 0)), totalBytes: UInt64(max(total, 0)))
    }
}
