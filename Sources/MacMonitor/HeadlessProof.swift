import Foundation
import MonitorCore

/// `MacMonitor --headless-proof`: runs the real sampler against this Mac, feeds a temporary
/// history file and reads it back, then times a `collect` + `ingest` round. No windows, no
/// notifications, never touches the installed app's history.
@MainActor
enum HeadlessProof {
    static func run() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("macmonitor-proof-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        guard let store = try? HistoryStore(url: file, now: Date()) else { print("Store konnte nicht geöffnet werden"); return }

        // 1. Sampler -> MetricSample -> HistoryStore -> series
        let sampler = Sampler()
        sampler.detailsVisible = true
        _ = sampler.collect(isOnline: true)           // first call only primes the deltas
        let begin = Date()
        var last: SystemSnapshot?
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 1)
            let snapshot = sampler.collect(isOnline: true)
            last = snapshot
            let samples = MetricSample.samples(from: snapshot)
            blocking { await store.record(samples, at: snapshot.date) }
        }
        let end = Date().addingTimeInterval(1)
        print("== Echtlauf: 6 Messungen, Verlauf aus temporärer Datei gelesen ==")
        let keys = blocking { try! await store.metricKeys() }
        for key in keys {
            let points = blocking { try! await store.series(key, from: begin.addingTimeInterval(-60), to: end, maxPoints: 120) }
            let total = points.reduce(0) { $0 + $1.count }
            let avg = total > 0 ? points.reduce(0.0) { $0 + $1.avg * Double($1.count) } / Double(total) : 0
            let lo = points.map(\.min).min() ?? 0, hi = points.map(\.max).max() ?? 0
            print(String(format: "%-16@ Punkte %d  Messungen %d  min %.2f  Ø %.2f  max %.2f", key.rawValue as NSString,
                         points.count, total, lo, avg, hi))
        }
        if let s = last {
            print("Snapshot: GPU \(s.gpu.map { "\(Int($0.utilizationPercent)) %" } ?? "nil"), Temp \(s.thermals?.cpuAverageCelsius.map { "\(Int($0)) °C" } ?? "nil"), "
                  + "Leistung \(s.powerDraw?.systemWatts.map { "\($0) W" } ?? "nil"), Lüfter \(s.fans.count), Akku \(s.power.batteryPercent.map { "\($0) %" } ?? "nil"), "
                  + "Volumes \(s.volumes.count), Prozesse \(s.processes.count)")
        }

        // 2. Cost of one tick with closed windows (detailsVisible = false)
        let quiet = Sampler()
        quiet.detailsVisible = false
        let cold0 = Date()
        _ = quiet.collect(isOnline: true)
        let cold = Date().timeIntervalSince(cold0)
        _ = quiet.collect(isOnline: true)
        let model = AppModel(settings: MonitorSettings())
        let timed = try! HistoryStore(url: file.deletingLastPathComponent().appendingPathComponent("macmonitor-proof2-\(UUID().uuidString).sqlite"), now: Date())
        model.useHistory(timed)
        let runs = 200
        var snapshots: [SystemSnapshot] = []
        var collectTotal = 0.0, collectMax = 0.0
        for _ in 0..<runs {
            let c0 = Date()
            snapshots.append(quiet.collect(isOnline: true))
            let c = Date().timeIntervalSince(c0)
            collectTotal += c
            collectMax = max(collectMax, c)
        }
        let i0 = Date()
        for snapshot in snapshots { model.ingest(snapshot) }
        let ingest = Date().timeIntervalSince(i0)
        model.history?.flushAndWait(timeout: 30)
        // The same work the background pipeline does, timed in isolation.
        let direct = try! HistoryStore(path: ":memory:", now: Date())
        let p0 = Date()
        let frozen = snapshots
        blocking {
            for s in frozen {
                await direct.record(MetricSample.samples(from: s), at: s.date)
                let usages = ProcessUsage.usages(from: s) { $0.appName.isEmpty ? $0.name : $0.appName }
                await direct.recordProcesses(usages, at: s.date, interval: 10)
            }
        }
        let pipeline = Date().timeIntervalSince(p0)
        // One tick on which the 30 s sensor cache (HID temperatures, SMC fans, IOReport power) has expired.
        Thread.sleep(forTimeInterval: 31)
        let sensor0 = Date()
        _ = quiet.collect(isOnline: true)
        let sensorTick = Date().timeIntervalSince(sensor0)
        print("== Ruhelast (Fenster zu), \(runs) Läufe ==")
        print(String(format: "collect kalt (alle Caches leer): %.1f ms", cold * 1000))
        print(String(format: "collect warm (Sensoren aus dem Cache) Mittel: %.2f ms, Max: %.2f ms", collectTotal / Double(runs) * 1000, collectMax * 1000))
        print(String(format: "collect im Tick, in dem das 30-s-Sensorraster abläuft: %.1f ms", sensorTick * 1000))
        print(String(format: "ingest auf dem Hauptthread inkl. Regeln und Übergabe an History, Mittel: %.3f ms", ingest / Double(runs) * 1000))
        print(String(format: "History im Hintergrund (Abbilden + record + recordProcesses), Mittel: %.3f ms", pipeline / Double(runs) * 1000))
        try? FileManager.default.removeItem(atPath: timed.path)
    }

    /// Runs an async body to completion from synchronous main-thread code.
    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            result = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}
