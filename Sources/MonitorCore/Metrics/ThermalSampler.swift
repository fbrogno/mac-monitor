import Foundation
import IOKit

/// Temperature sensors via the private `IOHIDEventSystemClient` (usage page 0xff00, usage 5).
/// The symbols are looked up at runtime, so a macOS release that drops them yields nil, not a crash.
public final class ThermalSampler {
    private struct HID {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
        typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

        let copyEvent: CopyEvent
        let floatValue: FloatValue
        let client: CFTypeRef
        let services: [CFTypeRef]
        let names: [String]

        init?() {
            guard let handle = dlopen(nil, RTLD_NOW),
                  let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
                  let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
                  let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
                  let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
                  let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
                  let floatValue = dlsym(handle, "IOHIDEventGetFloatValue"),
                  let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
            else { return nil }
            let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
            _ = unsafeBitCast(setMatching, to: SetMatching.self)(client, matching as CFDictionary)
            guard let list = unsafeBitCast(copyServices, to: CopyServices.self)(client)?.takeRetainedValue(),
                  CFArrayGetCount(list) > 0 else { return nil }
            let property = unsafeBitCast(copyProperty, to: CopyProperty.self)
            // Each read costs about 0.6 ms, so keep only useful sensors: one service per name
            // (the PMU chips repeat every sensor) and none of the junk "tdev"/"tcal" ones.
            var seen = Set<String>()
            var services: [CFTypeRef] = []
            var names: [String] = []
            for service in (list as [AnyObject]).map({ $0 as CFTypeRef }) {
                let name = (property(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
                guard ThermalSampler.isUsableSensor(name), seen.insert(name).inserted else { continue }
                services.append(service)
                names.append(name)
            }
            guard !services.isEmpty else { return nil }
            self.copyEvent = unsafeBitCast(copyEvent, to: CopyEvent.self)
            self.floatValue = unsafeBitCast(floatValue, to: FloatValue.self)
            self.client = client
            self.services = services
            self.names = names
        }

        /// Raw (name, °C) pairs; services without an event are skipped.
        func readAll() -> [(name: String, celsius: Double)] {
            let temperatureType: Int64 = 15 // kIOHIDEventTypeTemperature
            var result: [(String, Double)] = []
            result.reserveCapacity(services.count)
            for (service, name) in zip(services, names) {
                guard let event = copyEvent(service, temperatureType, 0, 0)?.takeRetainedValue() else { continue }
                result.append((name, floatValue(event, Int32(temperatureType << 16))))
            }
            return result
        }
    }

    private let hid = HID()
    private let smc: SMCSampler

    public init(smc: SMCSampler = SMCSampler()) { self.smc = smc }

    public var isAvailable: Bool { hid != nil || smc.isAvailable }

    /// `batteryCelsius` is used when the HID gas-gauge sensor is missing.
    public func sample(batteryCelsius: Double? = nil) -> ThermalSensors? {
        let raw = hid?.readAll() ?? []
        var result = Self.summarize(raw, batteryCelsius: batteryCelsius)
        if result.cpuAverageCelsius == nil, let legacy = smc.legacyCPUTemperature() {
            result = ThermalSensors(cpuAverageCelsius: legacy, cpuMaxCelsius: legacy,
                                    batteryCelsius: result.batteryCelsius, sensors: result.sensors)
        }
        return result.sensors.isEmpty && result.cpuAverageCelsius == nil ? nil : result
    }

    /// Pure aggregation of raw readings. Drops implausible values, merges duplicate names by averaging, and
    /// derives the CPU/SoC statistics from the die sensors.
    static func summarize(_ raw: [(name: String, celsius: Double)], batteryCelsius: Double?) -> ThermalSensors {
        let valid = raw.filter { $0.celsius > 0 && $0.celsius < 150 && isUsableSensor($0.name) }
        let grouped = Dictionary(grouping: valid, by: \.name).map { name, items in
            TemperatureReading(name: name, celsius: items.map(\.celsius).reduce(0, +) / Double(items.count))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let cpu = valid.filter(isCPUDieSensor).map(\.celsius)
        let battery = batteryCelsius ?? valid.first { $0.name.contains("battery") }?.celsius
        return ThermalSensors(
            cpuAverageCelsius: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
            cpuMaxCelsius: cpu.max(), batteryCelsius: battery, sensors: grouped)
    }

    /// Names that carry a real temperature: PMU "tdev" sensors report about -9200 and "tcal" is a
    /// calibration value.
    static func isUsableSensor(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("tdev") && !name.contains("tcal")
    }

    /// Die sensors: "PMU tdie*" on M2 and later, "pACC/eACC MTR Temp Sensor*" on M1.
    static func isCPUDieSensor(_ reading: (name: String, celsius: Double)) -> Bool {
        reading.name.hasPrefix("PMU tdie") || reading.name.contains("ACC MTR Temp")
    }
}
