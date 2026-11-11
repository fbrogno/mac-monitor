import Foundation
import MonitorCore
import WidgetKit

/// Everything that connects the running app to the outside: the file the desktop widgets read and
/// the latest values the Shortcuts intents answer from. AppModel only calls `didIngest`.
@MainActor
enum AppIntegration {
    private static var lastWritten: WidgetSnapshot?
    private static var lastWriteDate: Date?
    private static var lastKeys: Set<String> = []
    private static var store: WidgetStore? = WidgetStore.shared()
    private static var warned = false

    /// The model the intents read from; set by the first `didIngest`.
    private(set) static weak var model: AppModel?

    /// Called after every processed snapshot. Writes the widget file at most every 60 s (at once when
    /// an anomaly appears or resolves) and reloads widget timelines only if something visible changed.
    static func didIngest(_ model: AppModel) {
        self.model = model
        guard let snapshot = model.snapshot, let store else { return }
        let now = snapshot.date
        let keys = Set(model.reported.map(\.key))
        let anomaliesChanged = keys != lastKeys
        let due = lastWriteDate.map { now.timeIntervalSince($0) >= 60 } ?? true
        guard due || anomaliesChanged else { return }

        // After a restart carry on with the series of the file from before, if it is still recent.
        var previous = lastWritten
        if previous == nil, let old = store.read(), !old.isStale(at: now) { previous = old }

        var next = WidgetSnapshot(snapshot: snapshot, conditions: model.reported)
        if due {
            next = next.appending(to: previous)
        } else if let previous {
            // An extra write for an anomaly change must not add a point to the minute series.
            next.cpuSeries = previous.cpuSeries
            next.memorySeries = previous.memorySeries
            next.gpuSeries = previous.gpuSeries
        }
        do {
            try store.write(next)
        } catch {
            if !warned { warned = true; NSLog("MacMonitor: Widget-Datei nicht geschrieben: \(error)") }
            return
        }
        let reload = previous.map { next.isVisiblyDifferent(from: $0) || $0.isStale(at: now) } ?? true
        lastWritten = next
        lastKeys = keys
        if due { lastWriteDate = now }
        if reload { WidgetCenter.shared.reloadAllTimelines() }
    }
}
