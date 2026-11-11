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

    /// Executables below these folders belong to the system, with or without an app bundle. Left out on purpose:
    /// `/usr/bin` (tools like `python3` or `ssh`) and `/System/Cryptexes` (Safari lives there).
    static let systemPathPrefixes = [
        "/System/Library/", "/System/Applications/", "/System/iOSSupport/", "/usr/libexec/", "/usr/sbin/", "/sbin/",
        "/Library/Apple/", "/Library/PrivilegedHelperTools/",
    ]

    /// By name only (used when a rule is written, before any process is known).
    public static func isProtected(name: String) -> Bool {
        names.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// True for an executable path or app key inside a system folder, including `/System/Applications/…`.
    static func isSystemPath(_ path: String) -> Bool {
        systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    /// Full check on a running process. `ownPid` is MacMonitor itself.
    public static func isProtected(_ p: ProcessStat, ownPid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        if p.pid < systemPidLimit || p.pid == ownPid { return true }
        if isProtected(name: p.name) || isProtected(name: p.appName) { return true }
        // Own bundle, not `appKey`: a `node` that Terminal started carries Terminal's key but is an ordinary tool.
        if !p.bundlePath.isEmpty && isSystemPath(p.bundlePath) { return true }
        if p.name.lowercased().hasPrefix("com.apple.") { return true }
        if !p.path.isEmpty {
            // The executable's own location decides: a Homebrew `mongod` or `postgres` is an ordinary tool.
            return isSystemPath(p.path)
        }
        // Without a known path and without an app bundle, the old rule of thumb is the only evidence left:
        // names ending in "d" (`mediaanalysisd`) are daemons. It applies only here, never when the path is known.
        if p.appKey.isEmpty || p.appKey.hasPrefix("proc:") {
            let lower = p.name.lowercased()
            if lower.count > 3, lower.hasSuffix("d") { return true }
        }
        return false
    }
}

/// Apps that run other programs (terminals, editors, IDEs): a rule on a program inside them must never reach
/// the host or its other children, and a rule on the host itself affects only the processes called by that name.
enum HostApps {
    static let names: Set<String> = [
        "terminal", "iterm", "iterm2", "warp", "ghostty", "kitty", "alacritty", "hyper", "wezterm", "tabby",
        "visual studio code", "visual studio code - insiders", "vscodium", "cursor", "windsurf", "zed", "xcode",
        "sublime text", "nova", "fleet", "tmux",
    ]
    static let prefixes = [
        "intellij idea", "pycharm", "webstorm", "goland", "clion", "rider", "phpstorm", "rubymine", "datagrip",
        "android studio", "appcode",
    ]

    /// `name` is a bundle name without ".app".
    static func isHost(bundleName name: String) -> Bool {
        let lower = name.lowercased()
        return names.contains(lower) || prefixes.contains { lower.hasPrefix($0) }
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

    /// The processes a name refers to, matched case-insensitively: processes with exactly that name, and, when
    /// the name is that of an app, all processes whose own executable lives in that app's bundle (its helpers).
    /// Not the accountability group: `appKey` also gathers everything an app started (a `node` in Terminal
    /// belongs to Terminal that way), and a rule on "Terminal" must not end a `node`, nor the other way round.
    /// Host apps (terminals, editors) are never expanded to their bundle.
    static func processes(named name: String, in s: SystemSnapshot) -> [ProcessStat] {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return [] }
        return s.processes.filter { p in
            if p.name.lowercased() == target { return true }
            guard !p.bundlePath.isEmpty else { return false }
            let bundle = AppGrouping.bundleName(p.bundlePath)
            return bundle.lowercased() == target && !HostApps.isHost(bundleName: bundle)
        }
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
                ref = main.map { ProcessRef($0) }
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
            return above ? L("Die CPU-Auslastung liegt bei \(v) und damit über der Schwelle von \(t).")
                         : L("Die CPU-Auslastung liegt bei \(v) und damit unter der Schwelle von \(t).")
        case .memoryPercent:
            return above ? L("Der Arbeitsspeicher ist zu \(v) belegt, das liegt über der Schwelle von \(t).")
                         : L("Der Arbeitsspeicher ist zu \(v) belegt, das liegt unter der Schwelle von \(t).")
        case .swapGB:
            return above ? L("Der Swap ist \(v) groß und damit über der Schwelle von \(t).")
                         : L("Der Swap ist \(v) groß und damit unter der Schwelle von \(t).")
        case .gpuPercent:
            return above ? L("Die GPU ist zu \(v) ausgelastet, das liegt über der Schwelle von \(t).")
                         : L("Die GPU ist zu \(v) ausgelastet, das liegt unter der Schwelle von \(t).")
        case .cpuTemperature:
            return above ? L("Die CPU ist \(v) warm und damit über der Schwelle von \(t).")
                         : L("Die CPU ist \(v) warm und damit unter der Schwelle von \(t).")
        case .fanPercent:
            return above ? L("Der Lüfter läuft mit \(v) seiner Höchstdrehzahl, das liegt über der Schwelle von \(t).")
                         : L("Der Lüfter läuft mit \(v) seiner Höchstdrehzahl, das liegt unter der Schwelle von \(t).")
        case .systemWatts:
            return above ? L("Der Mac verbraucht \(v) und damit mehr als die Schwelle von \(t).")
                         : L("Der Mac verbraucht \(v) und damit weniger als die Schwelle von \(t).")
        case .batteryPercent:
            return above ? L("Der Akku steht bei \(v) und damit über der Schwelle von \(t).")
                         : L("Der Akku steht bei \(v) und damit unter der Schwelle von \(t).")
        case .freeDiskGB:
            return above ? L("Auf der Festplatte sind \(v) frei, das liegt über der Schwelle von \(t).")
                         : L("Auf der Festplatte sind nur noch \(v) frei, das liegt unter der Schwelle von \(t).")
        case .networkDown:
            return above ? L("Der Download läuft mit \(v) und damit schneller als die Schwelle von \(t).")
                         : L("Der Download läuft mit \(v) und damit langsamer als die Schwelle von \(t).")
        case .networkUp:
            return above ? L("Der Upload läuft mit \(v) und damit schneller als die Schwelle von \(t).")
                         : L("Der Upload läuft mit \(v) und damit langsamer als die Schwelle von \(t).")
        case .processCPU:
            return above ? L("\(who) belegt \(v) CPU und damit mehr als die Schwelle von \(t).")
                         : L("\(who) belegt \(v) CPU und damit weniger als die Schwelle von \(t).")
        case .processMemory:
            return above ? L("\(who) belegt \(v) Arbeitsspeicher und damit mehr als die Schwelle von \(t).")
                         : L("\(who) belegt \(v) Arbeitsspeicher und damit weniger als die Schwelle von \(t).")
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
            let ref = members.first.map { ProcessRef($0) }

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
