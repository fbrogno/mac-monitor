import Foundation

/// What a custom rule measures. Units are fixed per metric so thresholds stay easy to type.
public enum CustomMetric: String, CaseIterable, Codable, Sendable {
    case cpuTotal, memoryPercent, swapGB, gpuPercent, cpuTemperature, fanPercent, systemWatts
    case batteryPercent, freeDiskGB, networkDown, networkUp, processCPU, processMemory

    public enum Unit: String, Sendable {
        case percent, gigabytes, celsius, watts, megabytesPerSecond
    }

    public var unit: Unit {
        switch self {
        case .cpuTotal, .memoryPercent, .gpuPercent, .fanPercent, .batteryPercent, .processCPU: .percent
        case .swapGB, .freeDiskGB, .processMemory: .gigabytes
        case .cpuTemperature: .celsius
        case .systemWatts: .watts
        case .networkDown, .networkUp: .megabytesPerSecond
        }
    }

    /// Process metrics need a process or app name; only they allow the actions quit and throttle.
    public var needsProcess: Bool { self == .processCPU || self == .processMemory }

    /// Metrics whose natural range is 0…100.
    var isBoundedPercent: Bool { unit == .percent && self != .processCPU }

    public var title: String {
        switch self {
        case .cpuTotal: "CPU gesamt"
        case .memoryPercent: "Arbeitsspeicher belegt"
        case .swapGB: "Swap"
        case .gpuPercent: "GPU-Auslastung"
        case .cpuTemperature: "CPU-Temperatur"
        case .fanPercent: "Lüfterdrehzahl"
        case .systemWatts: "Systemleistung"
        case .batteryPercent: "Akkustand"
        case .freeDiskGB: "Freier Speicherplatz"
        case .networkDown: "Netzwerk Download"
        case .networkUp: "Netzwerk Upload"
        case .processCPU: "CPU eines Prozesses"
        case .processMemory: "RAM eines Prozesses"
        }
    }

    /// "62 %", "4,2 GB", "78 °C", "12,5 W", "3,1 MB/s".
    public func format(_ value: Double) -> String {
        switch unit {
        case .percent: Format.percent(value)
        case .gigabytes: Format.decimal(value, digits: 1) + " GB"
        case .celsius: Format.decimal(value, digits: 0) + " °C"
        case .watts: Format.decimal(value, digits: 1) + " W"
        case .megabytesPerSecond: Format.decimal(value, digits: 1) + " MB/s"
        }
    }

    /// The current value, nil when the Mac does not report it (or the named process is not running).
    func value(in s: SystemSnapshot, processName: String?) -> Double? {
        let gigabyte = 1_073_741_824.0
        switch self {
        case .cpuTotal: return s.cpuPercent
        case .memoryPercent: return s.memoryTotalBytes > 0 ? s.memoryFraction * 100 : nil
        case .swapGB: return Double(s.swapUsedBytes) / gigabyte
        case .gpuPercent: return s.gpu?.utilizationPercent
        case .cpuTemperature: return s.thermals?.cpuMaxCelsius
        case .fanPercent: return s.fans.filter { $0.maxRpm > 0 }.map { $0.fraction * 100 }.max()
        case .systemWatts: return s.powerDraw?.systemWatts
        case .batteryPercent: return s.power.batteryPercent.map(Double.init)
        case .freeDiskGB: return s.disk.map { Double($0.availableBytes) / gigabyte }
        case .networkDown: return s.network.map { $0.downBytesPerSecond / 1_048_576 }
        case .networkUp: return s.network.map { $0.upBytesPerSecond / 1_048_576 }
        case .processCPU, .processMemory:
            guard let processName else { return nil }
            let group = CustomRuleEvaluator.processes(named: processName, in: s)
            guard !group.isEmpty else { return nil }
            if self == .processCPU { return group.reduce(0) { $0 + $1.cpuPercent } }
            return Double(group.reduce(UInt64(0)) { $0 + $1.footprintBytes }) / gigabyte
        }
    }
}

public enum CustomComparison: String, CaseIterable, Codable, Sendable {
    case above, below

    public var title: String {
        switch self {
        case .above: "liegt über"
        case .below: "liegt unter"
        }
    }
}

/// Restricts a rule to a power source.
public enum PowerCondition: String, CaseIterable, Codable, Sendable {
    case always, onlyOnBattery, onlyOnAC

    public var title: String {
        switch self {
        case .always: "Immer"
        case .onlyOnBattery: "Nur im Akkubetrieb"
        case .onlyOnAC: "Nur am Netzteil"
        }
    }

    func allows(_ power: PowerState) -> Bool {
        switch self {
        case .always: true
        case .onlyOnBattery: power.onBattery
        case .onlyOnAC: !power.onBattery
        }
    }
}

/// What a custom rule does when it fires. Only describes the action; the app carries it out
/// (see `PlannedAction`).
public enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case showNotification
    case runShortcut(name: String)
    /// Quit the process or app. `askFirst` shows a confirmation before anything is ended.
    case quitProcess(askFirst: Bool)
    /// Lower the process priority ("nice") instead of ending it.
    case throttleProcess
    case openURL(String)

    public enum Kind: String, CaseIterable, Sendable {
        case showNotification, runShortcut, quitProcess, throttleProcess, openURL

        public var title: String {
            switch self {
            case .showNotification: "Mitteilung zeigen"
            case .runShortcut: "Kurzbefehl ausführen"
            case .quitProcess: "Prozess beenden"
            case .throttleProcess: "Prozess drosseln"
            case .openURL: "URL öffnen"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .showNotification: .showNotification
        case .runShortcut: .runShortcut
        case .quitProcess: .quitProcess
        case .throttleProcess: .throttleProcess
        case .openURL: .openURL
        }
    }

    /// Quit and throttle act on a process, so they only make sense for process metrics.
    public var needsProcess: Bool { kind == .quitProcess || kind == .throttleProcess }
}

public enum RuleValidationError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong(maxLength: Int)
    case thresholdNotFinite
    case thresholdNegative
    case thresholdAbove100
    case negativeDuration
    case negativeCooldown
    case missingProcessName
    case noActions
    case actionNeedsProcessMetric(RuleAction.Kind)
    case protectedProcess(String)
    case emptyShortcutName
    case invalidURL(String)
}

/// A user-defined rule: measure, compare, hold for a while, then do something.
public struct CustomRule: Codable, Equatable, Identifiable, Sendable {
    public static let maxNameLength = 80

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var metric: CustomMetric
    /// Process or app name for `processCPU` / `processMemory`; compared without regard to case against
    /// the process name and the app name.
    public var processName: String?
    public var comparison: CustomComparison
    /// In the unit of `metric` (see `CustomMetric.unit`).
    public var threshold: Double
    /// How long the comparison must hold without interruption.
    public var minDuration: TimeInterval
    public var powerCondition: PowerCondition
    public var severity: Severity
    /// Minimum time between two runs of the actions of this rule.
    public var cooldown: TimeInterval
    public var actions: [RuleAction]

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, metric: CustomMetric,
                processName: String? = nil, comparison: CustomComparison = .above, threshold: Double,
                minDuration: TimeInterval = 60, powerCondition: PowerCondition = .always,
                severity: Severity = .warning, cooldown: TimeInterval = 1800,
                actions: [RuleAction] = [.showNotification]) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.metric = metric
        self.processName = processName
        self.comparison = comparison
        self.threshold = threshold
        self.minDuration = minDuration
        self.powerCondition = powerCondition
        self.severity = severity
        self.cooldown = cooldown
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, metric, processName, comparison, threshold, minDuration
        case powerCondition, severity, cooldown, actions
    }

    /// Tolerant like `MonitorSettings`: only identity, name, metric and threshold are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        metric = try c.decode(CustomMetric.self, forKey: .metric)
        threshold = try c.decode(Double.self, forKey: .threshold)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        processName = try? c.decodeIfPresent(String.self, forKey: .processName)
        comparison = (try? c.decodeIfPresent(CustomComparison.self, forKey: .comparison)) ?? .above
        minDuration = (try? c.decodeIfPresent(Double.self, forKey: .minDuration)) ?? 60
        powerCondition = (try? c.decodeIfPresent(PowerCondition.self, forKey: .powerCondition)) ?? .always
        severity = (try? c.decodeIfPresent(Severity.self, forKey: .severity)) ?? .warning
        cooldown = (try? c.decodeIfPresent(Double.self, forKey: .cooldown)) ?? 1800
        actions = (try? c.decodeIfPresent([RuleAction].self, forKey: .actions)) ?? [.showNotification]
    }

    /// Key of the conditions this rule produces.
    public var conditionKey: String { "custom.\(id.uuidString)" }

    /// Empty means the rule is usable.
    public func validate() -> [RuleValidationError] {
        var errors: [RuleValidationError] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { errors.append(.emptyName) }
        if trimmed.count > Self.maxNameLength { errors.append(.nameTooLong(maxLength: Self.maxNameLength)) }

        if !threshold.isFinite {
            errors.append(.thresholdNotFinite)
        } else if threshold < 0 {
            errors.append(.thresholdNegative)
        } else if metric.isBoundedPercent && threshold > 100 {
            errors.append(.thresholdAbove100)
        }
        if minDuration < 0 { errors.append(.negativeDuration) }
        if cooldown < 0 { errors.append(.negativeCooldown) }

        let process = processName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if metric.needsProcess && process.isEmpty { errors.append(.missingProcessName) }

        if actions.isEmpty { errors.append(.noActions) }
        var reported = Set<RuleAction.Kind>()
        for action in actions {
            if action.needsProcess {
                if !metric.needsProcess {
                    if reported.insert(action.kind).inserted { errors.append(.actionNeedsProcessMetric(action.kind)) }
                } else if !process.isEmpty, ProtectedProcesses.isProtected(name: process) {
                    let protected = RuleValidationError.protectedProcess(process)
                    if !errors.contains(protected) { errors.append(protected) }
                }
            }
            switch action {
            case .runShortcut(let shortcut) where shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                errors.append(.emptyShortcutName)
            case .openURL(let text) where !Self.isWebURL(text):
                errors.append(.invalidURL(text))
            default: break
            }
        }
        return errors
    }

    public var isValid: Bool { validate().isEmpty }

    static func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

extension CustomRule {
    /// Ready-made rules to start from. Ids are fixed so a template can be recognised; use
    /// `instantiated()` to add one to the user's rules.
    public static let templates: [CustomRule] = [
        CustomRule(
            id: UUID(uuidString: "6F1D0A10-0000-4000-8000-000000000001")!,
            name: "Chrome frisst RAM", metric: .processMemory, processName: "Google Chrome",
            comparison: .above, threshold: 4, minDuration: 120, severity: .warning, cooldown: 1800,
            actions: [.showNotification, .quitProcess(askFirst: true)]),
        CustomRule(
            id: UUID(uuidString: "6F1D0A10-0000-4000-8000-000000000002")!,
            name: "Mac wird heiß", metric: .cpuTemperature, comparison: .above, threshold: 90,
            minDuration: 120, severity: .warning, cooldown: 900, actions: [.showNotification]),
        CustomRule(
            id: UUID(uuidString: "6F1D0A10-0000-4000-8000-000000000003")!,
            name: "Akku unter 20 %", metric: .batteryPercent, comparison: .below, threshold: 20,
            minDuration: 30, powerCondition: .onlyOnBattery, severity: .warning, cooldown: 3600,
            actions: [.showNotification, .runShortcut(name: "Energie sparen")]),
        CustomRule(
            id: UUID(uuidString: "6F1D0A10-0000-4000-8000-000000000004")!,
            name: "Xcode zu hungrig", metric: .processCPU, processName: "Xcode",
            comparison: .above, threshold: 300, minDuration: 300, severity: .info, cooldown: 1800,
            actions: [.showNotification, .throttleProcess]),
        CustomRule(
            id: UUID(uuidString: "6F1D0A10-0000-4000-8000-000000000005")!,
            name: "Großer Upload läuft", metric: .networkUp, comparison: .above, threshold: 5,
            minDuration: 300, severity: .info, cooldown: 3600, actions: [.showNotification]),
    ]

    /// A copy with a fresh id, ready to be stored as the user's own rule.
    public func instantiated() -> CustomRule {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
