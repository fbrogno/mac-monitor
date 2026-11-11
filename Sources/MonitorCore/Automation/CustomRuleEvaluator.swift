import Foundation

/// An action the app should carry out now. Nothing here runs anything.
public struct PlannedAction: Sendable, Equatable, Identifiable {
    public let ruleID: UUID
    public let ruleName: String
    public let action: RuleAction
    /// Main process of the target app (lowest PID); nil for actions without a process.
    public let process: ProcessRef?
    /// All unprotected processes of the target app, for ending or throttling the whole app.
    public let pids: [Int32]
    /// True when the user must confirm before the app does it.
    public let requiresConfirmation: Bool
    /// The condition that triggered it; carries title and text for a notification.
    public let condition: Condition

    public var id: String { "\(ruleID.uuidString).\(action.kind.rawValue)" }

    public init(ruleID: UUID, ruleName: String, action: RuleAction, process: ProcessRef?, pids: [Int32],
                requiresConfirmation: Bool, condition: Condition) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.action = action
        self.process = process
        self.pids = pids
        self.requiresConfirmation = requiresConfirmation
        self.condition = condition
    }
}

/// Processes that custom rules must never end or throttle: the system itself, MacMonitor, and
/// anything that is not recognisably a user's app or tool.
public enum ProtectedProcesses {
    /// Lower-case names.
    public static let names: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "finder", "dock", "systemuiserver",
        "controlcenter", "notificationcenter", "coreaudiod", "mds", "mds_stores", "mdworker_shared",
        "logd", "usereventagent", "cfprefsd", "securityd", "trustd", "opendirectoryd", "configd",
        "distnoted", "powerd", "bluetoothd", "airportd", "sshd", "syslogd", "diskarbitrationd",
        "fseventsd", "notifyd", "hidd", "coreservicesd", "lsd", "runningboardd", "tccd", "amfid",
        "sandboxd", "taskgated", "windowmanager", "macmonitor",
    ]

    /// Highest PID that is always treated as system.
    public static let systemPidLimit: Int32 = 100

    /// By name only (used when a rule is written, before any process is known).
    public static func isProtected(name: String) -> Bool {
        names.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Full check on a running process. `ownPid` is MacMonitor itself.
    public static func isProtected(_ p: ProcessStat, ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        if p.pid < systemPidLimit || p.pid == ownPid { return true }
        if isProtected(name: p.name) || isProtected(name: p.appName) { return true }
        if p.appKey.hasPrefix("app:/System/Library/") { return true }
        // Without an app bundle: system daemons (name ending in "d", e.g. `mediaanalysisd`) and
        // reverse-DNS service names are left alone; ordinary tools like `node` or `ffmpeg` are fine.
        if p.appKey.isEmpty || p.appKey.hasPrefix("proc:") {
            let lower = p.name.lowercased()
            if lower.count > 3, lower.hasSuffix("d") { return true }
            if lower.hasPrefix("com.apple.") { return true }
        }
        return false
    }
}

/// Turns custom rules into conditions for the `AlertEngine` and the engine's events back into
/// actions. Pure: time comes in as a parameter.
public struct CustomRuleEvaluator: Sendable {
    /// When the actions of each rule last ran, for the cool-down.
    public private(set) var lastRun: [UUID: Date]

    public init(lastRun: [UUID: Date] = [:]) {
        self.lastRun = lastRun
    }

    /// All processes that belong to the app(s) a name refers to, matched case-insensitively against
    /// process and app names; helpers come along through their shared `appKey`.
    static func processes(named name: String, in s: SystemSnapshot) -> [ProcessStat] {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return [] }
        let matching = s.processes.filter { $0.name.lowercased() == target || $0.appName.lowercased() == target }
        let keys = Set(matching.map(\.appKey).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return matching }
        let members = s.processes.filter { keys.contains($0.appKey) }
        let singles = matching.filter { $0.appKey.isEmpty }
        return members + singles
    }

    /// Conditions of all enabled, valid rules whose comparison currently holds. `isActive` is the
    /// engine's `isActive`, used for hysteresis. Conditions carry `RuleID.custom` and the key
    /// `custom.<id>`; the app should show custom rules only through their `PlannedAction`s.
    public static func conditions(for rules: [CustomRule], in s: SystemSnapshot,
                                  isActive: (String) -> Bool = { _ in false }) -> [Condition] {
        var out: [Condition] = []
        for rule in rules where rule.isEnabled && rule.isValid && rule.powerCondition.allows(s.power) {
            guard let value = rule.metric.value(in: s, processName: rule.processName) else { continue }
            let active = isActive(rule.conditionKey)
            let holds: Bool
            switch rule.comparison {
            case .above: holds = value >= (active ? rule.threshold * Rules.hysteresis : rule.threshold)
            case .below: holds = active ? value <= rule.threshold / Rules.hysteresis : value < rule.threshold
            }
            guard holds else { continue }

            var ref: ProcessRef?
            if rule.metric.needsProcess, let name = rule.processName {
                let main = processes(named: name, in: s).min { $0.pid < $1.pid }
                ref = main.map { ProcessRef(pid: $0.pid, name: $0.name) }
            }
            out.append(Condition(
                key: rule.conditionKey, rule: .custom, severity: rule.severity,
                title: rule.name,
                body: message(rule, value: value),
                sustain: rule.minDuration, process: ref))
        }
        return out
    }

    /// Full German sentence per metric and direction.
    static func message(_ rule: CustomRule, value: Double) -> String {
        let v = rule.metric.format(value)
        let t = rule.metric.format(rule.threshold)
        let above = rule.comparison == .above
        let who = rule.processName ?? ""
        switch rule.metric {
        case .cpuTotal:
            return above ? "Die CPU-Auslastung liegt bei \(v) und damit über der Schwelle von \(t)."
                         : "Die CPU-Auslastung liegt bei \(v) und damit unter der Schwelle von \(t)."
        case .memoryPercent:
            return above ? "Der Arbeitsspeicher ist zu \(v) belegt, das liegt über der Schwelle von \(t)."
                         : "Der Arbeitsspeicher ist zu \(v) belegt, das liegt unter der Schwelle von \(t)."
        case .swapGB:
            return above ? "Der Swap ist \(v) groß und damit über der Schwelle von \(t)."
                         : "Der Swap ist \(v) groß und damit unter der Schwelle von \(t)."
        case .gpuPercent:
            return above ? "Die GPU ist zu \(v) ausgelastet, das liegt über der Schwelle von \(t)."
                         : "Die GPU ist zu \(v) ausgelastet, das liegt unter der Schwelle von \(t)."
        case .cpuTemperature:
            return above ? "Die CPU ist \(v) warm und damit über der Schwelle von \(t)."
                         : "Die CPU ist \(v) warm und damit unter der Schwelle von \(t)."
        case .fanPercent:
            return above ? "Der Lüfter läuft mit \(v) seiner Höchstdrehzahl, das liegt über der Schwelle von \(t)."
                         : "Der Lüfter läuft mit \(v) seiner Höchstdrehzahl, das liegt unter der Schwelle von \(t)."
        case .systemWatts:
            return above ? "Der Mac verbraucht \(v) und damit mehr als die Schwelle von \(t)."
                         : "Der Mac verbraucht \(v) und damit weniger als die Schwelle von \(t)."
        case .batteryPercent:
            return above ? "Der Akku steht bei \(v) und damit über der Schwelle von \(t)."
                         : "Der Akku steht bei \(v) und damit unter der Schwelle von \(t)."
        case .freeDiskGB:
            return above ? "Auf der Festplatte sind \(v) frei, das liegt über der Schwelle von \(t)."
                         : "Auf der Festplatte sind nur noch \(v) frei, das liegt unter der Schwelle von \(t)."
        case .networkDown:
            return above ? "Der Download läuft mit \(v) und damit schneller als die Schwelle von \(t)."
                         : "Der Download läuft mit \(v) und damit langsamer als die Schwelle von \(t)."
        case .networkUp:
            return above ? "Der Upload läuft mit \(v) und damit schneller als die Schwelle von \(t)."
                         : "Der Upload läuft mit \(v) und damit langsamer als die Schwelle von \(t)."
        case .processCPU:
            return above ? "\(who) belegt \(v) CPU und damit mehr als die Schwelle von \(t)."
                         : "\(who) belegt \(v) CPU und damit weniger als die Schwelle von \(t)."
        case .processMemory:
            return above ? "\(who) belegt \(v) Arbeitsspeicher und damit mehr als die Schwelle von \(t)."
                         : "\(who) belegt \(v) Arbeitsspeicher und damit weniger als die Schwelle von \(t)."
        }
    }

    /// Actions that are due for the engine's events. Only `.fired` counts, reminders and escalations
    /// do not run actions again. A rule within its cool-down is skipped. Actions on processes are
    /// planned only for unprotected processes that are running in `snapshot`.
    public mutating func plan(events: [AlertEvent], rules: [CustomRule], snapshot: SystemSnapshot,
                              now: Date) -> [PlannedAction] {
        let byKey = Dictionary(rules.map { ($0.conditionKey, $0) }, uniquingKeysWith: { first, _ in first })
        var planned: [PlannedAction] = []
        for event in events where event.kind == .fired && event.condition.rule == .custom {
            guard let rule = byKey[event.condition.key], rule.isEnabled, rule.isValid else { continue }
            if let last = lastRun[rule.id], now.timeIntervalSince(last) < rule.cooldown { continue }

            var members: [ProcessStat] = []
            if rule.metric.needsProcess, let name = rule.processName {
                members = Self.processes(named: name, in: snapshot).filter { !ProtectedProcesses.isProtected($0) }
                    .sorted { $0.pid < $1.pid }
            }
            let ref = members.first.map { ProcessRef(pid: $0.pid, name: $0.name) }

            var produced = false
            for action in rule.actions {
                switch action {
                case .quitProcess(let askFirst):
                    guard let ref else { continue }
                    planned.append(PlannedAction(ruleID: rule.id, ruleName: rule.name, action: action, process: ref,
                                                 pids: members.map(\.pid), requiresConfirmation: askFirst,
                                                 condition: event.condition))
                case .throttleProcess:
                    guard let ref else { continue }
                    planned.append(PlannedAction(ruleID: rule.id, ruleName: rule.name, action: action, process: ref,
                                                 pids: members.map(\.pid), requiresConfirmation: false,
                                                 condition: event.condition))
                case .showNotification, .runShortcut, .openURL:
                    planned.append(PlannedAction(ruleID: rule.id, ruleName: rule.name, action: action, process: nil,
                                                 pids: [], requiresConfirmation: false, condition: event.condition))
                }
                produced = true
            }
            if produced { lastRun[rule.id] = now }
        }
        return planned
    }

    /// Forget the cool-down of rules that no longer exist.
    public mutating func prune(keeping rules: [CustomRule]) {
        let ids = Set(rules.map(\.id))
        lastRun = lastRun.filter { ids.contains($0.key) }
    }
}
