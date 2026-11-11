import Darwin
import Foundation
import Testing
@testable import MonitorCore

private let fig = "\u{2007}"
/// Figure spaces are only padding; tests compare the visible text.
private func visible(_ s: String) -> String { s.replacingOccurrences(of: fig, with: "") }

private func values(cpu: Double = 12, memory: Double = 58, gpu: Double? = nil, temp: Double? = nil, watts: Double? = nil,
                    down: Double? = nil, battery: Double? = nil) -> MenuBarValues {
    MenuBarValues(cpuPercent: cpu, memoryPercent: memory, gpuPercent: gpu, temperatureCelsius: temp,
                  watts: watts, downBytesPerSecond: down, batteryPercent: battery)
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

// MARK: - Menu bar

@Suite struct MenuBarDisplayTests {
    @Test func iconOnlyHasNoText() {
        var d = MenuBarDisplay()
        #expect(d.update(items: [], values: values(), now: t0) == nil)
        #expect(d.text.isEmpty)
    }

    @Test func buildsTextForSeveralValuesWithTags() {
        var d = MenuBarDisplay()
        let text = d.update(items: [.cpu, .memory, .temperature], values: values(temp: 61), now: t0)
        #expect(text.map(visible) == "CPU 12% · RAM 58% · 61°C")
    }

    @Test func singleValueHasNoTag() {
        var d = MenuBarDisplay()
        #expect(d.update(items: [.cpu], values: values(), now: t0).map(visible) == "12%")
    }

    @Test func missingValuesAreLeftOut() {
        var d = MenuBarDisplay()
        let text = d.update(items: [.cpu, .gpu, .power], values: values(watts: nil), now: t0)
        #expect(text.map(visible) == "12%")
    }

    @Test func netAndPowerFormats() {
        var d = MenuBarDisplay()
        let text = d.update(items: [.networkDown, .power], values: values(watts: 11.4, down: 1_900_000), now: t0)
        #expect(text.map(visible) == "↓1,8 MB/s · 11 W")
    }

    @Test func textKeepsItsLengthWhileValuesMove() {
        var small = MenuBarDisplay(), big = MenuBarDisplay()
        let a = small.update(items: [.cpu, .memory], values: values(cpu: 4, memory: 9), now: t0)
        let b = big.update(items: [.cpu, .memory], values: values(cpu: 100, memory: 88), now: t0)
        #expect(a?.count == b?.count)
    }

    @Test func percentMovesBelowFivePointsAreIgnored() {
        var d = MenuBarDisplay()
        _ = d.update(items: [.cpu], values: values(cpu: 20), now: t0)
        #expect(d.update(items: [.cpu], values: values(cpu: 24), now: t0.addingTimeInterval(60)) == nil)
        #expect(d.update(items: [.cpu], values: values(cpu: 25), now: t0.addingTimeInterval(120)).map(visible) == "25%")
    }

    @Test func temperatureNeedsTwoDegrees() {
        #expect(!MenuBarDisplay.moved(.temperature, from: 60, to: 61))
        #expect(MenuBarDisplay.moved(.temperature, from: 60, to: 62))
    }

    @Test func powerStepDependsOnLevel() {
        #expect(!MenuBarDisplay.moved(.power, from: 10, to: 10.9))
        #expect(MenuBarDisplay.moved(.power, from: 10, to: 11))
        #expect(!MenuBarDisplay.moved(.power, from: 30, to: 34))
        #expect(MenuBarDisplay.moved(.power, from: 30, to: 35))
    }

    @Test func networkUsesCoarseSteps() {
        let mb = 1_048_576.0
        #expect(!MenuBarDisplay.moved(.networkDown, from: 1.1 * mb, to: 1.9 * mb))
        #expect(MenuBarDisplay.moved(.networkDown, from: 1.9 * mb, to: 2.1 * mb))
        #expect(!MenuBarDisplay.moved(.networkDown, from: 0.0, to: 20_000))
        #expect(MenuBarDisplay.moved(.networkDown, from: 20_000, to: 0.3 * mb))
    }

    @Test func redrawsAtMostEveryTenSeconds() {
        var d = MenuBarDisplay()
        _ = d.update(items: [.cpu], values: values(cpu: 10), now: t0)
        #expect(d.update(items: [.cpu], values: values(cpu: 50), now: t0.addingTimeInterval(3)) == nil)
        #expect(d.update(items: [.cpu], values: values(cpu: 50), now: t0.addingTimeInterval(11)).map(visible) == "50%")
    }

    @Test func changedChoiceRedrawsAtOnce() {
        var d = MenuBarDisplay()
        _ = d.update(items: [.cpu], values: values(), now: t0)
        #expect(d.update(items: [.cpu, .memory], values: values(), now: t0.addingTimeInterval(1)) != nil)
        #expect(d.update(items: [], values: values(), now: t0.addingTimeInterval(2)) == "")
    }

    @Test func textChangesOnlyWhenTheShownTextChanges() {
        var d = MenuBarDisplay()
        _ = d.update(items: [.power], values: values(watts: 10.2), now: t0)
        // Moved by a whole watt but rounds to the same shown number: no redraw.
        #expect(d.update(items: [.power], values: values(watts: 10.4), now: t0.addingTimeInterval(30)) == nil)
    }

    @Test func itemsAreLimitedToThreeWithoutDuplicates() {
        #expect(MenuBarItem.normalized([.cpu, .cpu, .memory, .gpu, .power]) == [.cpu, .memory, .gpu])
    }

    @Test func oldStylesMigrateWithoutLoss() throws {
        for (style, items) in [("icon", []), ("iconAndCPU", [MenuBarItem.cpu]), ("iconCPUAndMemory", [.cpu, .memory])] {
            let json = #"{"menuBarStyle":"\#(style)"}"#
            let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(json.utf8))
            #expect(s.menuBarItems == items)
            #expect(s.menuBarStyle.rawValue == style)
        }
    }

    @Test func freeChoiceRoundTripsAndKeepsOldStyleReadable() throws {
        var s = MonitorSettings()
        s.menuBarItems = [.cpu, .power, .battery]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MonitorSettings.self, from: data)
        #expect(back.menuBarItems == [.cpu, .power, .battery])
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["menuBarStyle"] as? String == "iconAndCPU")
    }

    @Test func unknownItemsAreDropped() throws {
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"menuBarItems":["cpu","fusion","gpu"]}"#.utf8))
        #expect(s.menuBarItems == [.cpu, .gpu])
    }
}

// MARK: - Validation texts

@Suite struct RuleMessageTests {
    private let all: [RuleValidationError] = [
        .emptyName, .nameTooLong(maxLength: 80), .thresholdNotFinite, .thresholdNegative, .thresholdAbove100,
        .negativeDuration, .negativeCooldown, .missingProcessName, .noActions,
        .actionNeedsProcessMetric(.quitProcess), .actionNeedsProcessMetric(.throttleProcess),
        .actionNeedsProcessMetric(.showNotification), .protectedProcess("Finder"), .emptyShortcutName,
        .invalidURL("kein url"), .invalidURL("  "),
    ]

    @Test func everyErrorHasAGermanSentence() {
        for error in all {
            let text = error.message
            #expect(text.count > 20, "\(error)")
            #expect(text.hasSuffix("."), "\(error)")
            #expect(!text.contains("RuleValidationError"), "\(error)")
        }
        #expect(Set(all.map(\.message)).count == all.count)
    }

    @Test func parametersAppearInTheText() {
        #expect(RuleValidationError.nameTooLong(maxLength: 80).message.contains("80"))
        #expect(RuleValidationError.protectedProcess("Finder").message.contains("Finder"))
    }

    @Test func everyFieldIsUsed() {
        #expect(Set(all.map(\.field)) == Set(RuleField.allCases))
    }

    @Test func realValidationErrorsMapToFields() {
        var rule = CustomRule(name: " ", metric: .cpuTotal, threshold: 150, minDuration: -1, cooldown: -5, actions: [])
        rule.processName = nil
        let fields = Set(rule.validate().map(\.field))
        #expect(fields == [.name, .threshold, .duration, .cooldown, .actions])
    }
}

// MARK: - URL policy

@Suite struct ActionURLPolicyTests {
    @Test func webAndAppSchemesPass() {
        for ok in ["https://example.com/a?b=1", "http://localhost:8080", "slack://channel?team=T1", "things:///show?id=today",
                   "x-apple.systempreferences:com.apple.Notifications-Settings.extension", "mailto:a@b.de", " https://example.com "] {
            #expect(ActionURLPolicy.isAllowed(ok), "\(ok)")
        }
    }

    @Test func localAndDangerousSchemesAreRefused() {
        for bad in ["file:///etc/hosts", "FILE:///Applications", "javascript:alert(1)", "data:text/html,x", "ftp://example.com",
                    "ssh://host", "smb://server/share", "vnc://host", "https://", "http:///x", "kein url", "example.com", "", "x:",
                    "https://exa mple.com", "ht\ttp://a.de"] {
            #expect(!ActionURLPolicy.isAllowed(bad), "\(bad)")
        }
    }

    @Test func validationUsesThePolicy() {
        let rule = CustomRule(name: "x", metric: .cpuTotal, threshold: 50, actions: [.openURL("file:///etc/passwd")])
        #expect(rule.validate() == [.invalidURL("file:///etc/passwd")])
        let ok = CustomRule(name: "x", metric: .cpuTotal, threshold: 50, actions: [.openURL("slack://open")])
        #expect(ok.validate().isEmpty)
    }
}

// MARK: - Signals: decisions

@Suite struct SignalGuardTests {
    @Test func allowedWhenSameProcess() {
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "node", currentName: "node", ownPid: 1) == .allowed)
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "Node", currentName: "node", ownPid: 1) == .allowed)
    }

    @Test func gone() {
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "node", currentName: nil, ownPid: 1) == .gone)
    }

    @Test func reusedPidIsDetected() {
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "node", currentName: "Safari", ownPid: 1) == .pidReused(nowNamed: "Safari"))
    }

    @Test func reusedPidNeverReachesProtectedProcess() {
        // The recorded process was harmless, but the PID now belongs to Finder: not the same process, not touched.
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "node", currentName: "Finder", ownPid: 1) == .pidReused(nowNamed: "Finder"))
    }

    @Test func protectedNamesPidsAndSelf() {
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "Finder", currentName: "Finder", ownPid: 1) == .protected)
        #expect(SignalGuard.verdict(pid: 50, expectedName: "x", currentName: "x", ownPid: 1) == .protected)
        #expect(SignalGuard.verdict(pid: 4000, expectedName: "x", currentName: "x", ownPid: 4000) == .protected)
    }

    @Test func truncatedNamesStillMatch() {
        let full = "Google Chrome Helper (Renderer)"
        #expect(SignalGuard.verdict(pid: 4000, expectedName: full, currentName: String(full.prefix(16)), ownPid: 1) == .allowed)
        #expect(SignalGuard.verdict(pid: 4000, expectedName: full, currentName: String(full.prefix(24)), ownPid: 1) == .allowed)
        // Too short a prefix says nothing about identity.
        #expect(SignalGuard.verdict(pid: 4000, expectedName: full, currentName: "Google", ownPid: 1) == .pidReused(nowNamed: "Google"))
    }
}

// MARK: - Signals: on throwaway processes only

@Suite(.serialized) struct ProcessControlTests {
    /// A child started just for the test; ended in any case.
    private func withChild(_ body: (Process) throws -> Void) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["600"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try body(child)
    }

    @Test func childNameIsReadable() throws {
        try withChild { child in
            #expect(ProcessControl.currentName(of: child.processIdentifier) == "sleep")
        }
        #expect(ProcessControl.currentName(of: 2_000_000_000) == nil)
    }

    @Test func throttleLowersPriority() throws {
        try withChild { child in
            let pid = child.processIdentifier
            #expect(getpriority(PRIO_PROCESS, id_t(pid)) == 0)
            let results = ProcessControl.throttle([ProcessRef(pid: pid, name: "sleep")])
            #expect(results.map(\.outcome) == [.done])
            #expect(getpriority(PRIO_PROCESS, id_t(pid)) == 10)
            #expect(child.isRunning)
        }
    }

    @Test func terminateEndsTheChildMainProcessFirst() throws {
        try withChild { child in
            let pid = child.processIdentifier
            let results = ProcessControl.terminate([ProcessRef(pid: pid, name: "sleep")])
            #expect(results.map(\.outcome) == [.done])
            child.waitUntilExit()
            #expect(child.terminationReason == .uncaughtSignal)
            #expect(child.terminationStatus == SIGTERM)
        }
    }

    @Test func protectedNameIsRefusedAndChildSurvives() throws {
        try withChild { child in
            let ref = ProcessRef(pid: child.processIdentifier, name: "Finder")
            // The PID is the child's, but the rule claims it is Finder: refused as reused PID, never signalled.
            #expect(ProcessControl.terminate([ref]).map(\.outcome) == [.skipped(.pidReused(nowNamed: "sleep"))])
            #expect(ProcessControl.throttle([ref]).map(\.outcome) == [.skipped(.pidReused(nowNamed: "sleep"))])
            #expect(child.isRunning)
            #expect(getpriority(PRIO_PROCESS, id_t(child.processIdentifier)) == 0)
        }
    }

    @Test func protectedProcessIsRefusedEvenWhenNameMatches() throws {
        // Injected lookup: the child "is" Finder, so name and expectation agree, yet protection wins.
        try withChild { child in
            let ref = ProcessRef(pid: child.processIdentifier, name: "Finder")
            let out = ProcessControl.terminate([ref], currentName: { _ in "Finder" })
            #expect(out.map(\.outcome) == [.skipped(.protected)])
            #expect(child.isRunning)
        }
    }

    @Test func reusedPidIsNotSignalled() throws {
        try withChild { child in
            let ref = ProcessRef(pid: child.processIdentifier, name: "node")
            #expect(ProcessControl.terminate([ref]).map(\.outcome) == [.skipped(.pidReused(nowNamed: "sleep"))])
            #expect(child.isRunning)
        }
    }

    @Test func endedProcessIsReportedAsGone() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let out = ProcessControl.terminate([ProcessRef(pid: child.processIdentifier, name: "true")])
        #expect(out.map(\.outcome) == [.skipped(.gone)])
    }
}

// MARK: - Shortcuts

@Suite struct ShortcutRunnerTests {
    @Test func unknownShortcutFailsWithMessage() async {
        let result = await ShortcutRunner.run(name: "MacMonitor-Test-gibt-es-nicht-7f3a91", timeout: 30)
        guard case .failed(let message) = result else {
            Issue.record("erwartet .failed, bekam \(result)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func invalidNamesAreRefusedWithoutRunning() async {
        #expect(await ShortcutRunner.run(name: "  ") == .invalidName)
        #expect(await ShortcutRunner.run(name: "--help") == .invalidName)
    }

    @Test func missingToolIsReported() async {
        #expect(await ShortcutRunner.run(name: "x", executable: "/nonexistent/shortcuts") == .unavailable)
    }

    @Test func slowRunIsStoppedAtTheTimeLimit() async {
        let started = Date()
        let result = await ShortcutRunner.run(name: "x", timeout: 0.5, executable: "/bin/sleep", arguments: { _ in ["30"] })
        #expect(result == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func nameIsOneArgumentWithoutShell() async {
        // A name that would be a command in a shell is just a (missing) shortcut here.
        let result = await ShortcutRunner.run(name: "x; touch /tmp/macmonitor-should-not-exist", timeout: 30)
        #expect(result != .success)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/macmonitor-should-not-exist"))
    }
}

// MARK: - Energy average

@Suite struct EnergyAveragerTests {
    private func proc(_ pid: Int32, _ key: String, _ mw: Double) -> ProcessStat {
        ProcessStat(pid: pid, name: key, cpuPercent: 0, footprintBytes: 0, energyMilliwatts: mw, appKey: key, appName: key)
    }

    @Test func meanOverTheWindowSumsHelpers() {
        var a = EnergyAverager()
        a.add([proc(1, "app:A", 4000), proc(2, "app:A", 2000)], at: t0)
        a.add([proc(1, "app:A", 1000), proc(2, "app:A", 1000)], at: t0.addingTimeInterval(60))
        #expect(a.averages["app:A"] == 4000)
    }

    @Test func oldSamplesLeaveTheWindow() {
        var a = EnergyAverager(window: 300)
        a.add([proc(1, "app:A", 9000)], at: t0)
        a.add([proc(1, "app:A", 1000)], at: t0.addingTimeInterval(400))
        #expect(a.averages["app:A"] == 1000)
    }

    @Test func shortSpikeDoesNotReachTheLimit() {
        var a = EnergyAverager()
        for i in 0..<9 { a.add([proc(1, "app:A", 1000)], at: t0.addingTimeInterval(Double(i) * 20)) }
        a.add([proc(1, "app:A", 20_000)], at: t0.addingTimeInterval(180))
        #expect((a.averages["app:A"] ?? 0) < 8000)
    }

    @Test func goneAppsDecayAndDisappear() {
        var a = EnergyAverager(window: 300)
        a.add([proc(1, "app:A", 6000)], at: t0)
        a.add([], at: t0.addingTimeInterval(100))
        #expect(a.averages["app:A"] == 3000)
        a.add([], at: t0.addingTimeInterval(500))
        #expect(a.trackedApps == 0)
    }

    @Test func memoryIsBounded() {
        var a = EnergyAverager(window: 300, maxApps: 5)
        a.add((0..<50).map { proc(Int32($0 + 200), "app:\($0)", Double($0 + 1)) }, at: t0)
        #expect(a.trackedApps == 5)
        #expect(a.averages["app:49"] == 50)
    }

    @Test func ruleUsesTheAverageNotTheSpike() {
        var s = MonitorSettings()
        s.energyHogWatts = 8
        let spike = SystemSnapshot(date: t0, cpuPercent: 0, memoryUsedBytes: 0, memoryTotalBytes: 0, memoryPressure: .normal,
                                   swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, network: nil,
                                   power: PowerState(onBattery: true, batteryPercent: 50, lowPowerMode: false),
                                   processes: [proc(1, "app:A", 12_000)])
        let withSpike = Rules.evaluate(spike, Rules.Context(settings: s))
        #expect(withSpike.contains { $0.rule == .energyHog })
        let averaged = Rules.evaluate(spike, Rules.Context(settings: s, averagedAppEnergyMilliwatts: ["app:A": 2000]))
        #expect(!averaged.contains { $0.rule == .energyHog })
    }
}

// MARK: - Settings: tolerance, groups, export

@Suite struct SettingsToleranceTests {
    private func goodRuleJSON(_ id: String, name: String = "Gut") -> String {
        #"{"id":"\#(id)","name":"\#(name)","metric":"cpuTotal","threshold":80}"#
    }

    @Test func oneBrokenRuleDoesNotCostTheOthers() throws {
        let a = UUID().uuidString, b = UUID().uuidString
        let json = """
        {"customRules":[\(goodRuleJSON(a, name: "A")),
          {"id":"\(UUID().uuidString)","name":"Kaputt","metric":"gibtEsNicht","threshold":1},
          {"nur":"Unsinn"}, 42,
          {"id":"\(UUID().uuidString)","name":"Neue Aktion","metric":"cpuTotal","threshold":1,"actions":[{"teleport":{}}]},
          \(goodRuleJSON(b, name: "B"))]}
        """
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(json.utf8))
        #expect(s.customRules.map(\.name) == ["A", "B"])
    }

    @Test func missingActionsDefaultButUnreadableActionsSkipTheRule() throws {
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data("{\"customRules\":[\(goodRuleJSON(UUID().uuidString))]}".utf8))
        #expect(s.customRules.first?.actions == [.showNotification])
    }

    @Test func customRulesOfWrongTypeGiveEmptyListAndKeepTheRestOfTheSettings() throws {
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"customRules":"x","processCPUThreshold":77}"#.utf8))
        #expect(s.customRules.isEmpty)
        #expect(s.processCPUThreshold == 77)
    }

    @Test func everyBuiltInRuleIsInExactlyOneGroup() {
        let listed = RuleGroup.allCases.flatMap(\.rules)
        #expect(listed.count == 17)
        #expect(Set(listed) == Set(RuleID.allCases))
    }

    @Test func resettingOneGroupLeavesTheOthers() {
        var s = MonitorSettings()
        s.processCPUThreshold = 50; s.enabledRules.remove(.memoryHog); s.memoryHogFraction = 0.5
        s.cpuTempThreshold = 70; s.ssdWearPercent = 50; s.enabledRules.insert(.gpuHigh)
        s.reset(.processes)
        let d = MonitorSettings()
        #expect(s.processCPUThreshold == d.processCPUThreshold)
        #expect(s.memoryHogFraction == d.memoryHogFraction)
        #expect(s.isEnabled(.memoryHog))
        #expect(s.cpuTempThreshold == 70)
        #expect(s.ssdWearPercent == 50)
        s.reset(.system)
        #expect(s.cpuTempThreshold == d.cpuTempThreshold)
        #expect(!s.isEnabled(.gpuHigh))
        #expect(s.ssdWearPercent == 50)
    }

    @Test func resettingEverythingEqualsTheDefaults() {
        var s = MonitorSettings()
        s.processCPUThreshold = 1; s.processCPUSustain = 1; s.memoryHogFraction = 1; s.memoryHogSustain = 1
        s.cpuTotalThreshold = 1; s.cpuTotalSustain = 1; s.memoryPressureSustain = 1; s.swapThresholdGB = 1
        s.diskMinFreePercent = 1; s.diskMinFreeGB = 1; s.networkOfflineSustain = 1; s.sleepBlockerSustain = 1
        s.cpuTempThreshold = 1; s.cpuTempSustain = 1; s.fanMaxPercent = 1; s.fanMaxSustain = 1
        s.batteryHealthMinPercent = 1; s.batteryDrainSustain = 1; s.energyHogWatts = 1; s.energyHogSustain = 1
        s.ssdWearPercent = 1; s.ssdSpareMinPercent = 1; s.gpuHighThreshold = 1; s.gpuHighSustain = 1
        s.enabledRules = []
        for g in RuleGroup.allCases { s.reset(g) }
        #expect(s == MonitorSettings())
    }
}

@Suite struct SettingsTransferTests {
    @Test func roundTrip() throws {
        var s = MonitorSettings()
        s.processCPUThreshold = 70
        s.enabledRules.remove(.swap)
        s.menuBarItems = [.cpu, .temperature]
        s.ignoredProcesses = ["a", "b"]
        s.quiet.quietHoursEnabled = true
        s.quiet.quietHoursStart = 23 * 60
        s.hotKeys.openDashboard = HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.control | HotKeyBinding.option)
        s.customRules = CustomRule.templates.map { $0.instantiated() }
        let data = try SettingsTransfer.export(s, date: t0)
        let back = try SettingsTransfer.importSettings(from: data)
        #expect(back.settings == s)
        #expect(back.skippedRules == 0)
        #expect(String(decoding: data, as: UTF8.self).contains("macmonitor-settings"))
    }

    @Test func importDropsInvalidAndUnreadableRules() throws {
        var s = MonitorSettings()
        var bad = CustomRule.templates[0].instantiated()
        bad.threshold = -5
        s.customRules = [CustomRule.templates[1].instantiated(), bad]
        var text = String(decoding: try SettingsTransfer.export(s), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"customRules\" : [", with: "\"customRules\" : [ {\"unsinn\":1},")
        let back = try SettingsTransfer.importSettings(from: Data(text.utf8))
        #expect(back.settings.customRules.count == 1)
        #expect(back.skippedRules == 2)
    }

    @Test func foreignAndBrokenFilesAreRejected() {
        #expect(throws: SettingsTransfer.ImportError.notReadable) { try SettingsTransfer.importSettings(from: Data("nein".utf8)) }
        #expect(throws: SettingsTransfer.ImportError.wrongFormat) { try SettingsTransfer.importSettings(from: Data(#"{"a":1}"#.utf8)) }
        #expect(throws: SettingsTransfer.ImportError.wrongFormat) {
            try SettingsTransfer.importSettings(from: Data(#"{"format":"macmonitor-settings","version":1}"#.utf8))
        }
        #expect(throws: SettingsTransfer.ImportError.newerVersion(9)) {
            try SettingsTransfer.importSettings(from: Data(#"{"format":"macmonitor-settings","version":9,"settings":{}}"#.utf8))
        }
    }
}

// MARK: - Hot keys

@Suite struct HotKeyTests {
    @Test func needsAModifierThatIsNotOnlyShift() {
        #expect(HotKeyBinding(keyCode: 2, modifiers: 0).validate() == .needsModifier)
        #expect(HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.shift).validate() == .needsModifier)
        #expect(HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.control | HotKeyBinding.option).validate() == nil)
    }

    @Test func reservedCombinationsAreRefused() {
        #expect(HotKeyBinding(keyCode: 12, modifiers: HotKeyBinding.command).validate() == .reserved("⌘Q"))
        #expect(HotKeyBinding(keyCode: 49, modifiers: HotKeyBinding.command).validate() == .reserved("⌘Leertaste"))
        #expect(HotKeyBinding(keyCode: 200, modifiers: HotKeyBinding.command).validate() == .unknownKey)
    }

    @Test func conflictsBetweenOurOwnShortcuts() {
        let b = HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.control | HotKeyBinding.option)
        var s = HotKeySettings()
        s.openDashboard = b
        #expect(s.conflict(for: b, excluding: .openOverview) == .openDashboard)
        #expect(s.conflict(for: b, excluding: .openDashboard) == nil)
        #expect(HotKeySettings().isEmpty)
    }

    @Test func symbolsAndNamesAndMessages() {
        let b = HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.command | HotKeyBinding.shift | HotKeyBinding.control)
        #expect(b.modifierSymbols == "⌃⇧⌘")
        #expect(HotKeyBinding.specialKeyName(49) == "Leertaste")
        #expect(HotKeyBinding.specialKeyName(2) == nil)
        #expect(HotKeyBinding.Problem.reserved("⌘Q").message.contains("⌘Q"))
    }

    @Test func noShortcutIsSetByDefaultAndOldSettingsLoad() throws {
        #expect(MonitorSettings().hotKeys.isEmpty)
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"hotKeys":{"openPopover":{"keyCode":2,"modifiers":2304},"openOverview":"kaputt"}}"#.utf8))
        #expect(s.hotKeys.openPopover?.keyCode == 2)
        #expect(s.hotKeys.openOverview == nil)
    }
}
