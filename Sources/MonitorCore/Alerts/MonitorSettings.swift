import Foundation

public enum RuleID: String, CaseIterable, Codable, Sendable {
    case runawayProcess, memoryHog, cpuHigh, memoryPressure, swap, thermal, disk, network, sleepBlocker
    case cpuTemperature, fanMaxed, batteryHealth, batteryDrainOnAC, energyHog, ssdWear, volumeFull, gpuHigh
    /// Marks conditions produced by user-defined rules (`CustomRule`). Not a built-in rule: it has no
    /// toggle in `enabledRules`; every custom rule has its own `isEnabled`.
    case custom

    /// The built-in rules, i.e. everything that can be switched on and off in `enabledRules`.
    public static var allCases: [RuleID] {
        [.runawayProcess, .memoryHog, .cpuHigh, .memoryPressure, .swap, .thermal, .disk, .network, .sleepBlocker,
         .cpuTemperature, .fanMaxed, .batteryHealth, .batteryDrainOnAC, .energyHog, .ssdWear, .volumeFull, .gpuHigh]
    }

    /// Rules that start out switched off, both for fresh installs and for rules added after an update.
    static let disabledByDefault: Set<RuleID> = [.gpuHigh]

    public var title: String {
        switch self {
        case .runawayProcess: "Hängender Prozess"
        case .memoryHog: "Speicherfresser"
        case .cpuHigh: "CPU dauerhaft hoch"
        case .memoryPressure: "Speicherdruck"
        case .swap: "Swap-Nutzung"
        case .thermal: "Überhitzung"
        case .disk: "Festplatte voll"
        case .network: "Internet weg"
        case .sleepBlocker: "Ruhezustand blockiert"
        case .cpuTemperature: "CPU-Temperatur hoch"
        case .fanMaxed: "Lüfter am Anschlag"
        case .batteryHealth: "Akku-Gesundheit"
        case .batteryDrainOnAC: "Akku entlädt trotz Netzteil"
        case .energyHog: "Energiefresser im Akkubetrieb"
        case .ssdWear: "SSD-Verschleiß"
        case .volumeFull: "Volume voll"
        case .gpuHigh: "GPU dauerhaft hoch"
        case .custom: "Eigene Regel"
        }
    }
}

extension RuleID {
    /// Rules that existed before `knownRules` was stored (version 1.0).
    static let legacy: [RuleID] = [.runawayProcess, .memoryHog, .cpuHigh, .memoryPressure, .swap, .thermal, .disk, .network]
}

public enum MenuBarStyle: String, CaseIterable, Codable, Sendable {
    case icon, iconAndCPU, iconCPUAndMemory

    /// The items this style stands for.
    public var items: [MenuBarItem] {
        switch self {
        case .icon: []
        case .iconAndCPU: [.cpu]
        case .iconCPUAndMemory: [.cpu, .memory]
        }
    }

    /// The nearest old style for a free choice.
    public init(items: [MenuBarItem]) {
        if items.isEmpty { self = .icon }
        else if items.starts(with: [.cpu, .memory]) { self = .iconCPUAndMemory }
        else { self = .iconAndCPU }
    }

    public var title: String {
        switch self {
        case .icon: "Nur Symbol"
        case .iconAndCPU: "Symbol + CPU"
        case .iconCPUAndMemory: "Symbol + CPU + RAM"
        }
    }
}

/// Whether to also show MacMonitor's own alert panel on the screen with the mouse pointer.
/// macOS only shows notification banners on the main display.
public enum OverlayMode: String, CaseIterable, Codable, Sendable {
    case off, otherScreens, always

    public var title: String {
        switch self {
        case .off: "Aus"
        case .otherScreens: "Wenn ich an einem anderen Bildschirm bin"
        case .always: "Immer"
        }
    }

    /// `pointerOnMainScreen`: the pointer is on the display macOS shows banners on.
    public func shouldShow(pointerOnMainScreen: Bool) -> Bool {
        switch self {
        case .off: false
        case .otherScreens: !pointerOnMainScreen
        case .always: true
        }
    }
}

/// All user-tunable thresholds. Decoding tolerates missing keys so new settings can be added
/// without wiping what the user already configured.
public struct MonitorSettings: Codable, Equatable, Sendable {
    public var enabledRules: Set<RuleID> = Set(RuleID.allCases).subtracting(RuleID.disabledByDefault)
    public var processCPUThreshold: Double = 90
    public var processCPUSustain: TimeInterval = 180
    public var memoryHogFraction: Double = 0.25
    public var memoryHogSustain: TimeInterval = 60
    public var cpuTotalThreshold: Double = 90
    public var cpuTotalSustain: TimeInterval = 120
    public var memoryPressureSustain: TimeInterval = 60
    public var swapThresholdGB: Double = 8
    public var diskMinFreePercent: Double = 10
    public var diskMinFreeGB: Double = 15
    public var networkOfflineSustain: TimeInterval = 30
    public var sleepBlockerSustain: TimeInterval = 1800
    public var reminderInterval: TimeInterval = 1800
    /// Reminder interval for rules about slow-changing facts (battery health, SSD wear): 7 days.
    public var longReminderInterval: TimeInterval = 7 * 86_400
    /// CPU die temperature limit in °C (hottest sensor).
    public var cpuTempThreshold: Double = 95
    public var cpuTempSustain: TimeInterval = 120
    /// A fan counts as maxed out at this share of its range, in percent.
    public var fanMaxPercent: Double = 90
    public var fanMaxSustain: TimeInterval = 300
    /// Battery health is reported below this share of the design capacity, in percent.
    public var batteryHealthMinPercent: Double = 80
    public var batteryDrainSustain: TimeInterval = 600
    /// Average power of one app on battery, in watts.
    public var energyHogWatts: Double = 8
    public var energyHogSustain: TimeInterval = 300
    /// SSD wear estimate at or above this value, in percent.
    public var ssdWearPercent: Double = 80
    /// Available spare below this value, in percent.
    public var ssdSpareMinPercent: Double = 20
    public var gpuHighThreshold: Double = 90
    public var gpuHighSustain: TimeInterval = 300
    public var customRules: [CustomRule] = []
    public var quiet: QuietSettings = QuietSettings()
    public var overlayMode: OverlayMode = .otherScreens
    public var ignoredProcesses: [String] = ["kernel_task", "mds_stores", "mdworker_shared", "photoanalysisd"]
    /// Values shown next to the menu bar icon, at most `MenuBarDisplay.maxItems`; empty means icon only.
    /// Icon only by default: every text change makes macOS redraw the status item on each
    /// display (~40 ms), which would dominate the app's energy use.
    public var menuBarItems: [MenuBarItem] = []
    /// The three fixed styles of version 1.x, mapped to and from `menuBarItems`. Still written so an
    /// older version reads something sensible.
    public var menuBarStyle: MenuBarStyle {
        get { MenuBarStyle(items: menuBarItems) }
        set { menuBarItems = newValue.items }
    }
    public var hotKeys: HotKeySettings = HotKeySettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabledRules, knownRules, processCPUThreshold, processCPUSustain, memoryHogFraction, memoryHogSustain
        case cpuTotalThreshold, cpuTotalSustain, memoryPressureSustain, swapThresholdGB, diskMinFreePercent
        case diskMinFreeGB, networkOfflineSustain, sleepBlockerSustain, reminderInterval, overlayMode
        case ignoredProcesses, menuBarStyle, menuBarItems, hotKeys
        case longReminderInterval, cpuTempThreshold, cpuTempSustain, fanMaxPercent, fanMaxSustain
        case batteryHealthMinPercent, batteryDrainSustain, energyHogWatts, energyHogSustain
        case ssdWearPercent, ssdSpareMinPercent, gpuHighThreshold, gpuHighSustain, customRules, quiet
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabledRules, forKey: .enabledRules)
        try c.encode(RuleID.allCases.map(\.rawValue), forKey: .knownRules)
        try c.encode(processCPUThreshold, forKey: .processCPUThreshold)
        try c.encode(processCPUSustain, forKey: .processCPUSustain)
        try c.encode(memoryHogFraction, forKey: .memoryHogFraction)
        try c.encode(memoryHogSustain, forKey: .memoryHogSustain)
        try c.encode(cpuTotalThreshold, forKey: .cpuTotalThreshold)
        try c.encode(cpuTotalSustain, forKey: .cpuTotalSustain)
        try c.encode(memoryPressureSustain, forKey: .memoryPressureSustain)
        try c.encode(swapThresholdGB, forKey: .swapThresholdGB)
        try c.encode(diskMinFreePercent, forKey: .diskMinFreePercent)
        try c.encode(diskMinFreeGB, forKey: .diskMinFreeGB)
        try c.encode(networkOfflineSustain, forKey: .networkOfflineSustain)
        try c.encode(sleepBlockerSustain, forKey: .sleepBlockerSustain)
        try c.encode(reminderInterval, forKey: .reminderInterval)
        try c.encode(overlayMode, forKey: .overlayMode)
        try c.encode(ignoredProcesses, forKey: .ignoredProcesses)
        try c.encode(menuBarStyle, forKey: .menuBarStyle)
        try c.encode(menuBarItems, forKey: .menuBarItems)
        try c.encode(hotKeys, forKey: .hotKeys)
        try c.encode(longReminderInterval, forKey: .longReminderInterval)
        try c.encode(cpuTempThreshold, forKey: .cpuTempThreshold)
        try c.encode(cpuTempSustain, forKey: .cpuTempSustain)
        try c.encode(fanMaxPercent, forKey: .fanMaxPercent)
        try c.encode(fanMaxSustain, forKey: .fanMaxSustain)
        try c.encode(batteryHealthMinPercent, forKey: .batteryHealthMinPercent)
        try c.encode(batteryDrainSustain, forKey: .batteryDrainSustain)
        try c.encode(energyHogWatts, forKey: .energyHogWatts)
        try c.encode(energyHogSustain, forKey: .energyHogSustain)
        try c.encode(ssdWearPercent, forKey: .ssdWearPercent)
        try c.encode(ssdSpareMinPercent, forKey: .ssdSpareMinPercent)
        try c.encode(gpuHighThreshold, forKey: .gpuHighThreshold)
        try c.encode(gpuHighSustain, forKey: .gpuHighSustain)
        try c.encode(customRules, forKey: .customRules)
        try c.encode(quiet, forKey: .quiet)
    }

    public func isEnabled(_ rule: RuleID) -> Bool { enabledRules.contains(rule) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        enabledRules = (try? c.decodeIfPresent(Set<RuleID>.self, forKey: .enabledRules)) ?? d.enabledRules
        // Rules added after the settings were saved start out enabled.
        let known = (try? c.decodeIfPresent([String].self, forKey: .knownRules)) ?? RuleID.legacy.map(\.rawValue)
        enabledRules.formUnion(RuleID.allCases.filter { !known.contains($0.rawValue) && !RuleID.disabledByDefault.contains($0) })
        processCPUThreshold = (try? c.decodeIfPresent(Double.self, forKey: .processCPUThreshold)) ?? d.processCPUThreshold
        processCPUSustain = (try? c.decodeIfPresent(Double.self, forKey: .processCPUSustain)) ?? d.processCPUSustain
        memoryHogFraction = (try? c.decodeIfPresent(Double.self, forKey: .memoryHogFraction)) ?? d.memoryHogFraction
        memoryHogSustain = (try? c.decodeIfPresent(Double.self, forKey: .memoryHogSustain)) ?? d.memoryHogSustain
        cpuTotalThreshold = (try? c.decodeIfPresent(Double.self, forKey: .cpuTotalThreshold)) ?? d.cpuTotalThreshold
        cpuTotalSustain = (try? c.decodeIfPresent(Double.self, forKey: .cpuTotalSustain)) ?? d.cpuTotalSustain
        memoryPressureSustain = (try? c.decodeIfPresent(Double.self, forKey: .memoryPressureSustain)) ?? d.memoryPressureSustain
        swapThresholdGB = (try? c.decodeIfPresent(Double.self, forKey: .swapThresholdGB)) ?? d.swapThresholdGB
        diskMinFreePercent = (try? c.decodeIfPresent(Double.self, forKey: .diskMinFreePercent)) ?? d.diskMinFreePercent
        diskMinFreeGB = (try? c.decodeIfPresent(Double.self, forKey: .diskMinFreeGB)) ?? d.diskMinFreeGB
        networkOfflineSustain = (try? c.decodeIfPresent(Double.self, forKey: .networkOfflineSustain)) ?? d.networkOfflineSustain
        sleepBlockerSustain = (try? c.decodeIfPresent(Double.self, forKey: .sleepBlockerSustain)) ?? d.sleepBlockerSustain
        reminderInterval = (try? c.decodeIfPresent(Double.self, forKey: .reminderInterval)) ?? d.reminderInterval
        overlayMode = (try? c.decodeIfPresent(OverlayMode.self, forKey: .overlayMode)) ?? d.overlayMode
        ignoredProcesses = (try? c.decodeIfPresent([String].self, forKey: .ignoredProcesses)) ?? d.ignoredProcesses
        if let names = try? c.decodeIfPresent([String].self, forKey: .menuBarItems) {
            menuBarItems = MenuBarItem.normalized(names.compactMap(MenuBarItem.init(rawValue:)))
        } else {
            // Settings from before the free choice: derive the items from the old style.
            menuBarItems = ((try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? .icon).items
        }
        hotKeys = (try? c.decodeIfPresent(HotKeySettings.self, forKey: .hotKeys)) ?? d.hotKeys
        longReminderInterval = (try? c.decodeIfPresent(Double.self, forKey: .longReminderInterval)) ?? d.longReminderInterval
        cpuTempThreshold = (try? c.decodeIfPresent(Double.self, forKey: .cpuTempThreshold)) ?? d.cpuTempThreshold
        cpuTempSustain = (try? c.decodeIfPresent(Double.self, forKey: .cpuTempSustain)) ?? d.cpuTempSustain
        fanMaxPercent = (try? c.decodeIfPresent(Double.self, forKey: .fanMaxPercent)) ?? d.fanMaxPercent
        fanMaxSustain = (try? c.decodeIfPresent(Double.self, forKey: .fanMaxSustain)) ?? d.fanMaxSustain
        batteryHealthMinPercent = (try? c.decodeIfPresent(Double.self, forKey: .batteryHealthMinPercent)) ?? d.batteryHealthMinPercent
        batteryDrainSustain = (try? c.decodeIfPresent(Double.self, forKey: .batteryDrainSustain)) ?? d.batteryDrainSustain
        energyHogWatts = (try? c.decodeIfPresent(Double.self, forKey: .energyHogWatts)) ?? d.energyHogWatts
        energyHogSustain = (try? c.decodeIfPresent(Double.self, forKey: .energyHogSustain)) ?? d.energyHogSustain
        ssdWearPercent = (try? c.decodeIfPresent(Double.self, forKey: .ssdWearPercent)) ?? d.ssdWearPercent
        ssdSpareMinPercent = (try? c.decodeIfPresent(Double.self, forKey: .ssdSpareMinPercent)) ?? d.ssdSpareMinPercent
        gpuHighThreshold = (try? c.decodeIfPresent(Double.self, forKey: .gpuHighThreshold)) ?? d.gpuHighThreshold
        gpuHighSustain = (try? c.decodeIfPresent(Double.self, forKey: .gpuHighSustain)) ?? d.gpuHighSustain
        // One unreadable rule must not take the others with it.
        customRules = ((try? c.decodeIfPresent([LossyRule].self, forKey: .customRules)) ?? []).compactMap(\.rule)
        quiet = (try? c.decodeIfPresent(QuietSettings.self, forKey: .quiet)) ?? d.quiet
    }
}

/// Decodes a custom rule or, if it is broken or unknown, nothing.
private struct LossyRule: Decodable {
    let rule: CustomRule?
    init(from decoder: Decoder) throws { rule = try? CustomRule(from: decoder) }
}
