import Foundation
import MonitorCore

/// Feeds the `HistoryStore` in order and off the main thread: `AppModel.ingest` only enqueues the
/// snapshot (a cheap value copy); mapping to metrics, grouping by app and the SQLite work happen here.
final class HistoryPipeline: Sendable {
    private enum Input: Sendable {
        case snapshot(SystemSnapshot, interval: TimeInterval)
        case event(AlertEvent)
        case flush(DispatchSemaphore?)
    }

    let store: HistoryStore
    private let input: AsyncStream<Input>.Continuation

    /// How often old data is rolled up and expired.
    static let compactEvery: TimeInterval = 600

    init(store: HistoryStore) {
        self.store = store
        let (stream, continuation) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        Task.detached(priority: .utility) {
            var lastCompact = Date.distantPast
            for await item in stream {
                switch item {
                case .snapshot(let snapshot, let interval):
                    await store.record(MetricSample.samples(from: snapshot), at: snapshot.date)
                    let usages = ProcessUsage.usages(from: snapshot) { $0.appName.isEmpty ? $0.name : $0.appName }
                    await store.recordProcesses(usages, at: snapshot.date, interval: interval)
                    if snapshot.date.timeIntervalSince(lastCompact) >= Self.compactEvery {
                        lastCompact = snapshot.date
                        try? await store.compact(now: snapshot.date)
                    }
                case .event(let event):
                    await store.record(event)
                case .flush(let done):
                    try? await store.flush()
                    done?.signal()
                }
            }
        }
    }

    /// `interval` is how many seconds this sample stands for (CPU seconds = percent × interval).
    func record(_ snapshot: SystemSnapshot, interval: TimeInterval) {
        input.yield(.snapshot(snapshot, interval: interval))
    }

    func record(_ event: AlertEvent) { input.yield(.event(event)) }

    /// Writes the buffered minute to disk (before sleep).
    func flush() { input.yield(.flush(nil)) }

    /// Writes everything buffered and waits at most `timeout` seconds, so quitting never hangs.
    @discardableResult
    func flushAndWait(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        input.yield(.flush(done))
        return done.wait(timeout: .now() + timeout) == .success
    }
}
