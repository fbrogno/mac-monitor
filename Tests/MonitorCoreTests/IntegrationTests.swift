import Foundation
import Testing
@testable import MonitorCore

private let gb: UInt64 = 1_073_741_824

private func sample(date: Date = Date(), cpu: Double = 20, used: UInt64 = 12 * gb, processes: [ProcessStat] = []) -> SystemSnapshot {
    SystemSnapshot(
        date: date, cpuPercent: cpu, memoryUsedBytes: used, memoryTotalBytes: 24 * gb,
        memoryPressure: .normal, swapUsedBytes: 0, thermal: .nominal,
        disk: DiskStat(availableBytes: 300 * gb, totalBytes: 1000 * gb), isOnline: true,
        power: PowerState(onBattery: true, batteryPercent: 80, lowPowerMode: false, minutesRemaining: 200),
        processes: processes,
        gpu: GPUStat(utilizationPercent: 9),
        thermals: ThermalSensors(cpuAverageCelsius: 45, cpuMaxCelsius: 50, batteryCelsius: nil, sensors: []),
        powerDraw: SystemPowerDraw(systemWatts: 11.3))
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct WidgetSnapshotTests {
    @Test func roundtripKeepsEveryField() throws {
        let condition = Condition(key: "system.memory", rule: .memoryPressure, severity: .warning,
                                  title: "Speicher knapp", body: "", sustain: 0)
        let full = WidgetSnapshot(snapshot: sample(date: Date(timeIntervalSince1970: 1_800_000_000.123)), conditions: [condition])
            .appending(to: nil)
        let store = WidgetStore(directory: tempDirectory())
        try store.write(full)
        let read = try #require(store.read())
        #expect(read == full)
        #expect(read.anomalies.first?.title == "Speicher knapp")
        #expect(read.gpuPercent == 9)
        #expect(read.battery?.percent == 80)
        #expect(read.cpuSeries == [20])
    }

    @Test func missingOrBrokenOrForeignVersionFileReadsAsNil() throws {
        let store = WidgetStore(directory: tempDirectory())
        #expect(store.read() == nil)
        try Data("{ kaputt".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)
        var future = WidgetSnapshot(snapshot: sample(), conditions: [])
        future.version = WidgetSnapshot.currentVersion + 1
        try store.write(future)
        #expect(store.read() == nil)
    }

    @Test func staleFileIsNotShownAsCurrent() {
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        let old = WidgetSnapshot(snapshot: sample(date: seen), conditions: [])
        #expect(WidgetContent.resolve(old, at: seen.addingTimeInterval(60)) == .live(old))
        let late = seen.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
        #expect(WidgetContent.resolve(old, at: late) == .stale(lastSeen: seen, snapshot: old))
        #expect(WidgetContent.resolve(nil, at: late) == .noData)
    }

    @Test func seriesKeepsTheLastHourOnly() {
        var current: WidgetSnapshot?
        for i in 0..<75 {
            current = WidgetSnapshot(snapshot: sample(cpu: Double(i)), conditions: []).appending(to: current)
        }
        let series = current?.cpuSeries ?? []
        #expect(series.count == WidgetSnapshot.seriesLength)
        #expect(series.last == 74)
        #expect(series.first == 15)
    }

    @Test func visibleChangeNeedsMoreThanNoise() {
        let base = WidgetSnapshot(snapshot: sample(cpu: 20), conditions: [])
        #expect(!WidgetSnapshot(snapshot: sample(cpu: 21), conditions: []).isVisiblyDifferent(from: base))
        #expect(WidgetSnapshot(snapshot: sample(cpu: 30), conditions: []).isVisiblyDifferent(from: base))
        let alert = Condition(key: "k", rule: .memoryPressure, severity: .warning, title: "t", body: "", sustain: 0)
        #expect(WidgetSnapshot(snapshot: sample(cpu: 20), conditions: [alert]).isVisiblyDifferent(from: base))
    }

    @Test func groupIdentifierIsAbsentWithoutEntitlement() {
        // The test runner has no App-Groups entitlement; the lookup must fail softly.
        #expect(WidgetStore.ownGroupIdentifier() == nil)
        #expect(WidgetStore.shared() == nil)
    }
}

struct PauseStateTests {
    private func state() -> PauseState {
        PauseState(defaults: UserDefaults(suiteName: "pause-test-\(UUID().uuidString)")!)
    }

    @Test func pauseEndsAtTheGivenTime() {
        let pause = state()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!pause.isPaused(at: now))
        let end = pause.pause(for: 3600, from: now)
        #expect(end == now.addingTimeInterval(3600))
        #expect(pause.isPaused(at: now.addingTimeInterval(3599)))
        #expect(!pause.isPaused(at: now.addingTimeInterval(3601)))
    }

    @Test func resumeAndZeroDurationLiftThePause() {
        let pause = state()
        pause.pause(for: 600)
        #expect(pause.isPaused())
        pause.resume()
        #expect(!pause.isPaused() && pause.until == nil)
        pause.pause(for: 600)
        #expect(pause.pause(for: 0) == nil)
        #expect(!pause.isPaused())
    }
}

struct ConsumerRankingTests {
    private let processes = [
        ProcessStat(pid: 1, name: "Chrome", cpuPercent: 10, footprintBytes: 2 * gb, energyMilliwatts: 500, appKey: "app:/Chrome.app", appName: "Chrome"),
        ProcessStat(pid: 2, name: "Chrome Helper", cpuPercent: 15, footprintBytes: 3 * gb, energyMilliwatts: 500, appKey: "app:/Chrome.app", appName: "Chrome"),
        ProcessStat(pid: 3, name: "node", cpuPercent: 40, footprintBytes: 1 * gb, energyMilliwatts: 100, appKey: "proc:3", appName: "node"),
        ProcessStat(pid: 4, name: "Xcode", cpuPercent: 5, footprintBytes: 8 * gb, energyMilliwatts: 2000, appKey: "app:/Xcode.app", appName: "Xcode"),
    ]

    @Test func ranksByEachMetricWithHelpersSummed() {
        let s = sample(processes: processes)
        #expect(ConsumerRanking.top(s, by: .cpu, limit: 2).map(\.name) == ["node", "Chrome"])
        #expect(ConsumerRanking.top(s, by: .memory, limit: 1).map(\.name) == ["Xcode"])
        #expect(ConsumerRanking.top(s, by: .energy, limit: 3).map(\.name) == ["Xcode", "Chrome", "node"])
        #expect(ConsumerRanking.top(s, by: .cpu, limit: 0).isEmpty)
        #expect(ConsumerRanking.top(s, by: .cpu, limit: 10).count == 3)
    }

    @Test func summaryCarriesTheCoreValues() {
        let summary = StatusSummary(sample(), anomalyCount: 2)
        #expect(summary.cpuPercent == 20 && summary.memoryPercent == 50)
        #expect(summary.gpuPercent == 9 && summary.temperatureCelsius == 45 && summary.powerWatts == 11.3)
        #expect(summary.batteryPercent == 80 && summary.freeDiskBytes == 300 * gb && summary.anomalyCount == 2)
    }
}
