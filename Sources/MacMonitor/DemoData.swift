import Foundation
import MonitorCore

/// An in-memory `HistoryStore` with 30 days of plausible, deterministic data: a workday rhythm,
/// a Mac that sleeps at night and a few incidents.
enum DemoHistory {
    static func make(now: Date = Date()) -> HistoryStore {
        // The store is an actor: fill it from a background task and wait here (offline renderer only).
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: HistoryStore?
        Task.detached {
            let store = try! HistoryStore(path: ":memory:", now: now.addingTimeInterval(-30 * 86_400))
            await fill(store, now: now)
            result = store
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }

    private static func noise(_ i: Int, _ salt: Int) -> Double {
        let v = sin(Double(i * 7919 + salt * 104_729)) * 43_758.5453
        return v - v.rounded(.down)
    }

    private static func fill(_ store: HistoryStore, now: Date) async {
        let calendar = Calendar.current
        let gb = 1_073_741_824.0
        let start = now.addingTimeInterval(-30 * 86_400)
        let fine = now.addingTimeInterval(-48 * 3600)
        var t = start
        var i = 0
        var lastCompact = start
        while t < now {
            let step: TimeInterval = t < fine ? 300 : 60
            defer { t = t.addingTimeInterval(step); i += 1 }
            let hour = Double(calendar.component(.hour, from: t)) + Double(calendar.component(.minute, from: t)) / 60
            // Asleep from 23:30 to 07:30; a short nap at lunch on some days.
            let day = calendar.ordinality(of: .day, in: .era, for: t) ?? 0
            if hour >= 23.5 || hour < 7.5 { continue }
            if day % 3 == 0 && hour >= 13.0 && hour < 13.7 { continue }
            let work = max(0, sin((hour - 7.5) / 16 * .pi))            // 0 … 1 over the day
            let burst = noise(i / 6, 1) > 0.86 ? 35 + noise(i, 2) * 30 : 0
            let cpu = min(98, 8 + 30 * work + burst + noise(i, 3) * 9)
            let mem = 55 + 17 * work + 4 * sin(Double(day) / 2.3) + noise(i / 12, 4) * 3
            let pressure = mem > 71 ? 1.0 : 0.0
            let temp = 36 + 0.34 * cpu + noise(i, 5) * 3
            let power = 5 + 0.2 * cpu + noise(i, 6) * 2
            let battery = max(8, 97 - (hour - 7.5) * 3.2 - noise(i / 30, 7) * 2)
            let samples: [MetricSample] = [
                MetricSample(.cpuTotal, cpu),
                MetricSample(.cpuEfficiency, cpu * 0.35),
                MetricSample(.cpuPerformance, min(100, cpu * 1.3)),
                MetricSample(.gpuPercent, max(0, 4 + 22 * work * noise(i / 3, 8) + noise(i, 9) * 5)),
                MetricSample(.gpuMemory, (0.9 + 1.4 * work) * gb),
                MetricSample(.memoryUsed, mem / 100 * 24 * gb),
                MetricSample(.memoryPercent, mem),
                MetricSample(.memoryPressure, pressure),
                MetricSample(.memoryUnderPressure, pressure),
                MetricSample(.swapUsed, (0.3 + 2.4 * max(0, mem - 62) / 12) * gb),
                MetricSample(.thermalLevel, 0),
                MetricSample(.cpuTempAvg, temp),
                MetricSample(.cpuTempMax, temp + 8 + noise(i, 10) * 6),
                MetricSample(.batteryTemp, 29 + 4 * work + noise(i, 11)),
                MetricSample(.powerSystem, power),
                MetricSample(.powerCPU, power * 0.45),
                MetricSample(.powerGPU, power * 0.15),
                MetricSample(.fanMax, temp > 55 ? 1800 + (temp - 55) * 160 : 0 + 1200),
                MetricSample(.diskRead, noise(i, 12) * noise(i, 13) * 9_000_000),
                MetricSample(.diskWrite, noise(i, 14) * noise(i, 15) * 3_500_000),
                MetricSample(.load1, 0.6 + cpu / 100 * 6 + noise(i, 16)),
                MetricSample(.netDown, noise(i, 17) * noise(i, 18) * 6_000_000 * (0.3 + work)),
                MetricSample(.netUp, noise(i, 19) * noise(i, 20) * 700_000 * (0.3 + work)),
                MetricSample(.batteryPercent, battery),
                MetricSample(.diskFree, (330 - Double(day % 30) * 0.4) * gb),
            ]
            await store.record(samples, at: t)
            await store.recordProcesses([
                ProcessUsage(group: "Xcode", cpuPercent: 8 + 40 * work * noise(i / 8, 21), footprintBytes: UInt64(2.8 * gb)),
                ProcessUsage(group: "Google Chrome", cpuPercent: 4 + 25 * work * noise(i / 5, 22), footprintBytes: UInt64(4.1 * gb)),
                ProcessUsage(group: "Docker", cpuPercent: 3 + 12 * work, footprintBytes: UInt64(4.0 * gb)),
                ProcessUsage(group: "node", cpuPercent: burst * 1.6, footprintBytes: UInt64(1.2 * gb)),
                ProcessUsage(group: "Claude", cpuPercent: 2 + 6 * work * noise(i / 4, 23), footprintBytes: UInt64(0.9 * gb)),
                ProcessUsage(group: "Finder", cpuPercent: 0.8, footprintBytes: UInt64(0.3 * gb)),
            ], at: t, interval: step)
            if t.timeIntervalSince(lastCompact) > 6 * 3600 {
                lastCompact = t
                try? await store.compact(now: t)
            }
        }
        // A few incidents in the past week, one still open.
        func condition(_ key: String, _ rule: RuleID, _ severity: Severity, _ title: String, _ process: ProcessRef? = nil) -> Condition {
            Condition(key: key, rule: rule, severity: severity, title: title, body: "", sustain: 0, process: process)
        }
        let node = ProcessRef(pid: 4182, name: "node")
        let incidents: [(TimeInterval, TimeInterval?, Condition)] = [
            (-6.2 * 86_400, 1500, condition("process.cpu.node", .runawayProcess, .warning, String(localized: "\("node") hängt bei \(Format.percent(100)) CPU"), node)),
            (-4.1 * 86_400, 2700, condition("system.memory", .memoryPressure, .warning, String(localized: "Speicherdruck erhöht"))),
            (-3.4 * 86_400, 620, condition("system.network", .network, .warning, String(localized: "Keine Internetverbindung"))),
            (-1.8 * 86_400, 4100, condition("system.memory", .memoryPressure, .critical, String(localized: "Speicherdruck kritisch"))),
            (-0.9 * 86_400, 900, condition("process.cpu.node", .runawayProcess, .warning, String(localized: "\("node") hängt bei \(Format.percent(100)) CPU"), node)),
            (-0.1 * 86_400, nil, condition("system.memory", .memoryPressure, .warning, String(localized: "Speicherdruck erhöht"))),
        ]
        for (offset, length, c) in incidents {
            let begin = now.addingTimeInterval(offset)
            await store.record(AlertEvent(date: begin, kind: .fired, condition: c))
            if let length { await store.record(AlertEvent(date: begin.addingTimeInterval(length), kind: .resolved, condition: c)) }
        }
        try? await store.compact(now: now)
        try? await store.flush()
    }
}
