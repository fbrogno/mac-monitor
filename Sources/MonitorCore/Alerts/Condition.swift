import Foundation

public enum Severity: Int, Sendable, Comparable, Codable {
    case info, warning, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Something a rule considers abnormal right now. The engine decides whether it has lasted long
/// enough to be worth a notification.
public struct Condition: Sendable, Equatable, Identifiable {
    /// Stable identity across samples, e.g. `process.cpu.Xcode`.
    public let key: String
    public let rule: RuleID
    public let severity: Severity
    public let title: String
    public let body: String
    /// How long the condition must hold before it is reported.
    public let sustain: TimeInterval
    public let process: ProcessRef?
    /// Overrides the engine's reminder interval for this condition (e.g. 7 days for battery health).
    public let reminderInterval: TimeInterval?

    public var id: String { key }

    public init(key: String, rule: RuleID, severity: Severity, title: String, body: String,
                sustain: TimeInterval, process: ProcessRef? = nil, reminderInterval: TimeInterval? = nil) {
        self.key = key
        self.rule = rule
        self.severity = severity
        self.title = title
        self.body = body
        self.sustain = sustain
        self.process = process
        self.reminderInterval = reminderInterval
    }
}

/// A process as it was seen. The PID alone is not an identity (the system reuses PIDs), so the
/// kernel start time travels with it; `SignalGuard` compares both right before anything is sent.
public struct ProcessRef: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let name: String
    /// `ri_proc_start_abstime` of the process; nil when unknown (old notification payloads, tests).
    public let startTime: UInt64?

    public init(pid: Int32, name: String, startTime: UInt64? = nil) {
        self.pid = pid
        self.name = name
        self.startTime = startTime
    }

    /// The reference to a sampled process, with its start time when the sample has one.
    public init(_ stat: ProcessStat) {
        self.init(pid: stat.pid, name: stat.name, startTime: stat.startTime == 0 ? nil : stat.startTime)
    }
}

extension SystemSnapshot {
    /// A reference to the process with this PID, with the start time from this snapshot if the name still fits
    /// (sleep blockers come from IOKit and know no start time themselves).
    public func processRef(pid: Int32, name: String) -> ProcessRef {
        if let stat = processes.first(where: { $0.pid == pid }), SignalGuard.sameName(stat.name, name) {
            return ProcessRef(stat)
        }
        return ProcessRef(pid: pid, name: name)
    }
}

/// A notification-worthy moment produced by the engine.
public struct AlertEvent: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case fired, reminder, escalated, resolved
    }

    public let id = UUID()
    public let date: Date
    public let kind: Kind
    public let condition: Condition

    public init(date: Date, kind: Kind, condition: Condition) {
        self.date = date
        self.kind = kind
        self.condition = condition
    }
}
