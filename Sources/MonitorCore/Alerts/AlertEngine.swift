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

    public init(reminderInterval: TimeInterval = 1800) {
        self.reminderInterval = reminderInterval
    }

    public func isActive(_ key: String) -> Bool { tracks[key] != nil }

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
                } else if now.timeIntervalSince(firedAt) >= reminderInterval {
                    events.append(AlertEvent(date: now, kind: .reminder, condition: condition))
                    track.firedAt = now
                }
            } else if now.timeIntervalSince(track.since) >= condition.sustain {
                events.append(AlertEvent(date: now, kind: .fired, condition: condition))
                track.firedAt = now
                track.firedSeverity = condition.severity
            }
            tracks[condition.key] = track
        }

        for (key, track) in tracks where !seen.contains(key) {
            tracks[key] = nil
            if track.firedAt != nil {
                events.append(AlertEvent(date: now, kind: .resolved, condition: track.condition))
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
