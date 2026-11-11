import Foundation
import MonitorCore

/// Gives the Shortcuts intents a current snapshot. If the running app measured within the last
/// `maxAge` seconds, that is used; otherwise (app just started by the intent, or sampling paused)
/// the reader takes its own one-off measurement instead of waiting for the next tick.
@MainActor
enum SystemReader {
    struct Reading {
        let snapshot: SystemSnapshot
        let conditions: [Condition]
        /// True when the values come from a measurement made just now for the intent.
        let measuredNow: Bool
    }

    static func current(maxAge: TimeInterval = 15) async -> Reading {
        if let model = AppIntegration.model, let snapshot = model.snapshot,
           Date().timeIntervalSince(snapshot.date) <= maxAge {
            return Reading(snapshot: snapshot, conditions: model.reported, measuredNow: false)
        }
        let snapshot = await measureOnce()
        // Without a running engine there is no "lasted long enough"; the plain rule result is reported.
        let conditions = Rules.evaluate(snapshot, Rules.Context(settings: SettingsStore.load()))
        return Reading(snapshot: snapshot, conditions: conditions, measuredNow: true)
    }

    /// One fresh measurement: the first sample only primes the CPU and process deltas, so a second
    /// one follows a second later. Runs off the main thread.
    nonisolated static func measureOnce(interval: TimeInterval = 1) async -> SystemSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let sampler = Sampler()
                _ = sampler.collect(isOnline: true)
                Thread.sleep(forTimeInterval: interval)
                continuation.resume(returning: sampler.collect(isOnline: true))
            }
        }
    }
}
