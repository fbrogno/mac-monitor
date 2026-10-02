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
