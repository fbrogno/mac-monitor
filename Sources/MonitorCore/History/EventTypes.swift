import Foundation

public enum EventKind: String, Sendable, Codable, CaseIterable {
    case fired, reminder, escalated, resolved

    public init(_ kind: AlertEvent.Kind) {
        switch kind {
        case .fired: self = .fired
        case .reminder: self = .reminder
        case .escalated: self = .escalated
        case .resolved: self = .resolved
        }
    }
}

/// A persisted `AlertEvent`.
public struct HistoryEvent: Sendable, Equatable, Codable {
    public let date: Date
    /// `Condition.key`, the identity that ties fired … resolved together.
    public let key: String
    /// `RuleID.rawValue`; kept as text so rules removed later do not break old rows.
    public let rule: String
    public let severity: Severity
    public let kind: EventKind
    public let title: String
    public let body: String
    public let process: String?

    public init(date: Date, key: String, rule: String, severity: Severity, kind: EventKind,
                title: String, body: String, process: String? = nil) {
        self.date = date
        self.key = key
        self.rule = rule
        self.severity = severity
        self.kind = kind
        self.title = title
        self.body = body
        self.process = process
    }

    public init(_ event: AlertEvent) {
        self.init(date: event.date, key: event.condition.key, rule: event.condition.rule.rawValue,
                  severity: event.condition.severity, kind: EventKind(event.kind),
                  title: event.condition.title, body: event.condition.body,
                  process: event.condition.process?.name)
    }

    public var ruleID: RuleID? { RuleID(rawValue: rule) }
}

/// A condition from `fired` until `resolved`.
public struct Incident: Sendable, Equatable, Codable {
    public let key: String
    public let rule: String
    /// Highest severity seen while the incident lasted.
    public let severity: Severity
    public let title: String
    public let process: String?
    public let start: Date
    /// nil while the incident is still open.
    public let end: Date?

    public init(key: String, rule: String, severity: Severity, title: String,
                process: String?, start: Date, end: Date?) {
        self.key = key
        self.rule = rule
        self.severity = severity
        self.title = title
        self.process = process
        self.start = start
        self.end = end
    }

    /// Length so far; open incidents run until `now`.
    public func duration(asOf now: Date) -> TimeInterval {
        Swift.max(0, (end ?? now).timeIntervalSince(start))
    }

    /// Pairs events into incidents, ordered by start. Pure function.
    /// `reminder`/`escalated` raise the severity; a `resolved` or reminder without a preceding
    /// `fired` (it fell out of the retention window) is ignored; a repeated `fired` is ignored.
    public static func build(from events: [HistoryEvent]) -> [Incident] {
        var open: [String: Incident] = [:]
        var done: [Incident] = []
        for event in events.enumerated().sorted(by: { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }).map(\.element) {
            switch event.kind {
            case .fired:
                if open[event.key] == nil {
                    open[event.key] = Incident(key: event.key, rule: event.rule, severity: event.severity,
                                               title: event.title, process: event.process,
                                               start: event.date, end: nil)
                }
            case .reminder, .escalated:
                if let current = open[event.key], event.severity > current.severity {
                    open[event.key] = Incident(key: current.key, rule: current.rule, severity: event.severity,
                                               title: current.title, process: current.process,
                                               start: current.start, end: nil)
                }
            case .resolved:
                if let current = open.removeValue(forKey: event.key) {
                    done.append(Incident(key: current.key, rule: current.rule, severity: current.severity,
                                         title: current.title, process: current.process,
                                         start: current.start, end: event.date))
                }
            }
        }
        return (done + open.values).sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }
}

/// One process group in one sample. `group` is chosen by the caller (process name today,
/// app name later). `cpuPercent` uses the Activity Monitor scale (100 = one busy core).
public struct ProcessUsage: Sendable, Equatable {
    public let group: String
    public let cpuPercent: Double
    public let footprintBytes: UInt64

    public init(group: String, cpuPercent: Double, footprintBytes: UInt64) {
        self.group = group
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }

    /// Groups the snapshot's processes (CPU and footprint are summed per group).
    public static func usages(from snapshot: SystemSnapshot,
                              group: (ProcessStat) -> String = { $0.name }) -> [ProcessUsage] {
        var sums: [String: (cpu: Double, bytes: UInt64)] = [:]
        for process in snapshot.processes {
            let key = group(process)
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.cpu + process.cpuPercent, old.bytes + process.footprintBytes)
        }
        return sums.map { ProcessUsage(group: $0.key, cpuPercent: $0.value.cpu, footprintBytes: $0.value.bytes) }
    }
}

/// A group's total over a period.
public struct ProcessConsumer: Sendable, Equatable, Codable {
    public let group: String
    /// CPU time in seconds (100 % of one core for one second = 1).
    public let cpuSeconds: Double
    /// Highest footprint seen in any sample.
    public let peakFootprintBytes: UInt64

    public init(group: String, cpuSeconds: Double, peakFootprintBytes: UInt64) {
        self.group = group
        self.cpuSeconds = cpuSeconds
        self.peakFootprintBytes = peakFootprintBytes
    }
}

public struct TopProcesses: Sendable, Equatable, Codable {
    public let byCPU: [ProcessConsumer]
    public let byMemory: [ProcessConsumer]

    public init(byCPU: [ProcessConsumer], byMemory: [ProcessConsumer]) {
        self.byCPU = byCPU
        self.byMemory = byMemory
    }

    public static let empty = TopProcesses(byCPU: [], byMemory: [])
}
