import Foundation
import Testing
@testable import MonitorCore

private let gb: UInt64 = 1_073_741_824

private func snap(
    onBattery: Bool = false,
    charging: Bool = false,
    batteryPercent: Int? = 80,
    health: BatteryHealth? = nil,
    thermal: ThermalLevel = .nominal,
    thermals: ThermalSensors? = nil,
    fans: [FanStat] = [],
    powerDraw: SystemPowerDraw? = nil,
    battery: BatteryDetail? = nil,
    volumes: [VolumeStat] = [],
    ssd: SSDHealth? = nil,
    gpu: GPUStat? = nil,
    cpu: Double = 10,
    used: UInt64 = 8 * gb,
    swap: UInt64 = 0,
    disk: DiskStat? = DiskStat(availableBytes: 200 * gb, totalBytes: 1000 * gb),
    network: NetworkRate? = nil,
    processes: [ProcessStat] = []
) -> SystemSnapshot {
    SystemSnapshot(
        date: .now, cpuPercent: cpu, memoryUsedBytes: used, memoryTotalBytes: 24 * gb,
        memoryPressure: .normal, swapUsedBytes: swap, thermal: thermal, disk: disk, isOnline: true,
        network: network,
        power: PowerState(onBattery: onBattery, batteryPercent: batteryPercent, lowPowerMode: false,
                          isCharging: charging, health: health),
        processes: processes, gpu: gpu, thermals: thermals, fans: fans, powerDraw: powerDraw,
        batteryDetail: battery, volumes: volumes, ssdHealth: ssd)
}

private func sensors(_ max: Double?) -> ThermalSensors {
    ThermalSensors(cpuAverageCelsius: nil, cpuMaxCelsius: max, batteryCelsius: nil, sensors: [])
}

private func battery(max: Int = 5000, design: Int = 5000, condition: BatteryCondition = .normal,
                     mv: Int? = nil, ma: Int? = nil) -> BatteryDetail {
    BatteryDetail(designCapacityMah: design, maxCapacityMah: max, condition: condition,
                  voltageMillivolts: mv, amperageMilliamps: ma)
}

private func evaluate(_ s: SystemSnapshot, settings: MonitorSettings = MonitorSettings(),
                      active: Set<String> = [], muted: Set<String> = [],
                      averages: [String: Double] = [:]) -> [Condition] {
    Rules.evaluate(s, Rules.Context(settings: settings, isActive: { active.contains($0) },
                                    mutedProcesses: muted, averagedAppEnergyMilliwatts: averages))
}

private func only(_ rule: RuleID, _ conditions: [Condition]) -> [Condition] {
    conditions.filter { $0.rule == rule }
}

private func disabled(_ rule: RuleID) -> MonitorSettings {
    var s = MonitorSettings()
    s.enabledRules.remove(rule)
    return s
}

// MARK: - Built-in rules

@Suite struct ExtendedRuleTests {
    @Test func cpuTemperature() {
        let hot = only(.cpuTemperature, evaluate(snap(thermals: sensors(96))))
        #expect(hot.count == 1)
        #expect(hot[0].sustain == 120)
        #expect(hot[0].title == "CPU bei 96 °C")
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(94.9)))).isEmpty)
        // Hysteresis: 85 % of 95 = 80.75 while active.
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(82)), active: ["system.cpuTemperature"])).count == 1)
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(80)), active: ["system.cpuTemperature"])).isEmpty)
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(82)))).isEmpty)
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(nil)))).isEmpty)
        #expect(only(.cpuTemperature, evaluate(snap(thermals: nil))).isEmpty)
        #expect(only(.cpuTemperature, evaluate(snap(thermals: sensors(99)), settings: disabled(.cpuTemperature))).isEmpty)
    }

    @Test func cpuTemperatureStepsAsideForThermalRule() {
        let all = evaluate(snap(thermal: .serious, thermals: sensors(99)))
        #expect(only(.thermal, all).count == 1)
        #expect(only(.cpuTemperature, all).isEmpty)
        // With the thermal rule off, the temperature rule speaks.
        let withoutThermal = evaluate(snap(thermal: .serious, thermals: sensors(99)), settings: disabled(.thermal))
        #expect(only(.cpuTemperature, withoutThermal).count == 1)
        // Fair state is not reported by the thermal rule, so no overlap.
        #expect(only(.cpuTemperature, evaluate(snap(thermal: .fair, thermals: sensors(99)))).count == 1)
    }

    @Test func fanMaxed() {
        let fan = FanStat(index: 0, rpm: 5400, minRpm: 1200, maxRpm: 6000)
        let c = only(.fanMaxed, evaluate(snap(fans: [fan])))
        #expect(c.map(\.key) == ["fan.0"])
        #expect(c[0].sustain == 300)
        #expect(only(.fanMaxed, evaluate(snap(fans: [FanStat(index: 0, rpm: 5340, minRpm: 1200, maxRpm: 6000)]))).isEmpty)
        // 90 % * 0.85 = 76.5 % while active.
        let mid = FanStat(index: 1, rpm: 4800, minRpm: 1200, maxRpm: 6000)
        #expect(only(.fanMaxed, evaluate(snap(fans: [mid]), active: ["fan.1"])).count == 1)
        #expect(only(.fanMaxed, evaluate(snap(fans: [mid]))).isEmpty)
        #expect(only(.fanMaxed, evaluate(snap(fans: []))).isEmpty)
        #expect(only(.fanMaxed, evaluate(snap(fans: [FanStat(index: 0, rpm: 100, minRpm: 0, maxRpm: 0)]))).isEmpty)
        #expect(only(.fanMaxed, evaluate(snap(fans: [fan]), settings: disabled(.fanMaxed))).isEmpty)
        // One key per fan.
        let two = [fan, FanStat(index: 1, rpm: 5700, minRpm: 1200, maxRpm: 6000)]
        #expect(only(.fanMaxed, evaluate(snap(fans: two))).map(\.key) == ["fan.0", "fan.1"])
    }

    @Test func batteryHealth() {
        let worn = only(.batteryHealth, evaluate(snap(battery: battery(max: 3900))))
        #expect(worn.count == 1)
        #expect(worn[0].severity == .info)
        #expect(worn[0].sustain == 0)
        #expect(worn[0].reminderInterval == TimeInterval(7 * 86_400))
        #expect(worn[0].title == "Akku hat nur noch 78 % Kapazität")
        #expect(only(.batteryHealth, evaluate(snap(battery: battery(max: 4000)))).isEmpty)
        #expect(only(.batteryHealth, evaluate(snap(battery: battery(max: 4900)))).isEmpty)
        let service = only(.batteryHealth, evaluate(snap(battery: battery(max: 4900, condition: .serviceRecommended))))
        #expect(service.count == 1)
        #expect(service[0].title == "macOS empfiehlt einen Akku-Service")
        #expect(only(.batteryHealth, evaluate(snap())).isEmpty)
        #expect(only(.batteryHealth, evaluate(snap(battery: battery(max: 100, design: 0)))).isEmpty)
        #expect(only(.batteryHealth, evaluate(snap(battery: battery(max: 3000)), settings: disabled(.batteryHealth))).isEmpty)
    }

    @Test func batteryHealthFallsBackToPowerHealth() {
        let c = only(.batteryHealth, evaluate(snap(health: BatteryHealth(cycleCount: 900, capacityPercent: 74))))
        #expect(c.count == 1)
        #expect(c[0].body.contains("900 Ladezyklen"))
        #expect(only(.batteryHealth, evaluate(snap(health: BatteryHealth(cycleCount: 900, capacityPercent: 90)))).isEmpty)
    }

    @Test func batteryHealthRemindsOnlyEverySevenDays() {
        var engine = AlertEngine()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let s = snap(battery: battery(max: 3900))
        #expect(engine.process(evaluate(s), now: t0).map(\.kind) == [.fired])
        #expect(engine.process(evaluate(s), now: t0 + 3600).isEmpty)
        #expect(engine.process(evaluate(s), now: t0 + 2 * 86_400).isEmpty)
        #expect(engine.process(evaluate(s), now: t0 + 7 * 86_400).map(\.kind) == [.reminder])
    }

    @Test func batteryDrainOnAC() {
        // 12 V at -2 A drains 24 W.
        let drain = battery(mv: 12_000, ma: -2000)
        let c = only(.batteryDrainOnAC, evaluate(snap(battery: drain)))
        #expect(c.count == 1)
        #expect(c[0].sustain == 600)
        #expect(c[0].body.contains("24,0 W"))
        // Charging, or on battery: not this rule.
        #expect(only(.batteryDrainOnAC, evaluate(snap(onBattery: true, battery: drain))).isEmpty)
        #expect(only(.batteryDrainOnAC, evaluate(snap(charging: true, battery: drain))).isEmpty)
        #expect(only(.batteryDrainOnAC, evaluate(snap(battery: battery(mv: 12_000, ma: 1500)))).isEmpty)
        // Below the 1 W noise floor, but kept while active (0,5 W).
        let faint = battery(mv: 12_000, ma: -70)
        #expect(only(.batteryDrainOnAC, evaluate(snap(battery: faint))).isEmpty)
        #expect(only(.batteryDrainOnAC, evaluate(snap(battery: faint), active: ["battery.drainOnAC"])).count == 1)
        // No data.
        #expect(only(.batteryDrainOnAC, evaluate(snap(battery: battery()))).isEmpty)
        #expect(only(.batteryDrainOnAC, evaluate(snap())).isEmpty)
        #expect(only(.batteryDrainOnAC, evaluate(snap(battery: drain), settings: disabled(.batteryDrainOnAC))).isEmpty)
    }

    private func app(_ key: String, _ name: String, mw: Double, pid: Int32 = 500) -> ProcessStat {
        ProcessStat(pid: pid, name: name, cpuPercent: 5, footprintBytes: gb, energyMilliwatts: mw,
                    appKey: key, appName: name)
    }

    @Test func energyHog() {
        let s = snap(onBattery: true, processes: [app("app:/Applications/Zoom.app", "Zoom", mw: 9000)])
        let c = only(.energyHog, evaluate(s))
        #expect(c.map(\.key) == ["energy.app:/Applications/Zoom.app"])
        #expect(c[0].sustain == 300)
        #expect(c[0].process?.pid == 500)
        #expect(c[0].title == "Zoom verbraucht 9,0 W im Akkubetrieb")
        let below = snap(onBattery: true, processes: [app("app:/Applications/Zoom.app", "Zoom", mw: 7900)])
        #expect(only(.energyHog, evaluate(below)).isEmpty)
        // Hysteresis: 85 % of 8 W = 6,8 W while active.
        let mid = snap(onBattery: true, processes: [app("app:/Applications/Zoom.app", "Zoom", mw: 7000)])
        #expect(only(.energyHog, evaluate(mid, active: ["energy.app:/Applications/Zoom.app"])).count == 1)
        #expect(only(.energyHog, evaluate(mid)).isEmpty)
        // Only on battery.
        #expect(only(.energyHog, evaluate(snap(onBattery: false, processes: [app("app:/Applications/Zoom.app", "Zoom", mw: 9000)]))).isEmpty)
        // Disabled, ignored and muted apps.
        #expect(only(.energyHog, evaluate(s, settings: disabled(.energyHog))).isEmpty)
        #expect(only(.energyHog, evaluate(s, muted: ["Zoom"])).isEmpty)
        var ignoring = MonitorSettings()
        ignoring.ignoredProcesses = ["zoom"]
        #expect(only(.energyHog, evaluate(s, settings: ignoring)).isEmpty)
        // No energy data (0 mW) never triggers.
        #expect(only(.energyHog, evaluate(snap(onBattery: true, processes: [app("app:/A.app", "A", mw: 0)]))).isEmpty)
    }

    @Test func energyHogSumsHelpersAndUsesAverages() {
        let key = "app:/Applications/Browser.app"
        let procs = [app(key, "Browser", mw: 5000, pid: 300), app(key, "Browser Helper", mw: 4000, pid: 301)]
        let c = only(.energyHog, evaluate(snap(onBattery: true, processes: procs)))
        #expect(c.count == 1)
        #expect(c[0].process?.pid == 300)
        // A supplied five-minute mean wins over the current reading.
        #expect(only(.energyHog, evaluate(snap(onBattery: true, processes: procs), averages: [key: 3000])).isEmpty)
        #expect(only(.energyHog, evaluate(snap(onBattery: true, processes: [app(key, "Browser", mw: 100)]),
                                          averages: [key: 12_000])).count == 1)
    }

    @Test func ssdWear() {
        let worn = only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 80, availableSparePercent: 100))))
        #expect(worn.count == 1)
        #expect(worn[0].severity == .info)
        #expect(worn[0].reminderInterval == TimeInterval(7 * 86_400))
        #expect(worn[0].title == "SSD zu 80 % abgenutzt")
        #expect(only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 79, availableSparePercent: 100)))).isEmpty)
        let spare = only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 10, availableSparePercent: 19))))
        #expect(spare.count == 1)
        #expect(spare[0].title == "SSD-Reserve nur noch 19 %")
        #expect(only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 10, availableSparePercent: 20)))).isEmpty)
        let severe = only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 92, availableSparePercent: 100))))
        #expect(severe[0].severity == .warning)
        // Hysteresis: wear 70 stays reported while active (limit 68).
        let mid = SSDHealth(isVerified: true, percentageUsed: 70, availableSparePercent: 100)
        #expect(only(.ssdWear, evaluate(snap(ssd: mid), active: ["ssd.wear"])).count == 1)
        #expect(only(.ssdWear, evaluate(snap(ssd: mid))).isEmpty)
        #expect(only(.ssdWear, evaluate(snap(ssd: nil))).isEmpty)
        #expect(only(.ssdWear, evaluate(snap(ssd: SSDHealth(isVerified: true, percentageUsed: 95, availableSparePercent: 5)),
                                        settings: disabled(.ssdWear))).isEmpty)
    }

    @Test func volumeFull() {
        let full = VolumeStat(name: "Backup", path: "/Volumes/Backup", availableBytes: 20 * gb, totalBytes: 1000 * gb, isInternal: false)
        let c = only(.volumeFull, evaluate(snap(volumes: [full])))
        #expect(c.map(\.key) == ["volume./Volumes/Backup"])
        #expect(c[0].title.contains("Backup"))
        #expect(c[0].severity == .warning)
        let ok = VolumeStat(name: "Backup", path: "/Volumes/Backup", availableBytes: 300 * gb, totalBytes: 1000 * gb, isInternal: false)
        #expect(only(.volumeFull, evaluate(snap(volumes: [ok]))).isEmpty)
        // Very little left is critical.
        let tiny = VolumeStat(name: "Daten", path: "/Volumes/Daten", availableBytes: 2 * gb, totalBytes: 500 * gb, isInternal: true)
        #expect(only(.volumeFull, evaluate(snap(volumes: [tiny]))).first?.severity == .critical)
        // Percent limit (10 %) with plenty of absolute space still counts (bytes limit is an OR).
        let bigLow = VolumeStat(name: "Archiv", path: "/Volumes/Archiv", availableBytes: 90 * gb, totalBytes: 1000 * gb, isInternal: false)
        #expect(only(.volumeFull, evaluate(snap(volumes: [bigLow]))).count == 1)
        // Hysteresis: 11 % free stays reported while active.
        let edge = VolumeStat(name: "Archiv", path: "/Volumes/Archiv", availableBytes: 110 * gb, totalBytes: 1000 * gb, isInternal: false)
        #expect(only(.volumeFull, evaluate(snap(volumes: [edge]))).isEmpty)
        #expect(only(.volumeFull, evaluate(snap(volumes: [edge]), active: ["volume./Volumes/Archiv"])).count == 1)
        // One key per volume, tiny helper volumes are ignored.
        let efi = VolumeStat(name: "EFI", path: "/Volumes/EFI", availableBytes: 1000, totalBytes: 200 * 1_048_576, isInternal: true)
        #expect(only(.volumeFull, evaluate(snap(volumes: [full, tiny, efi]))).map(\.key).sorted()
                == ["volume./Volumes/Backup", "volume./Volumes/Daten"])
        #expect(only(.volumeFull, evaluate(snap(volumes: []))).isEmpty)
        #expect(only(.volumeFull, evaluate(snap(volumes: [full]), settings: disabled(.volumeFull))).isEmpty)
    }

    @Test func volumeRuleLeavesBootVolumeToDiskRule() {
        let boot = VolumeStat(name: "Macintosh HD", path: "/", availableBytes: 20 * gb, totalBytes: 1000 * gb, isInternal: true)
        #expect(only(.volumeFull, evaluate(snap(volumes: [boot]))).isEmpty)
        #expect(only(.volumeFull, evaluate(snap(volumes: [boot]), settings: disabled(.disk))).count == 1)
    }

    @Test func gpuHigh() {
        var on = MonitorSettings()
        on.enabledRules.insert(.gpuHigh)
        let c = only(.gpuHigh, evaluate(snap(gpu: GPUStat(utilizationPercent: 95)), settings: on))
        #expect(c.count == 1)
        #expect(c[0].sustain == 300)
        #expect(only(.gpuHigh, evaluate(snap(gpu: GPUStat(utilizationPercent: 89)), settings: on)).isEmpty)
        // Hysteresis: 76,5 % while active.
        #expect(only(.gpuHigh, evaluate(snap(gpu: GPUStat(utilizationPercent: 80)), settings: on, active: ["system.gpu"])).count == 1)
        #expect(only(.gpuHigh, evaluate(snap(gpu: GPUStat(utilizationPercent: 80)), settings: on)).isEmpty)
        #expect(only(.gpuHigh, evaluate(snap(gpu: nil), settings: on)).isEmpty)
        // Off by default.
        #expect(!MonitorSettings().isEnabled(.gpuHigh))
        #expect(only(.gpuHigh, evaluate(snap(gpu: GPUStat(utilizationPercent: 99)))).isEmpty)
    }

    @Test func missingMetricsTriggerNothing() {
        var all = MonitorSettings()
        all.enabledRules = Set(RuleID.allCases)
        let conditions = evaluate(snap(batteryPercent: nil), settings: all)
        #expect(conditions.isEmpty)
    }

    @Test func conditionsKeepWorkingInTheEngineWithPerRuleReminder() {
        var engine = AlertEngine(reminderInterval: 600)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let short = Condition(key: "a", rule: .cpuHigh, severity: .warning, title: "a", body: "", sustain: 0)
        let long = Condition(key: "b", rule: .ssdWear, severity: .info, title: "b", body: "", sustain: 0,
                             reminderInterval: 86_400)
        _ = engine.process([short, long], now: t0)
        let events = engine.process([short, long], now: t0 + 700)
        #expect(events.map(\.condition.key) == ["a"])
        #expect(engine.process([short, long], now: t0 + 86_400).map(\.condition.key).sorted() == ["a", "b"])
    }
}

// MARK: - Settings

@Suite struct ExtendedSettingsTests {
    @Test func oldSettingsLoadAndNewRulesStartAtDefaults() throws {
        let old = """
        {"enabledRules":["cpuHigh","disk"],"processCPUThreshold":75,"cpuTotalThreshold":80,
         "ignoredProcesses":["foo"],"menuBarStyle":"iconAndCPU"}
        """
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(old.utf8))
        #expect(s.processCPUThreshold == 75)
        #expect(s.ignoredProcesses == ["foo"])
        #expect(s.menuBarStyle == .iconAndCPU)
        // No knownRules: the 1.0 rule set is taken as known, so the new rules are switched on ...
        for rule in [RuleID.cpuTemperature, .fanMaxed, .batteryHealth, .batteryDrainOnAC, .energyHog, .ssdWear, .volumeFull, .sleepBlocker] {
            #expect(s.isEnabled(rule))
        }
        // ... except GPU, which is off by default, and what the user switched off stays off.
        #expect(!s.isEnabled(.gpuHigh))
        #expect(!s.isEnabled(.swap))
        #expect(s.cpuTempThreshold == 95)
        #expect(s.fanMaxPercent == 90)
        #expect(s.batteryHealthMinPercent == 80)
        #expect(s.energyHogWatts == 8)
        #expect(s.ssdWearPercent == 80)
        #expect(s.ssdSpareMinPercent == 20)
        #expect(s.gpuHighThreshold == 90)
        #expect(s.longReminderInterval == 7 * 86_400)
        #expect(s.customRules.isEmpty)
        #expect(s.quiet == QuietSettings())
    }

    @Test func knownRulesKeepUserChoiceAfterRoundTrip() throws {
        var s = MonitorSettings()
        s.enabledRules.remove(.fanMaxed)
        s.enabledRules.insert(.gpuHigh)
        s.cpuTempThreshold = 90
        let back = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(!back.isEnabled(.fanMaxed))
        #expect(back.isEnabled(.gpuHigh))
    }

    @Test func defaultsEnableEverythingExceptGPU() {
        let s = MonitorSettings()
        #expect(s.enabledRules == Set(RuleID.allCases).subtracting([.gpuHigh]))
        #expect(!RuleID.allCases.contains(.custom))
    }

    @Test func customRuleIDDoesNotBreakStoredEvents() {
        #expect(RuleID(rawValue: "custom") == .custom)
        #expect(RuleID(rawValue: "somethingFromTheFuture") == nil)
    }

    @Test func settingsCarryCustomRules() throws {
        var s = MonitorSettings()
        s.customRules = [CustomRule.templates[0].instantiated()]
        let back = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(s))
        #expect(back.customRules == s.customRules)
    }
}

// MARK: - Custom rules

/// `bundle` is the bundle the executable itself lives in; by default the one the key names (helpers inside their app).
private func proc(_ pid: Int32, _ name: String, cpu: Double = 5, mem: UInt64 = gb, key: String = "", app: String = "",
                  bundle: String? = nil, path: String = "", start: UInt64 = 0) -> ProcessStat {
    ProcessStat(pid: pid, name: name, cpuPercent: cpu, footprintBytes: mem, appKey: key, appName: app,
                startTime: start, path: path, bundlePath: bundle ?? (key.hasPrefix("app:") ? String(key.dropFirst(4)) : ""))
}

private func rule(_ metric: CustomMetric, _ comparison: CustomComparison = .above, _ threshold: Double,
                  process: String? = nil, power: PowerCondition = .always, cooldown: TimeInterval = 600,
                  actions: [RuleAction] = [.showNotification]) -> CustomRule {
    CustomRule(name: "Test", metric: metric, processName: process, comparison: comparison, threshold: threshold,
               minDuration: 30, powerCondition: power, cooldown: cooldown, actions: actions)
}

@Suite struct CustomRuleTests {
    let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func conditions(_ r: CustomRule, _ s: SystemSnapshot, active: Bool = false) -> [Condition] {
        CustomRuleEvaluator.conditions(for: [r], in: s, isActive: { _ in active })
    }

    @Test func conditionShape() {
        let r = rule(.cpuTotal, .above, 80)
        let c = conditions(r, snap(cpu: 85))
        #expect(c.count == 1)
        #expect(c[0].key == "custom.\(r.id.uuidString)")
        #expect(c[0].rule == .custom)
        #expect(c[0].sustain == 30)
        #expect(c[0].title == "Test")
        #expect(c[0].body == "Die CPU-Auslastung liegt bei 85 % und damit über der Schwelle von 80 %.")
    }

    @Test func eachMetric() {
        let procs = [proc(200, "Google Chrome", cpu: 40, mem: 5 * gb, key: "app:/Applications/Google Chrome.app", app: "Google Chrome"),
                     proc(201, "Google Chrome Helper", cpu: 60, mem: 3 * gb, key: "app:/Applications/Google Chrome.app", app: "Google Chrome")]
        let s = snap(batteryPercent: 15, thermals: sensors(92),
                     fans: [FanStat(index: 0, rpm: 3000, minRpm: 1000, maxRpm: 6000)],
                     powerDraw: SystemPowerDraw(systemWatts: 42), gpu: GPUStat(utilizationPercent: 70),
                     cpu: 85, used: 12 * gb, swap: 6 * gb,
                     disk: DiskStat(availableBytes: 30 * gb, totalBytes: 500 * gb),
                     network: NetworkRate(downBytesPerSecond: 10 * 1_048_576, upBytesPerSecond: 2 * 1_048_576),
                     processes: procs)
        let cases: [(CustomMetric, CustomComparison, Double, String?, Bool)] = [
            (.cpuTotal, .above, 80, nil, true), (.cpuTotal, .above, 90, nil, false),
            (.memoryPercent, .above, 49, nil, true), (.memoryPercent, .above, 51, nil, false),
            (.swapGB, .above, 5, nil, true), (.swapGB, .below, 5, nil, false),
            (.gpuPercent, .above, 60, nil, true), (.gpuPercent, .above, 80, nil, false),
            (.cpuTemperature, .above, 90, nil, true), (.cpuTemperature, .above, 95, nil, false),
            (.fanPercent, .above, 49, nil, true), (.fanPercent, .above, 51, nil, false),
            (.systemWatts, .above, 40, nil, true), (.systemWatts, .above, 50, nil, false),
            (.batteryPercent, .below, 20, nil, true), (.batteryPercent, .below, 10, nil, false),
            (.freeDiskGB, .below, 40, nil, true), (.freeDiskGB, .below, 20, nil, false),
            (.networkDown, .above, 9, nil, true), (.networkDown, .above, 11, nil, false),
            (.networkUp, .above, 1.5, nil, true), (.networkUp, .above, 3, nil, false),
            (.processCPU, .above, 90, "Google Chrome", true), (.processCPU, .above, 110, "google chrome", false),
            (.processMemory, .above, 7, "Google Chrome", true), (.processMemory, .above, 9, "Google Chrome", false),
            (.processMemory, .above, 1, "Chrome Helper", false),
        ]
        for (metric, cmp, threshold, name, fires) in cases {
            let r = rule(metric, cmp, threshold, process: name)
            #expect(conditions(r, s).isEmpty == !fires, "\(metric) \(cmp) \(threshold)")
        }
        // Process rules point at the app's main process (lowest PID).
        let chrome = rule(.processMemory, .above, 7, process: "Google Chrome")
        #expect(conditions(chrome, s).first?.process == ProcessRef(pid: 200, name: "Google Chrome"))
    }

    @Test func missingValuesNeverFire() {
        let bare = snap(batteryPercent: nil, disk: nil)
        for (metric, cmp) in [(CustomMetric.gpuPercent, CustomComparison.below), (.cpuTemperature, .below),
                              (.fanPercent, .below), (.systemWatts, .below), (.batteryPercent, .below),
                              (.freeDiskGB, .below), (.networkDown, .below), (.networkUp, .below)] {
            #expect(conditions(rule(metric, cmp, 100), bare).isEmpty, "\(metric)")
        }
        #expect(conditions(rule(.processCPU, .below, 100, process: "Nirgends"), bare).isEmpty)
    }

    @Test func belowAndHysteresis() {
        let r = rule(.batteryPercent, .below, 20)
        #expect(conditions(r, snap(batteryPercent: 19)).count == 1)
        #expect(conditions(r, snap(batteryPercent: 20)).isEmpty)
        // While active, it clears only above threshold / 0,85 = 23,5 %.
        #expect(conditions(r, snap(batteryPercent: 23), active: true).count == 1)
        #expect(conditions(r, snap(batteryPercent: 24), active: true).isEmpty)
        let above = rule(.cpuTotal, .above, 80)
        #expect(conditions(above, snap(cpu: 70), active: true).count == 1)
        #expect(conditions(above, snap(cpu: 67), active: true).isEmpty)
        #expect(conditions(above, snap(cpu: 70)).isEmpty)
    }

    @Test func powerCondition() {
        let onlyBattery = rule(.cpuTotal, .above, 50, power: .onlyOnBattery)
        let onlyAC = rule(.cpuTotal, .above, 50, power: .onlyOnAC)
        let always = rule(.cpuTotal, .above, 50)
        let batterySnap = snap(onBattery: true, cpu: 90)
        let acSnap = snap(onBattery: false, cpu: 90)
        #expect(conditions(onlyBattery, batterySnap).count == 1)
        #expect(conditions(onlyBattery, acSnap).isEmpty)
        #expect(conditions(onlyAC, acSnap).count == 1)
        #expect(conditions(onlyAC, batterySnap).isEmpty)
        #expect(conditions(always, batterySnap).count == 1 && conditions(always, acSnap).count == 1)
    }

    @Test func disabledAndInvalidRulesProduceNothing() {
        var off = rule(.cpuTotal, .above, 50)
        off.isEnabled = false
        #expect(conditions(off, snap(cpu: 90)).isEmpty)
        var invalid = rule(.cpuTotal, .above, 50)
        invalid.name = " "
        #expect(conditions(invalid, snap(cpu: 90)).isEmpty)
    }

    @Test func runsThroughTheAlertEngine() {
        let r = rule(.cpuTotal, .above, 50)
        var engine = AlertEngine()
        let s = snap(cpu: 90)
        #expect(engine.process(conditions(r, s), now: t0).isEmpty)
        let events = engine.process(conditions(r, s), now: t0 + 30)
        #expect(events.map(\.kind) == [.fired])
        #expect(events[0].condition.rule == .custom)
    }

    private func fire(_ r: CustomRule, _ s: SystemSnapshot, now: Date, evaluator: inout CustomRuleEvaluator,
                      kind: AlertEvent.Kind = .fired) -> [PlannedAction] {
        let c = conditions(r, s)
        guard let condition = c.first else { return [] }
        return evaluator.plan(events: [AlertEvent(date: now, kind: kind, condition: condition)],
                              rules: [r], snapshot: s, now: now)
    }

    @Test func plansActionsOnlyForFired() {
        let r = rule(.cpuTotal, .above, 50, actions: [.showNotification, .runShortcut(name: "Ruhe"),
                                                       .openURL("https://example.com")])
        let s = snap(cpu: 90)
        var ev = CustomRuleEvaluator()
        for kind in [AlertEvent.Kind.reminder, .escalated, .resolved] {
            #expect(fire(r, s, now: t0, evaluator: &ev, kind: kind).isEmpty)
        }
        let planned = fire(r, s, now: t0, evaluator: &ev)
        #expect(planned.map(\.action) == r.actions)
        #expect(planned.allSatisfy { !$0.requiresConfirmation && $0.process == nil && $0.ruleID == r.id })
        #expect(planned[0].condition.title == "Test")
    }

    @Test func cooldown() {
        let r = rule(.cpuTotal, .above, 50, cooldown: 600)
        let s = snap(cpu: 90)
        var ev = CustomRuleEvaluator()
        #expect(fire(r, s, now: t0, evaluator: &ev).count == 1)
        #expect(fire(r, s, now: t0 + 599, evaluator: &ev).isEmpty)
        #expect(fire(r, s, now: t0 + 600, evaluator: &ev).count == 1)
        #expect(ev.lastRun[r.id] == t0 + 600)
        ev.prune(keeping: [])
        #expect(ev.lastRun.isEmpty)
    }

    private let chrome = [proc(300, "Google Chrome", cpu: 10, mem: 6 * gb, key: "app:/Applications/Google Chrome.app", app: "Google Chrome"),
                          proc(301, "Google Chrome Helper", cpu: 10, mem: 2 * gb, key: "app:/Applications/Google Chrome.app", app: "Google Chrome")]

    @Test func quitAskFirstAndPids() {
        var r = rule(.processMemory, .above, 4, process: "Google Chrome",
                     actions: [.showNotification, .quitProcess(askFirst: true), .throttleProcess])
        r.cooldown = 0
        var ev = CustomRuleEvaluator()
        let planned = fire(r, snap(processes: chrome), now: t0, evaluator: &ev)
        #expect(planned.map(\.action.kind) == [.showNotification, .quitProcess, .throttleProcess])
        #expect(planned[1].requiresConfirmation)
        #expect(!planned[2].requiresConfirmation)
        #expect(planned[1].process == ProcessRef(pid: 300, name: "Google Chrome"))
        #expect(planned[1].pids == [300, 301])

        r.actions = [.quitProcess(askFirst: false)]
        #expect(fire(r, snap(processes: chrome), now: t0 + 1, evaluator: &ev).first?.requiresConfirmation == false)
    }

    @Test func protectedProcessesAreNeverPlanned() {
        // Rule written before the process list changed: planning re-checks against the live snapshot.
        let victim = [proc(50, "Docker", cpu: 500, mem: 10 * gb), // pid below 100
                      proc(400, "Finder", cpu: 500, mem: 10 * gb, key: "app:/System/Library/CoreServices/Finder.app", app: "Finder")]
        var ev = CustomRuleEvaluator()
        for name in ["Docker", "Finder"] {
            var r = rule(.processCPU, .above, 100, process: name, cooldown: 0,
                         actions: [.quitProcess(askFirst: false), .throttleProcess])
            r.name = "Test"
            // Hand-build the condition: validation already refuses protected names for Finder, and for
            // Docker the PID rule applies at plan time.
            let condition = Condition(key: r.conditionKey, rule: .custom, severity: .warning, title: "t", body: "", sustain: 0)
            var tolerant = r
            tolerant.processName = name
            let planned = ev.plan(events: [AlertEvent(date: t0, kind: .fired, condition: condition)],
                                  rules: [tolerant], snapshot: snap(processes: victim), now: t0)
            #expect(planned.isEmpty, "\(name)")
        }
    }

    // MARK: Processes started by a terminal or editor

    private let terminalKey = "app:/System/Applications/Utilities/Terminal.app"
    /// A `node` that Terminal started: the system holds Terminal accountable, so it carries Terminal's key and name.
    private var nodeUnderTerminal: [ProcessStat] {
        [proc(500, "Terminal", cpu: 2, key: terminalKey, app: "Terminal", bundle: "/System/Applications/Utilities/Terminal.app",
              path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", start: 10),
         proc(510, "zsh", cpu: 0, key: terminalKey, app: "Terminal", bundle: "", path: "/bin/zsh", start: 11),
         proc(511, "vim", cpu: 0, key: terminalKey, app: "Terminal", bundle: "", path: "/usr/bin/vim", start: 12),
         proc(512, "ssh", cpu: 0, key: terminalKey, app: "Terminal", bundle: "", path: "/usr/bin/ssh", start: 13),
         proc(520, "node", cpu: 300, mem: 2 * gb, key: terminalKey, app: "Terminal", bundle: "", path: "/opt/homebrew/bin/node", start: 14),
         proc(521, "node", cpu: 100, mem: 1 * gb, key: terminalKey, app: "Terminal", bundle: "", path: "/opt/homebrew/bin/node", start: 15)]
    }

    @Test func nodeUnderTerminalIsPlannedAlone() {
        var r = rule(.processCPU, .above, 100, process: "node", cooldown: 0,
                     actions: [.quitProcess(askFirst: false), .throttleProcess])
        r.cooldown = 0
        var ev = CustomRuleEvaluator()
        let planned = fire(r, snap(processes: nodeUnderTerminal), now: t0, evaluator: &ev)
        #expect(planned.map(\.action.kind) == [.quitProcess, .throttleProcess])
        for item in planned {
            // Only the two node processes, never Terminal, the shell, vim or ssh.
            #expect(item.pids == [520, 521])
            #expect(item.process == ProcessRef(pid: 520, name: "node", startTime: 14))
        }
    }

    @Test func ruleOnTerminalLeavesItsChildrenAlone() {
        let r = rule(.processCPU, .above, 1, process: "Terminal", cooldown: 0, actions: [.quitProcess(askFirst: false)])
        let found = CustomRuleEvaluator.processes(named: "terminal", in: snap(processes: nodeUnderTerminal))
        #expect(found.map(\.pid) == [500])
        var ev = CustomRuleEvaluator()
        // Terminal itself is a system app (/System/Applications), so the plan stays empty.
        #expect(fire(r, snap(processes: nodeUnderTerminal), now: t0, evaluator: &ev).isEmpty)
    }

    @Test func hostAppsAreNeverExpandedToTheirBundle() {
        let code = "/Applications/Visual Studio Code.app"
        let procs = [proc(600, "Electron", key: "app:" + code, app: "Visual Studio Code", bundle: code),
                     proc(601, "Code Helper (Plugin)", key: "app:" + code, app: "Visual Studio Code", bundle: code),
                     proc(602, "node", key: "app:" + code, app: "Visual Studio Code", bundle: "", path: "/opt/homebrew/bin/node")]
        // The bundle name matches no process by itself: nothing is ended as a group.
        #expect(CustomRuleEvaluator.processes(named: "Visual Studio Code", in: snap(processes: procs)).isEmpty)
        #expect(CustomRuleEvaluator.processes(named: "Code Helper (Plugin)", in: snap(processes: procs)).map(\.pid) == [601])
        #expect(CustomRuleEvaluator.processes(named: "node", in: snap(processes: procs)).map(\.pid) == [602])
        // An ordinary app is still taken as a whole, helpers included.
        let chrome = [proc(700, "Google Chrome", key: "app:/Applications/Google Chrome.app", app: "Google Chrome"),
                      proc(701, "Google Chrome Helper", key: "app:/Applications/Google Chrome.app", app: "Google Chrome")]
        #expect(CustomRuleEvaluator.processes(named: "Google Chrome", in: snap(processes: chrome)).map(\.pid) == [700, 701])
    }

    @Test func protectionByPathInsteadOfNameEnding() {
        // User-installed daemons are ordinary tools; system folders are protected whatever the name.
        #expect(!ProtectedProcesses.isProtected(proc(5000, "mongod", path: "/opt/homebrew/opt/mongodb-community/bin/mongod")))
        #expect(!ProtectedProcesses.isProtected(proc(5000, "node", key: terminalKey, app: "Terminal", bundle: "", path: "/opt/homebrew/bin/node")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "mediaanalysisd", path: "/System/Library/PrivateFrameworks/X/mediaanalysisd")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "someagent", path: "/usr/libexec/someagent")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "Calculator", key: "app:/System/Applications/Calculator.app", app: "Calculator",
                                                    path: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")))
        // Without any path the name ending still counts, as the conservative fallback.
        #expect(ProtectedProcesses.isProtected(proc(5000, "mediaanalysisd")))
        #expect(!ProtectedProcesses.isProtected(proc(5000, "ffmpeg")))
    }

    @Test func protectedList() {
        for name in ["kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "MacMonitor", "  launchd "] {
            #expect(ProtectedProcesses.isProtected(name: name), "\(name)")
        }
        #expect(!ProtectedProcesses.isProtected(name: "Google Chrome"))
        let own = ProcessInfo.processInfo.processIdentifier
        #expect(ProtectedProcesses.isProtected(proc(own, "Whatever")))
        #expect(ProtectedProcesses.isProtected(proc(1, "launchd")))
        #expect(ProtectedProcesses.isProtected(proc(99, "Something")))
        #expect(!ProtectedProcesses.isProtected(proc(100, "node")))
        #expect(!ProtectedProcesses.isProtected(proc(5000, "ffmpeg")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "mediaanalysisd")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "com.apple.Foo")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "Dock", key: "app:/System/Library/CoreServices/Dock.app", app: "Dock")))
        #expect(ProtectedProcesses.isProtected(proc(5000, "Helper", key: "app:/System/Library/Foo.app", app: "Foo")))
        // Safari lives in a cryptex outside /System/Library and may be ended.
        #expect(!ProtectedProcesses.isProtected(proc(5000, "Safari", key: "app:/System/Cryptexes/App/System/Applications/Safari.app", app: "Safari")))
        #expect(!ProtectedProcesses.isProtected(proc(5000, "Google Chrome", key: "app:/Applications/Google Chrome.app", app: "Google Chrome")))
    }

    @Test func validation() {
        #expect(rule(.cpuTotal, .above, 50).validate().isEmpty)

        var r = rule(.cpuTotal, .above, 50)
        r.name = "  "
        #expect(r.validate() == [.emptyName])
        r.name = String(repeating: "x", count: 81)
        #expect(r.validate() == [.nameTooLong(maxLength: 80)])

        #expect(rule(.cpuTotal, .above, .nan).validate() == [.thresholdNotFinite])
        #expect(rule(.cpuTotal, .above, -1).validate() == [.thresholdNegative])
        #expect(rule(.cpuTotal, .above, 101).validate() == [.thresholdAbove100])
        #expect(rule(.processCPU, .above, 400, process: "Xcode").validate().isEmpty)
        #expect(rule(.swapGB, .above, 500).validate().isEmpty)

        var d = rule(.cpuTotal, .above, 50)
        d.minDuration = -1
        d.cooldown = -1
        #expect(d.validate() == [.negativeDuration, .negativeCooldown])

        #expect(rule(.processCPU, .above, 100).validate() == [.missingProcessName])
        #expect(rule(.processMemory, .above, 1, process: "  ").validate() == [.missingProcessName])

        #expect(rule(.cpuTotal, .above, 50, actions: []).validate() == [.noActions])
        #expect(rule(.cpuTotal, .above, 50, actions: [.quitProcess(askFirst: true)]).validate()
                == [.actionNeedsProcessMetric(.quitProcess)])
        #expect(rule(.cpuTotal, .above, 50, actions: [.throttleProcess, .throttleProcess]).validate()
                == [.actionNeedsProcessMetric(.throttleProcess)])
        #expect(rule(.processCPU, .above, 100, process: "Xcode", actions: [.throttleProcess, .quitProcess(askFirst: true)]).validate().isEmpty)

        #expect(rule(.processCPU, .above, 100, process: "Finder", actions: [.quitProcess(askFirst: true)]).validate()
                == [.protectedProcess("Finder")])
        #expect(rule(.processCPU, .above, 100, process: "MacMonitor", actions: [.throttleProcess]).validate()
                == [.protectedProcess("MacMonitor")])
        // Protected names are fine when the rule only notifies.
        #expect(rule(.processCPU, .above, 100, process: "kernel_task", actions: [.showNotification]).validate().isEmpty)

        #expect(rule(.cpuTotal, .above, 50, actions: [.runShortcut(name: " ")]).validate() == [.emptyShortcutName])
        #expect(rule(.cpuTotal, .above, 50, actions: [.openURL("ftp://example.com")]).validate() == [.invalidURL("ftp://example.com")])
        #expect(rule(.cpuTotal, .above, 50, actions: [.openURL("kein url")]).validate() == [.invalidURL("kein url")])
        #expect(rule(.cpuTotal, .above, 50, actions: [.openURL("https://example.com/x")]).validate().isEmpty)
    }

    @Test func templatesAreValidAndDistinct() {
        #expect(CustomRule.templates.count >= 4)
        for template in CustomRule.templates {
            #expect(template.validate().isEmpty, "\(template.name)")
        }
        #expect(Set(CustomRule.templates.map(\.id)).count == CustomRule.templates.count)
        let copy = CustomRule.templates[0].instantiated()
        #expect(copy.id != CustomRule.templates[0].id)
        #expect(copy.name == CustomRule.templates[0].name)
    }

    @Test func codableRoundTripAndTolerantDecoding() throws {
        let all = CustomRule.templates + [
            rule(.processMemory, .above, 2, process: "X", actions: [.quitProcess(askFirst: false), .openURL("https://a.b"), .runShortcut(name: "K")]),
        ]
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode([CustomRule].self, from: data) == all)

        let id = UUID()
        let minimal = #"{"id":"\#(id.uuidString)","name":"Min","metric":"cpuTotal","threshold":70}"#
        let r = try JSONDecoder().decode(CustomRule.self, from: Data(minimal.utf8))
        #expect(r.id == id && r.isEnabled && r.comparison == .above && r.cooldown == 1800)
        #expect(r.actions == [.showNotification])
        #expect(r.severity == .warning)
    }
}

// MARK: - Quiet policy

@Suite struct QuietPolicyTests {
    private func ctx(focus: Bool = false, locked: Bool = false, presenting: Bool = false, minute: Int = 12 * 60) -> QuietContext {
        QuietContext(focusActive: focus, screenLocked: locked, presenting: presenting, minuteOfDay: minute)
    }

    private func decide(_ severity: Severity, _ kind: AlertEvent.Kind = .fired, _ settings: QuietSettings = QuietSettings(),
                        _ c: QuietContext) -> QuietDecision {
        QuietPolicy.decide(severity: severity, kind: kind, settings: settings, context: c)
    }

    private let loud = QuietDecision(banner: true, overlay: true, sound: true)
    private let noSound = QuietDecision(banner: true, overlay: true, sound: false)
    private let banner = QuietDecision(banner: true, overlay: false, sound: false)

    @Test func normalTimes() {
        #expect(decide(.critical, .fired, QuietSettings(), ctx()) == loud)
        #expect(decide(.warning, .fired, QuietSettings(), ctx()) == loud)
        #expect(decide(.warning, .escalated, QuietSettings(), ctx()) == loud)
        #expect(decide(.info, .fired, QuietSettings(), ctx()) == noSound)
        #expect(decide(.warning, .reminder, QuietSettings(), ctx()) == noSound)
        #expect(decide(.critical, .resolved, QuietSettings(), ctx()) == noSound)
        #expect(decide(.warning, .resolved, QuietSettings(), ctx()) == noSound)
    }

    @Test func soundSwitchOff() {
        var s = QuietSettings()
        s.soundEnabled = false
        #expect(decide(.critical, .fired, s, ctx()) == noSound)
    }

    @Test func focusPresentationAndLock() {
        for c in [ctx(focus: true), ctx(presenting: true)] {
            #expect(decide(.info, .fired, QuietSettings(), c) == .silent)
            #expect(decide(.warning, .fired, QuietSettings(), c) == banner)
            #expect(decide(.warning, .resolved, QuietSettings(), c) == banner)
            #expect(decide(.critical, .fired, QuietSettings(), c) == loud)
            #expect(decide(.critical, .resolved, QuietSettings(), c) == noSound)
        }
        // Locked: critical still delivered, but no panel on a dark screen.
        let locked = ctx(locked: true)
        #expect(decide(.info, .fired, QuietSettings(), locked) == .silent)
        #expect(decide(.warning, .fired, QuietSettings(), locked) == banner)
        #expect(decide(.critical, .fired, QuietSettings(), locked) == QuietDecision(banner: true, overlay: false, sound: true))
    }

    @Test func respectSwitches() {
        var s = QuietSettings()
        s.respectFocus = false
        s.respectPresentation = false
        s.respectScreenLock = false
        #expect(decide(.info, .fired, s, ctx(focus: true, presenting: true)) == noSound)
        #expect(decide(.warning, .fired, s, ctx(focus: true, presenting: true)) == loud)
        // The lock only hides the panel regardless of settings.
        #expect(decide(.warning, .fired, s, ctx(locked: true)) == QuietDecision(banner: true, overlay: false, sound: true))
    }

    @Test func criticalWithoutBreakThrough() {
        var s = QuietSettings()
        s.criticalBreaksThrough = false
        #expect(decide(.critical, .fired, s, ctx(focus: true)) == banner)
        #expect(decide(.critical, .fired, s, ctx()) == loud)
    }

    @Test func quietHoursSameDay() {
        var s = QuietSettings()
        s.quietHoursEnabled = true
        s.quietHoursStart = 13 * 60
        s.quietHoursEnd = 14 * 60
        let cases: [(Int, Bool)] = [(12 * 60 + 59, false), (13 * 60, true), (13 * 60 + 59, true), (14 * 60, false)]
        for (minute, inside) in cases {
            #expect(QuietPolicy.isInQuietHours(settings: s, minuteOfDay: minute) == inside, "\(minute)")
        }
    }

    @Test func quietHoursAcrossMidnight() {
        var s = QuietSettings()
        s.quietHoursEnabled = true // 22:00 to 07:00
        let cases: [(Int, Bool)] = [
            (21 * 60 + 59, false), (22 * 60, true), (23 * 60 + 59, true), (0, true), (3 * 60, true),
            (6 * 60 + 59, true), (7 * 60, false), (12 * 60, false),
        ]
        for (minute, inside) in cases {
            #expect(QuietPolicy.isInQuietHours(settings: s, minuteOfDay: minute) == inside, "\(minute)")
        }
        let night = ctx(minute: 23 * 60 + 30)
        #expect(decide(.info, .fired, s, night) == .silent)
        #expect(decide(.warning, .fired, s, night) == banner)
        #expect(decide(.critical, .fired, s, night) == loud)
        #expect(decide(.critical, .resolved, s, night) == noSound)
        let morning = ctx(minute: 8 * 60)
        #expect(decide(.info, .fired, s, morning) == noSound)
    }

    @Test func quietHoursOffOrEmpty() {
        var s = QuietSettings()
        #expect(!QuietPolicy.isInQuietHours(settings: s, minuteOfDay: 23 * 60))
        s.quietHoursEnabled = true
        s.quietHoursStart = 8 * 60
        s.quietHoursEnd = 8 * 60
        #expect(!QuietPolicy.isInQuietHours(settings: s, minuteOfDay: 8 * 60))
    }

    @Test func contextFromDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23, minute: 15))!
        #expect(QuietContext(date: date, calendar: calendar).minuteOfDay == 23 * 60 + 15)
    }

    @Test func settingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(QuietSettings.self, from: Data(#"{"quietHoursEnabled":true}"#.utf8))
        #expect(s.quietHoursEnabled && s.respectFocus && s.criticalBreaksThrough && s.quietHoursStart == 22 * 60)
    }
}
