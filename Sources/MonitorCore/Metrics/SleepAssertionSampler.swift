import Foundation
import IOKit.pwr_mgt

/// A process that currently keeps the Mac from going to sleep.
public struct SleepBlocker: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let name: String
    /// The assertion's own description, e.g. "caffeinate command-line tool".
    public let reason: String

    public init(pid: Int32, name: String, reason: String) {
        self.pid = pid
        self.name = name
        self.reason = reason
    }
}

public enum SleepAssertionSampler {
    /// Assertion types that stop the whole system (not just the display) from sleeping.
    static let systemSleepTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
    ]

    /// powerd holds "prevent sleep while display is on" permanently; that is not news.
    static let ignoredOwners: Set<String> = ["powerd"]

    public static func sample() -> [SleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }

        var blockers: [SleepBlocker] = []
        for (pidNumber, assertions) in byProcess {
            let pid = pidNumber.int32Value
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String, systemSleepTypes.contains(type) else { continue }
                let name = (assertion["Process Name"] as? String) ?? "PID \(pid)"
                guard !ignoredOwners.contains(name) else { continue }
                let reason = (assertion["AssertName"] as? String) ?? type
                blockers.append(SleepBlocker(pid: pid, name: name, reason: reason))
                break
            }
        }
        return blockers.sorted { $0.pid < $1.pid }
    }
}
