import Foundation

public enum RuleID: String, CaseIterable, Codable, Sendable {
    case runawayProcess, memoryHog, cpuHigh, memoryPressure, swap, thermal, disk, network, sleepBlocker

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
        }
    }
}

extension RuleID {
    /// Rules that existed before `knownRules` was stored (version 1.0).
    static let legacy: [RuleID] = [.runawayProcess, .memoryHog, .cpuHigh, .memoryPressure, .swap, .thermal, .disk, .network]
}

public enum MenuBarStyle: String, CaseIterable, Codable, Sendable {
    case icon, iconAndCPU, iconCPUAndMemory

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
    public var enabledRules: Set<RuleID> = Set(RuleID.allCases)
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
    public var overlayMode: OverlayMode = .otherScreens
    public var ignoredProcesses: [String] = ["kernel_task", "mds_stores", "mdworker_shared", "photoanalysisd"]
    /// Icon only by default: every text change makes macOS redraw the status item on each
    /// display (~40 ms), which would dominate the app's energy use.
    public var menuBarStyle: MenuBarStyle = .icon

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabledRules, knownRules, processCPUThreshold, processCPUSustain, memoryHogFraction, memoryHogSustain
        case cpuTotalThreshold, cpuTotalSustain, memoryPressureSustain, swapThresholdGB, diskMinFreePercent
        case diskMinFreeGB, networkOfflineSustain, sleepBlockerSustain, reminderInterval, overlayMode
        case ignoredProcesses, menuBarStyle
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
    }

    public func isEnabled(_ rule: RuleID) -> Bool { enabledRules.contains(rule) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        enabledRules = (try? c.decodeIfPresent(Set<RuleID>.self, forKey: .enabledRules)) ?? d.enabledRules
        // Rules added after the settings were saved start out enabled.
        let known = (try? c.decodeIfPresent([String].self, forKey: .knownRules)) ?? RuleID.legacy.map(\.rawValue)
        enabledRules.formUnion(RuleID.allCases.filter { !known.contains($0.rawValue) })
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
        menuBarStyle = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
    }
}
