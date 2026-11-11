import Foundation

/// Decides which conditions become notifications:
/// - a condition must hold for its `sustain` duration without interruption,
/// - once reported it stays quiet until it clears, escalates in severity,
///   or `reminderInterval` has passed,
/// - clearing a reported condition yields a `.resolved` event.
public struct AlertEngine: Sendable {
    struct Track: Sendable {
        var since: Date
        var condition: Condition
        var firedAt: Date?
        var firedSeverity: Severity?
    }

    public var reminderInterval: TimeInterval
    private(set) var tracks: [String: Track] = [:]
    /// When conditions with their own (long) `reminderInterval` were last reported, by key. The engine lives in
    /// memory only; the app saves this small table and hands it back with `restore`, so a battery or SSD note
    /// is not repeated after every launch.
    public private(set) var lastReported: [String: Date] = [:]
    /// Upper bound of the table; only a handful of rules have their own interval.
    static let lastReportedLimit = 50

    public init(reminderInterval: TimeInterval = 1800) {
        self.reminderInterval = reminderInterval
    }

    public func isActive(_ key: String) -> Bool { tracks[key] != nil }

    /// Loads what an earlier run saved. Entries from the future (clock changes) and older than `maxAge` are dropped.
    public mutating func restore(lastReported saved: [String: Date], now: Date, maxAge: TimeInterval = 30 * 86_400) {
        lastReported = saved.filter { $0.value <= now && now.timeIntervalSince($0.value) <= maxAge }
        trimLastReported()
    }

    private mutating func noteReported(_ condition: Condition, at date: Date) {
        guard condition.reminderInterval != nil else { return }
        lastReported[condition.key] = date
        trimLastReported()
    }

    private mutating func trimLastReported() {
        guard lastReported.count > Self.lastReportedLimit else { return }
        let keep = lastReported.sorted { $0.value > $1.value }.prefix(Self.lastReportedLimit)
        lastReported = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// Conditions that have been reported and are still ongoing, most severe first.
    public var reported: [Condition] {
        tracks.values.filter { $0.firedAt != nil }
            .map(\.condition)
            .sorted { ($0.severity, $1.key) > ($1.severity, $0.key) }
    }

    public mutating func process(_ conditions: [Condition], now: Date) -> [AlertEvent] {
        var events: [AlertEvent] = []
        var seen = Set<String>()

        for condition in conditions where seen.insert(condition.key).inserted {
            var track = tracks[condition.key] ?? Track(since: now, condition: condition)
            track.condition = condition

            if let firedAt = track.firedAt, let firedSeverity = track.firedSeverity {
                if condition.severity > firedSeverity {
                    events.append(AlertEvent(date: now, kind: .escalated, condition: condition))
                    track.firedAt = now
                    track.firedSeverity = condition.severity
                    noteReported(condition, at: now)
                } else if now.timeIntervalSince(firedAt) >= (condition.reminderInterval ?? reminderInterval) {
                    events.append(AlertEvent(date: now, kind: .reminder, condition: condition))
                    track.firedAt = now
                    noteReported(condition, at: now)
                }
            } else if now.timeIntervalSince(track.since) >= condition.sustain {
                if let interval = condition.reminderInterval, let last = lastReported[condition.key],
                   last <= now, now.timeIntervalSince(last) < interval {
                    // Reported in an earlier run and not yet due again: carry on as already reported, without a notice.
                    track.firedAt = last
                    track.firedSeverity = condition.severity
                } else {
                    events.append(AlertEvent(date: now, kind: .fired, condition: condition))
                    track.firedAt = now
                    track.firedSeverity = condition.severity
                    noteReported(condition, at: now)
                }
            }
            tracks[condition.key] = track
        }

        for (key, track) in tracks where !seen.contains(key) {
            tracks[key] = nil
            if track.firedAt != nil {
                events.append(AlertEvent(date: now, kind: .resolved, condition: track.condition))
                // Gone and back later is news again.
                lastReported[key] = nil
            }
        }
        return events
    }

    /// Forget conditions that have not been reported yet, e.g. after waking from sleep,
    /// so time spent asleep does not count towards `sustain`.
    public mutating func resetPending() {
        tracks = tracks.filter { $0.value.firedAt != nil }
    }
}
