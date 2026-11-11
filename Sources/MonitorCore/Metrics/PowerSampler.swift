import Foundation
import IOKit
import IOKit.ps

public enum PowerSampler {
    public static func sample(health: BatteryHealth? = nil) -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey

        var percent: Int?
        var charging = false
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
        }

        let estimate = IOPSGetTimeRemainingEstimate()
        let minutes = onBattery && estimate > 0 ? Int(estimate / 60) : nil
        return PowerState(onBattery: onBattery, batteryPercent: percent, lowPowerMode: lowPower,
                          isCharging: charging, minutesRemaining: minutes, health: percent == nil ? nil : health)
    }

    /// Capacity in mAh, temperature, voltage/current and adapter rating from the AppleSmartBattery
    /// registry entry. nil on Macs without a battery.
    public static func batteryDetail() -> BatteryDetail? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return parseBatteryDetail(dictionary)
    }

    /// Pure parser for the AppleSmartBattery properties.
    static func parseBatteryDetail(_ p: [String: Any]) -> BatteryDetail? {
        // Registry numbers may arrive as unsigned 64-bit values; a negative current shows up as 2^64 - n.
        func int(_ key: String) -> Int? { (p[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) } }
        guard (p["BatteryInstalled"] as? Bool) ?? true,
              let design = int("DesignCapacity"), design > 0,
              let maxCapacity = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"), maxCapacity > 0
        else { return nil }

        let rawTemperature = int("Temperature")
        let amperage = int("InstantAmperage") ?? int("Amperage")
        let adapter = (p["AdapterDetails"] as? [String: Any]).flatMap { ($0["Watts"] as? NSNumber)?.intValue }
        // AvgTimeToFull is 65535 while the estimate is unknown or the battery is not charging.
        let toFull = int("AvgTimeToFull").flatMap { $0 > 0 && $0 < 65_535 ? $0 : nil }
        let charging = (p["IsCharging"] as? Bool) ?? false
        // macOS shows "Service Recommended" below 80 % of design capacity.
        let worn = Double(maxCapacity) / Double(design) < 0.8
        let failed = (int("PermanentFailureStatus") ?? 0) != 0
        return BatteryDetail(
            designCapacityMah: design, maxCapacityMah: maxCapacity,
            currentCapacityMah: int("AppleRawCurrentCapacity"),
            temperatureCelsius: rawTemperature.flatMap { $0 > 0 ? Double($0) / 100 : nil },
            condition: worn || failed ? .serviceRecommended : .normal,
            minutesToFull: charging ? toFull : nil,
            voltageMillivolts: int("Voltage"), amperageMilliamps: amperage, adapterWatts: adapter)
    }

    /// Cycle count and capacity from the AppleSmartBattery registry entry. Changes slowly;
    /// callers should cache it.
    public static func batteryHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        guard let cycles = int("CycleCount"),
              let design = int("DesignCapacity"), design > 0,
              let maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") else { return nil }
        return BatteryHealth(cycleCount: cycles, capacityPercent: min(100, maxCapacity * 100 / design))
    }
}
