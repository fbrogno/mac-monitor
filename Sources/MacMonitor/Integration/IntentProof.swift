import Foundation
import MonitorCore

/// `MacMonitor --intent-proof`: runs the logic behind the Shortcuts intents without Shortcuts, Siri
/// or a running app: the one-off measurement (app not running), the texts, the pause state (in a
/// throw-away defaults suite) and the widget file (in a temporary folder).
/// Touches no real preferences and no group container.
@MainActor
enum IntentProof {
    static func run() {
        var finished = false
        Task { @MainActor in
            await proof()
            finished = true
        }
        while !finished { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    }

    private static func proof() async {
        print("== Kurzbefehle: Logik ohne laufende App ==")
        let start = Date()
        let reading = await SystemReader.current()
        print(String(format: "Messung: %.1f s, frisch gemessen: %@, Messzeit %.1f s alt",
                     Date().timeIntervalSince(start), reading.measuredNow ? "ja" : "nein",
                     Date().timeIntervalSince(reading.snapshot.date)))
        let summary = StatusSummary(reading.snapshot, anomalyCount: reading.conditions.count)
        print("Systemstatus:  \(IntentText.summary(summary))")
        let entity = SystemStatusEntity(summary)
        print("Entität:       CPU \(entity.cpuPercent) RAM \(entity.memoryPercent) GPU \(entity.gpuPercent.map(String.init(describing:)) ?? "nil") "
              + "Temp \(entity.temperatureCelsius.map(String.init(describing:)) ?? "nil") Leistung \(entity.powerWatts.map(String.init(describing:)) ?? "nil") "
              + "Akku \(entity.batteryPercent.map(String.init(describing:)) ?? "nil") frei \(entity.freeDiskGigabytes.map(String.init(describing:)) ?? "nil") GB "
              + "Auffälligkeiten \(entity.anomalyCount)")
        for metric in [ConsumerRanking.Metric.cpu, .memory, .energy] {
            let rows = ConsumerRanking.top(reading.snapshot, by: metric, limit: 3)
            print("Verbraucher \(metric): \(IntentText.consumers(rows, metric: metric))")
        }
        print("Auffälligkeiten: \(IntentText.anomalies(reading.conditions))")

        let suite = "macmonitor-intent-proof-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pause = PauseState(defaults: defaults)
        let end = pause.pause(for: 3600)
        print("Stumm:         \(end.map(IntentText.muted(until:)) ?? "-"), aktiv: \(pause.isPaused())")
        pause.resume()
        print("Aufgehoben:    aktiv: \(pause.isPaused())")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macmonitor-widget-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetStore(directory: dir)
        let file = WidgetSnapshot(snapshot: reading.snapshot, conditions: reading.conditions).appending(to: nil)
        try? store.write(file)
        let bytes = (try? Data(contentsOf: store.fileURL).count) ?? 0
        print("Widget-Datei:  \(bytes) Bytes, gelesen: \(store.read() == file ? "identisch" : "ABWEICHUNG")")
        let late = file.date.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
        print("Veraltet:      nach \(Int(WidgetSnapshot.staleAfter)) s -> \(String(describing: WidgetContent.resolve(file, at: late)).prefix(14))…")
    }
}
