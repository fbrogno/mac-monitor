import Foundation

/// Day or week report as plain numbers and structures (no sentences). Built by pure functions
/// from query results, so it can be tested without a database.
public struct HistorySummary: Sendable, Equatable, Codable {
    public struct Stat: Sendable, Equatable, Codable {
        /// Weighted by the number of raw samples, not a mean of bucket means.
        public let avg: Double
        public let peak: Double

        public init(avg: Double, peak: Double) {
            self.avg = avg
            self.peak = peak
        }

        /// nil when the points hold no samples.
        public static func of(_ points: [HistoryPoint]) -> Stat? {
            let samples = points.reduce(0) { $0 + $1.count }
            guard samples > 0, let peak = points.filter({ $0.count > 0 }).map(\.max).max() else { return nil }
            let total = points.reduce(0.0) { $0 + $1.avg * Double($1.count) }
            return Stat(avg: total / Double(samples), peak: peak)
        }
    }

    public struct RuleIncidents: Sendable, Equatable, Codable {
        public let rule: String
        public let count: Int
        public let totalSeconds: TimeInterval
    }

    /// Absolute differences current minus previous. A field is nil when either period lacks it.
    public struct Delta: Sendable, Equatable, Codable {
        public let cpuAvg: Double?
        public let cpuPeak: Double?
        public let memoryAvg: Double?
        public let memoryPeak: Double?
        public let pressureSeconds: TimeInterval?
        public let incidentCount: Int
        public let incidentSeconds: TimeInterval
    }

    public enum Comparison: Sendable, Equatable, Codable {
        /// No previous period, or it holds no measurements.
        case noComparisonData
        case delta(Delta)
    }

    public let interval: DateInterval
    /// CPU, 0…100.
    public let cpu: Stat?
    /// Memory as percent of installed memory, 0…100.
    public let memory: Stat?
    /// Seconds spent at warning pressure or worse; nil without pressure data.
    public let pressureSeconds: TimeInterval?
    /// Incidents overlapping the period, by rule, most first.
    public let incidentsByRule: [RuleIncidents]
    public let incidentCount: Int
    /// Incident time inside the period, summed over all incidents.
    public let incidentSeconds: TimeInterval
    public let topProcesses: TopProcesses
    public let comparison: Comparison

    /// Pure aggregation. `pressure` is the `memory.underPressure` series (its average is the share
    /// of time under pressure); `now` closes still-open incidents.
    public static func make(interval: DateInterval, cpu: [HistoryPoint], memory: [HistoryPoint],
                            pressure: [HistoryPoint], incidents: [Incident],
                            topProcesses: TopProcesses, now: Date) -> HistorySummary {
        let pressureSeconds: TimeInterval? = pressure.contains { $0.count > 0 }
            ? pressure.reduce(0) { $0 + $1.avg * $1.span } : nil

        var perRule: [String: (count: Int, seconds: TimeInterval)] = [:]
        var totalSeconds: TimeInterval = 0
        var count = 0
        for incident in incidents {
            let end = incident.end ?? now
            let clippedStart = max(incident.start, interval.start)
            let clippedEnd = min(end, interval.end)
            guard incident.start < interval.end, end > interval.start else { continue }
            let seconds = max(0, clippedEnd.timeIntervalSince(clippedStart))
            perRule[incident.rule, default: (0, 0)].count += 1
            perRule[incident.rule, default: (0, 0)].seconds += seconds
            totalSeconds += seconds
            count += 1
        }
        let rules = perRule.map { RuleIncidents(rule: $0.key, count: $0.value.count, totalSeconds: $0.value.seconds) }
            .sorted { ($0.count, $1.rule) > ($1.count, $0.rule) }

        return HistorySummary(interval: interval, cpu: Stat.of(cpu), memory: Stat.of(memory),
                              pressureSeconds: pressureSeconds, incidentsByRule: rules,
                              incidentCount: count, incidentSeconds: totalSeconds,
                              topProcesses: topProcesses, comparison: .noComparisonData)
    }

    /// Adds the comparison to the previous period (absolute differences, never a ratio).
    public func comparing(to previous: HistorySummary?) -> HistorySummary {
        let comparison: Comparison
        if let previous, previous.cpu != nil || previous.memory != nil {
            func diff(_ a: Double?, _ b: Double?) -> Double? { a.flatMap { x in b.map { x - $0 } } }
            comparison = .delta(Delta(
                cpuAvg: diff(cpu?.avg, previous.cpu?.avg), cpuPeak: diff(cpu?.peak, previous.cpu?.peak),
                memoryAvg: diff(memory?.avg, previous.memory?.avg), memoryPeak: diff(memory?.peak, previous.memory?.peak),
                pressureSeconds: diff(pressureSeconds, previous.pressureSeconds),
                incidentCount: incidentCount - previous.incidentCount,
                incidentSeconds: incidentSeconds - previous.incidentSeconds))
        } else {
            comparison = .noComparisonData
        }
        return HistorySummary(interval: interval, cpu: cpu, memory: memory, pressureSeconds: pressureSeconds,
                              incidentsByRule: incidentsByRule, incidentCount: incidentCount,
                              incidentSeconds: incidentSeconds, topProcesses: topProcesses, comparison: comparison)
    }
}

extension HistoryStore {
    /// Summary of `interval` without comparison.
    public func summary(for interval: DateInterval, now: Date) throws -> HistorySummary {
        func series(_ key: MetricKey) throws -> [HistoryPoint] {
            try self.series(key, from: interval.start, to: interval.end, maxPoints: 2000)
        }
        return HistorySummary.make(
            interval: interval, cpu: try series(.cpuTotal), memory: try series(.memoryPercent),
            pressure: try series(.memoryUnderPressure),
            incidents: try incidents(from: interval.start, to: interval.end),
            topProcesses: try topProcesses(from: interval.start, to: interval.end), now: now)
    }

    /// Summary of `interval` compared with the period of equal length right before it.
    public func report(for interval: DateInterval, now: Date) throws -> HistorySummary {
        let previous = DateInterval(start: interval.start.addingTimeInterval(-interval.duration), end: interval.start)
        return try summary(for: interval, now: now).comparing(to: try summary(for: previous, now: now))
    }
}
