import Foundation

/// Rules that build on the extended metrics (sensors, fans, battery detail, SSD, volumes, GPU).
/// A missing value (nil / empty) never triggers anything.
extension Rules {
    private static let gigabyte = 1_073_741_824.0

    static func extended(_ s: SystemSnapshot, _ ctx: Context, ignored: Set<String>) -> [Condition] {
        let set = ctx.settings
        var out: [Condition] = []

        // CPU temperature in °C. The coarse thermal-state rule already reports the same cause once
        // macOS itself throttles, so this one steps aside then.
        let thermalRuleSpeaks = set.isEnabled(.thermal) && s.thermal >= .serious
        if set.isEnabled(.cpuTemperature), !thermalRuleSpeaks, let hottest = s.thermals?.cpuMaxCelsius {
            let key = "system.cpuTemperature"
            if hottest >= ctx.limit(set.cpuTempThreshold, key: key) {
                out.append(Condition(
                    key: key, rule: .cpuTemperature, severity: .warning,
                    title: L("CPU bei \(Format.decimal(hottest, digits: 0)) °C"),
                    body: L("Die CPU ist seit über \(Format.duration(set.cpuTempSustain)) heißer als \(Format.decimal(set.cpuTempThreshold, digits: 0)) °C. Reduziere die Last, bevor macOS drosselt."),
                    sustain: set.cpuTempSustain))
            }
        }

        if set.isEnabled(.fanMaxed) {
            for fan in s.fans where fan.maxRpm > 0 {
                let key = "fan.\(fan.index)"
                let percent = fan.fraction * 100
                guard percent >= ctx.limit(set.fanMaxPercent, key: key) else { continue }
                out.append(Condition(
                    key: key, rule: .fanMaxed, severity: .warning,
                    title: L("Lüfter \(fan.index + 1) läuft mit \(Format.percent(percent)) seiner Drehzahl"),
                    body: L("Der Lüfter dreht seit über \(Format.duration(set.fanMaxSustain)) mit \(String(Int(fan.rpm.rounded()))) von höchstens \(String(Int(fan.maxRpm.rounded()))) U/min. Der Mac kämpft gegen die Wärme."),
                    sustain: set.fanMaxSustain))
            }
        }

        if set.isEnabled(.batteryHealth) {
            let capacity = batteryCapacityPercent(s)
            let service = s.batteryDetail?.condition == .serviceRecommended
            let worn = capacity.map { $0 < set.batteryHealthMinPercent } ?? false
            if worn || service {
                let pct = capacity.map { Format.decimal($0, digits: 0) } ?? "?"
                let cycles = s.power.health?.cycleCount
                let title: String
                let body: String
                if service {
                    title = L("macOS empfiehlt einen Akku-Service")
                    body = capacity == nil
                        ? L("macOS meldet für den Akku den Zustand „Service empfohlen“.")
                        : L("Der Akku fasst nur noch \(pct) % seiner ursprünglichen Kapazität, macOS meldet „Service empfohlen“.")
                } else if let cycles {
                    title = L("Akku hat nur noch \(pct) % Kapazität")
                    body = L("Der Akku fasst nach \(cycles) Ladezyklen nur noch \(pct) % seiner ursprünglichen Kapazität. Die Laufzeit ist entsprechend kürzer.")
                } else {
                    title = L("Akku hat nur noch \(pct) % Kapazität")
                    body = L("Der Akku fasst nur noch \(pct) % seiner ursprünglichen Kapazität. Die Laufzeit ist entsprechend kürzer.")
                }
                out.append(Condition(
                    key: "battery.health", rule: .batteryHealth, severity: .info, title: title, body: body,
                    sustain: 0, reminderInterval: set.longReminderInterval))
            }
        }

        // Plugged in, yet the battery still drains: the adapter cannot keep up with the load.
        if set.isEnabled(.batteryDrainOnAC), !s.power.onBattery, !s.power.isCharging,
           let drain = s.batteryDetail?.dischargeWatts {
            let key = "battery.drainOnAC"
            let limit = ctx.isActive(key) ? 0.5 : 1.0
            if drain >= limit {
                out.append(Condition(
                    key: key, rule: .batteryDrainOnAC, severity: .warning,
                    title: L("Akku entlädt sich trotz Netzteil"),
                    body: L("Der Mac hängt am Netzteil, der Akku verliert seit über \(Format.duration(set.batteryDrainSustain)) aber Ladung (\(Format.decimal(drain, digits: 1)) W). Das Netzteil ist vermutlich zu schwach für die aktuelle Last."),
                    sustain: set.batteryDrainSustain))
            }
        }

        if set.isEnabled(.energyHog), s.power.onBattery {
            let base = set.energyHogWatts * 1000
            for app in AppGrouping.aggregate(s.processes)
            where !ignored.contains(app.name.lowercased()) && !ctx.mutedProcesses.contains(app.name) {
                let key = "energy.\(app.key)"
                let milliwatts = ctx.averagedAppEnergyMilliwatts[app.key] ?? app.energyMilliwatts
                guard milliwatts >= ctx.limit(base, key: key) else { continue }
                let main = s.processes.filter { ($0.appKey.isEmpty ? "proc:\($0.pid)" : $0.appKey) == app.key }
                    .max { $0.energyMilliwatts < $1.energyMilliwatts }
                out.append(Condition(
                    key: key, rule: .energyHog, severity: .warning,
                    title: L("\(app.name) verbraucht \(Format.decimal(milliwatts / 1000, digits: 1)) W im Akkubetrieb"),
                    body: L("Die App zieht seit über \(Format.duration(set.energyHogSustain)) im Durchschnitt mehr als \(Format.decimal(set.energyHogWatts, digits: 0)) W aus dem Akku."),
                    sustain: set.energyHogSustain,
                    process: main.map { ProcessRef(pid: $0.pid, name: $0.name) }))
            }
        }

        if set.isEnabled(.ssdWear), let ssd = s.ssdHealth {
            let key = "ssd.wear"
            let active = ctx.isActive(key)
            let worn = Double(ssd.percentageUsed) >= (active ? set.ssdWearPercent * hysteresis : set.ssdWearPercent)
            let spareLow = Double(ssd.availableSparePercent) < set.ssdSpareMinPercent * (active ? 1 / hysteresis : 1)
            if worn || spareLow {
                let severe = ssd.percentageUsed >= 90 || ssd.availableSparePercent < 10
                out.append(Condition(
                    key: key, rule: .ssdWear, severity: severe ? .warning : .info,
                    title: worn ? L("SSD zu \(ssd.percentageUsed) % abgenutzt") : L("SSD-Reserve nur noch \(ssd.availableSparePercent) %"),
                    body: worn
                        ? L("Die SSD hat laut Selbstdiagnose \(ssd.percentageUsed) % ihrer geplanten Lebensdauer verbraucht, die Reserve liegt bei \(ssd.availableSparePercent) %. Sichere wichtige Daten regelmäßig.")
                        : L("Die Reserve der SSD ist auf \(ssd.availableSparePercent) % gesunken, die Abnutzung liegt bei \(ssd.percentageUsed) %. Sichere wichtige Daten regelmäßig."),
                    sustain: 0, reminderInterval: set.longReminderInterval))
            }
        }

        if set.isEnabled(.volumeFull) {
            let diskRuleCoversBootVolume = set.isEnabled(.disk)
            for volume in s.volumes where volume.totalBytes >= UInt64(gigabyte) {
                // The system volume belongs to the "Festplatte voll" rule.
                if diskRuleCoversBootVolume && volume.path == "/" { continue }
                let key = "volume.\(volume.path)"
                let factor = ctx.isActive(key) ? 1 / hysteresis : 1
                let tooLowFraction = volume.freeFraction * 100 < set.diskMinFreePercent * factor
                let tooLowBytes = Double(volume.availableBytes) < set.diskMinFreeGB * gigabyte * factor
                guard tooLowFraction || tooLowBytes else { continue }
                out.append(Condition(
                    key: key, rule: .volumeFull,
                    severity: Double(volume.availableBytes) < 5 * gigabyte ? .critical : .warning,
                    title: L("Auf „\(volume.name)“ sind nur noch \(Format.bytes(volume.availableBytes)) frei"),
                    body: L("Das Volume „\(volume.name)“ (\(volume.path)) ist zu \(Format.percent((1 - volume.freeFraction) * 100)) voll."),
                    sustain: 0))
            }
        }

        if set.isEnabled(.gpuHigh), let gpu = s.gpu {
            let key = "system.gpu"
            if gpu.utilizationPercent >= ctx.limit(set.gpuHighThreshold, key: key) {
                out.append(Condition(
                    key: key, rule: .gpuHigh, severity: .warning,
                    title: L("GPU seit \(Format.duration(set.gpuHighSustain)) bei \(Format.percent(gpu.utilizationPercent))"),
                    body: L("Die Grafikeinheit ist dauerhaft stark ausgelastet. Das kostet Akku und erzeugt Wärme."),
                    sustain: set.gpuHighSustain))
            }
        }

        return out
    }

    /// Full-charge capacity relative to the design capacity, 0…100+. Falls back to the coarser
    /// percentage from `PowerState.health` when the battery detail is unavailable.
    static func batteryCapacityPercent(_ s: SystemSnapshot) -> Double? {
        if let d = s.batteryDetail, d.designCapacityMah > 0 {
            return Double(d.maxCapacityMah) / Double(d.designCapacityMah) * 100
        }
        return s.power.health.map { Double($0.capacityPercent) }
    }
}
