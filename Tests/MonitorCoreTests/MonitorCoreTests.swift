import Foundation
import Testing
@testable import MonitorCore

private let gb: UInt64 = 1_073_741_824

private func snapshot(
    cpu: Double = 10,
    used: UInt64 = 8 * gb,
    pressure: MemoryPressure = .normal,
    swap: UInt64 = 0,
    thermal: ThermalLevel = .nominal,
    disk: DiskStat? = DiskStat(availableBytes: 200 * gb, totalBytes: 1000 * gb),
    online: Bool = true,
    processes: [ProcessStat] = []
) -> SystemSnapshot {
    SystemSnapshot(date: .now, cpuPercent: cpu, memoryUsedBytes: used, memoryTotalBytes: 24 * gb,
                   memoryPressure: pressure, swapUsedBytes: swap, thermal: thermal, disk: disk,
                   isOnline: online, power: .unknown, processes: processes)
}

private func condition(_ key: String, sustain: TimeInterval = 60, severity: Severity = .warning) -> Condition {
    Condition(key: key, rule: .cpuHigh, severity: severity, title: key, body: "", sustain: sustain)
}

@Suite struct AlertEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func waitsForSustainBeforeFiring() {
        var engine = AlertEngine()
        #expect(engine.process([condition("a")], now: t0).isEmpty)
        #expect(engine.process([condition("a")], now: t0 + 30).isEmpty)
        let events = engine.process([condition("a")], now: t0 + 60)
        #expect(events.map(\.kind) == [.fired])
        #expect(engine.reported.map(\.key) == ["a"])
    }

    @Test func interruptionRestartsSustain() {
        var engine = AlertEngine()
        _ = engine.process([condition("a")], now: t0)
        _ = engine.process([], now: t0 + 40)
        #expect(engine.process([condition("a")], now: t0 + 70).isEmpty)
        #expect(engine.process([condition("a")], now: t0 + 130).map(\.kind) == [.fired])
    }

    @Test func zeroSustainFiresImmediately() {
        var engine = AlertEngine()
        #expect(engine.process([condition("a", sustain: 0)], now: t0).map(\.kind) == [.fired])
    }

    @Test func staysQuietUntilReminder() {
        var engine = AlertEngine(reminderInterval: 600)
        _ = engine.process([condition("a", sustain: 0)], now: t0)
        #expect(engine.process([condition("a", sustain: 0)], now: t0 + 300).isEmpty)
        #expect(engine.process([condition("a", sustain: 0)], now: t0 + 600).map(\.kind) == [.reminder])
    }

    @Test func escalationFiresAgain() {
        var engine = AlertEngine()
        _ = engine.process([condition("p", sustain: 0)], now: t0)
        let events = engine.process([condition("p", sustain: 0, severity: .critical)], now: t0 + 10)
        #expect(events.map(\.kind) == [.escalated])
    }

    @Test func resolvedOnlyForReportedConditions() {
        var engine = AlertEngine()
        _ = engine.process([condition("fired", sustain: 0), condition("pending")], now: t0)
        let events = engine.process([], now: t0 + 10)
        #expect(events.map(\.kind) == [.resolved])
        #expect(events.first?.condition.key == "fired")
        #expect(!engine.isActive("pending"))
    }

    @Test func resetPendingKeepsReported() {
        var engine = AlertEngine()
        _ = engine.process([condition("fired", sustain: 0), condition("pending")], now: t0)
        engine.resetPending()
        #expect(engine.isActive("fired"))
        #expect(!engine.isActive("pending"))
    }

    @Test func duplicateKeysCountOnce() {
        var engine = AlertEngine()
        let events = engine.process([condition("a", sustain: 0), condition("a", sustain: 0)], now: t0)
        #expect(events.count == 1)
    }
}

@Suite struct RulesTests {
    let settings = MonitorSettings()

    @Test func quietSystemHasNoConditions() {
        #expect(Rules.evaluate(snapshot(), .init(settings: settings)).isEmpty)
    }

    @Test func runawayProcessUsesThresholdAndHysteresis() {
        let hot = ProcessStat(pid: 42, name: "node", cpuPercent: 80, footprintBytes: gb)
        let s = snapshot(processes: [hot])
        #expect(Rules.evaluate(s, .init(settings: settings)).isEmpty)
        let active = Rules.evaluate(s, .init(settings: settings, isActive: { $0 == "process.cpu.42" }))
        #expect(active.map(\.key) == ["process.cpu.42"])
        #expect(active.first?.process == ProcessRef(pid: 42, name: "node"))
    }

    @Test func ignoredAndMutedProcessesAreSkipped() {
        let procs = [
            ProcessStat(pid: 1, name: "kernel_task", cpuPercent: 300, footprintBytes: 0),
            ProcessStat(pid: 2, name: "Xcode", cpuPercent: 300, footprintBytes: 0),
        ]
        let conds = Rules.evaluate(snapshot(processes: procs), .init(settings: settings, mutedProcesses: ["Xcode"]))
        #expect(conds.isEmpty)
    }

    @Test func memoryHogFromShareOfRAM() {
        let hog = ProcessStat(pid: 7, name: "Chrome", cpuPercent: 1, footprintBytes: 7 * gb)
        let conds = Rules.evaluate(snapshot(processes: [hog]), .init(settings: settings))
        #expect(conds.map(\.rule) == [.memoryHog])
    }

    @Test func memoryPressureCriticalIsImmediate() {
        let warn = Rules.evaluate(snapshot(pressure: .warning), .init(settings: settings))
        #expect(warn.first?.sustain == settings.memoryPressureSustain)
        let crit = Rules.evaluate(snapshot(pressure: .critical), .init(settings: settings))
        #expect(crit.first?.severity == .critical)
        #expect(crit.first?.sustain == 0)
    }

    @Test func diskLowByPercentOrAbsolute() {
        let low = DiskStat(availableBytes: 12 * gb, totalBytes: 1000 * gb)
        #expect(Rules.evaluate(snapshot(disk: low), .init(settings: settings)).map(\.rule) == [.disk])
        // 16 GB free is above the 15 GB limit but still counts while the condition is active.
        let recovering = DiskStat(availableBytes: 16 * gb, totalBytes: 100 * gb)
        let ctx = Rules.Context(settings: settings, isActive: { $0 == "system.disk" })
        #expect(Rules.evaluate(snapshot(disk: recovering), ctx).map(\.rule) == [.disk])
    }

    @Test func disabledRulesStaySilent() {
        var s = settings
        s.enabledRules = []
        let conds = Rules.evaluate(snapshot(cpu: 100, pressure: .critical, thermal: .critical, online: false), .init(settings: s))
        #expect(conds.isEmpty)
    }

    @Test func offlineWaitsForSustain() {
        let conds = Rules.evaluate(snapshot(online: false), .init(settings: settings))
        #expect(conds.map(\.key) == ["system.network"])
        #expect(conds.first?.sustain == 30)
    }
}

@Suite struct MetricsTests {
    @Test func cpuUsageFromTicks() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        #expect(CPUTicks.usage(from: a, to: b) == 15)
        #expect(CPUTicks.usage(from: b, to: a) == 0)
    }

    @Test func processTrackerDiffsAndDetectsPIDReuse() {
        var tracker = ProcessCPUTracker()
        let first = [ProcessReading(pid: 5, startTime: 1, cpuTimeNs: 0, footprintBytes: 0)]
        #expect(tracker.update(first, nowNs: 0).isEmpty)

        let second = [ProcessReading(pid: 5, startTime: 1, cpuTimeNs: 1_500_000_000, footprintBytes: 0)]
        #expect(tracker.update(second, nowNs: 1_000_000_000)[5] == 150)

        let reused = [ProcessReading(pid: 5, startTime: 2, cpuTimeNs: 9_000_000_000, footprintBytes: 0)]
        #expect(tracker.update(reused, nowNs: 2_000_000_000)[5] == nil)
    }

    @Test func ringBufferKeepsNewestInOrder() {
        var ring = RingBuffer<Int>(capacity: 3)
        (1...5).forEach { ring.append($0) }
        #expect(ring.elements == [3, 4, 5])
        #expect(ring.last == 5)
    }

    @Test func settingsDecodeToleratesMissingKeys() throws {
        let data = Data(#"{"processCPUThreshold": 120}"#.utf8)
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: data)
        #expect(decoded.processCPUThreshold == 120)
        #expect(decoded.swapThresholdGB == MonitorSettings().swapThresholdGB)
    }

    @Test func germanFormatting() {
        #expect(Format.bytes(12 * gb + gb / 2) == "12,5 GB")
        #expect(Format.duration(180) == "3 min")
        #expect(Format.duration(90) == "1 min 30 s")
    }

    @Test func liveSamplersReturnPlausibleValues() {
        let system = SystemSampler()
        _ = system.cpuPercent()
        #expect(system.memoryUsedBytes() > 0)
        #expect(system.memoryUsedBytes() <= system.memoryTotalBytes)
        let processes = ProcessSampler().sample()
        #expect(processes.contains { $0.pid == getpid() })
    }
}

@Suite struct SamplingPolicyTests {
    @Test func intervalsAdaptToContext() {
        let ac = PowerState(onBattery: false, batteryPercent: 100, lowPowerMode: false)
        let battery = PowerState(onBattery: true, batteryPercent: 50, lowPowerMode: false)
        let saver = PowerState(onBattery: true, batteryPercent: 10, lowPowerMode: true)
        #expect(SamplingPolicy.interval(popoverOpen: true, power: saver) == 2)
        #expect(SamplingPolicy.interval(popoverOpen: false, power: ac) == 10)
        #expect(SamplingPolicy.interval(popoverOpen: false, power: battery) == 20)
        #expect(SamplingPolicy.interval(popoverOpen: false, power: saver) == 30)
    }
}
