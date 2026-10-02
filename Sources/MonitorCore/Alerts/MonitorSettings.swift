import Foundation

public enum RuleID: String, CaseIterable, Codable, Sendable {
    case runawayProcess, memoryHog, cpuHigh, memoryPressure, swap, thermal, disk, network

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
        }
    }
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
    public var reminderInterval: TimeInterval = 1800
    public var ignoredProcesses: [String] = ["kernel_task", "mds_stores", "mdworker_shared", "photoanalysisd"]
    /// Icon only by default: every text change makes macOS redraw the status item on each
    /// display (~40 ms), which would dominate the app's energy use.
    public var menuBarStyle: MenuBarStyle = .icon

    public init() {}

    public func isEnabled(_ rule: RuleID) -> Bool { enabledRules.contains(rule) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        enabledRules = (try? c.decodeIfPresent(Set<RuleID>.self, forKey: .enabledRules)) ?? d.enabledRules
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
        reminderInterval = (try? c.decodeIfPresent(Double.self, forKey: .reminderInterval)) ?? d.reminderInterval
        ignoredProcesses = (try? c.decodeIfPresent([String].self, forKey: .ignoredProcesses)) ?? d.ignoredProcesses
        menuBarStyle = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
    }
}
