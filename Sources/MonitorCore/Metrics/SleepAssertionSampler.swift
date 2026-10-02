import Darwin
import Foundation
import IOKit.pwr_mgt

/// A process that currently keeps the Mac from going to sleep.
public struct SleepBlocker: Sendable, Equatable, Hashable {
    public let pid: Int32
    public let name: String
    /// The assertion's own description, e.g. "caffeinate command-line tool".
    public let reason: String
    /// The process that started it. Tools like `caffeinate` are launched again and again by
    /// another program; quitting them is pointless while that program keeps running.
    public let parentName: String?

    public init(pid: Int32, name: String, reason: String, parentName: String? = nil) {
        self.pid = pid
        self.name = name
        self.reason = reason
        self.parentName = parentName
    }

    /// Stable across restarts of the same tool by the same program.
    public var identity: String { "\(name)|\(parentName ?? "")" }
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
                blockers.append(SleepBlocker(pid: pid, name: name, reason: reason, parentName: parentName(of: pid)))
                break
            }
        }
        return blockers.sorted { $0.pid < $1.pid }
    }

    /// Name of the parent process, nil for launchd-started processes (parent PID 1).
    static func parentName(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        guard parent > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(parent, &buffer, UInt32(buffer.count)) > 0 {
            return (String(cString: buffer) as NSString).lastPathComponent
        }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        return proc_name(parent, &nameBuffer, UInt32(nameBuffer.count)) > 0 ? String(cString: nameBuffer) : nil
    }
}
