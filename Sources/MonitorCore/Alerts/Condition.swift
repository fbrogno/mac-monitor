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

    public var id: String { key }

    public init(key: String, rule: RuleID, severity: Severity, title: String, body: String,
                sustain: TimeInterval, process: ProcessRef? = nil) {
        self.key = key
        self.rule = rule
        self.severity = severity
        self.title = title
        self.body = body
        self.sustain = sustain
        self.process = process
    }
}

public struct ProcessRef: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
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
