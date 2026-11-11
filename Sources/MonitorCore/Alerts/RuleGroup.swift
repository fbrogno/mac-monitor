import Foundation

/// The groups the built-in rules are shown in.
public enum RuleGroup: String, CaseIterable, Sendable, Identifiable {
    case processes, system, energy, storage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .processes: L("Prozesse")
        case .system: L("System")
        case .energy: L("Energie & Akku")
        case .storage: L("Speicherplatz")
        }
    }

    public var rules: [RuleID] {
        switch self {
        case .processes: [.runawayProcess, .memoryHog]
        case .system: [.cpuHigh, .memoryPressure, .swap, .thermal, .cpuTemperature, .fanMaxed, .gpuHigh, .network]
        case .energy: [.batteryHealth, .batteryDrainOnAC, .energyHog, .sleepBlocker]
        case .storage: [.disk, .volumeFull, .ssdWear]
        }
    }

    public static func group(of rule: RuleID) -> RuleGroup? { allCases.first { $0.rules.contains(rule) } }
}

extension MonitorSettings {
    /// Puts the switches, thresholds and durations of one rule back to the defaults.
    public mutating func reset(_ rule: RuleID) {
        let d = MonitorSettings()
        if d.isEnabled(rule) { enabledRules.insert(rule) } else { enabledRules.remove(rule) }
        switch rule {
        case .runawayProcess: processCPUThreshold = d.processCPUThreshold; processCPUSustain = d.processCPUSustain
        case .memoryHog: memoryHogFraction = d.memoryHogFraction; memoryHogSustain = d.memoryHogSustain
        case .cpuHigh: cpuTotalThreshold = d.cpuTotalThreshold; cpuTotalSustain = d.cpuTotalSustain
        case .memoryPressure: memoryPressureSustain = d.memoryPressureSustain
        case .swap: swapThresholdGB = d.swapThresholdGB
        case .thermal, .custom: break
        case .cpuTemperature: cpuTempThreshold = d.cpuTempThreshold; cpuTempSustain = d.cpuTempSustain
        case .fanMaxed: fanMaxPercent = d.fanMaxPercent; fanMaxSustain = d.fanMaxSustain
        case .gpuHigh: gpuHighThreshold = d.gpuHighThreshold; gpuHighSustain = d.gpuHighSustain
        case .network: networkOfflineSustain = d.networkOfflineSustain
        case .batteryHealth: batteryHealthMinPercent = d.batteryHealthMinPercent
        case .batteryDrainOnAC: batteryDrainSustain = d.batteryDrainSustain
        case .energyHog: energyHogWatts = d.energyHogWatts; energyHogSustain = d.energyHogSustain
        case .sleepBlocker: sleepBlockerSustain = d.sleepBlockerSustain
        case .disk, .volumeFull: diskMinFreePercent = d.diskMinFreePercent; diskMinFreeGB = d.diskMinFreeGB
        case .ssdWear: ssdWearPercent = d.ssdWearPercent; ssdSpareMinPercent = d.ssdSpareMinPercent
        }
    }

    public mutating func reset(_ group: RuleGroup) {
        for rule in group.rules { reset(rule) }
    }
}
