import Foundation

/// Pure rule set: snapshot in, abnormal conditions out. No timing, no side effects —
/// sustain, reminders and de-duplication live in `AlertEngine`.
public enum Rules {
    /// Rules lower their threshold to this share while a condition is already active,
    /// so a value hovering around the limit does not flap.
    public static let hysteresis = 0.85

    public struct Context {
        public var settings: MonitorSettings
        /// True if the engine currently tracks this key.
        public var isActive: (String) -> Bool
        /// Process names the user muted for now.
        public var mutedProcesses: Set<String>
        /// How much swap grew over the last ten minutes (0 if it shrank or is unknown).
        public var swapGrowthBytes: UInt64
        /// Mean power per app (`appKey` to milliwatts) over the energy-hog window, if the caller keeps
        /// a history. Apps missing here are judged by their current power.
        public var averagedAppEnergyMilliwatts: [String: Double]

        public init(settings: MonitorSettings, isActive: @escaping (String) -> Bool = { _ in false },
                    mutedProcesses: Set<String> = [], swapGrowthBytes: UInt64 = 0,
                    averagedAppEnergyMilliwatts: [String: Double] = [:]) {
            self.averagedAppEnergyMilliwatts = averagedAppEnergyMilliwatts
            self.settings = settings
            self.isActive = isActive
            self.mutedProcesses = mutedProcesses
            self.swapGrowthBytes = swapGrowthBytes
        }

        func limit(_ value: Double, key: String) -> Double {
            isActive(key) ? value * Rules.hysteresis : value
        }
    }

    public static func evaluate(_ s: SystemSnapshot, _ ctx: Context) -> [Condition] {
        let set = ctx.settings
        var out: [Condition] = []

        let ignored = Set(set.ignoredProcesses.map { $0.lowercased() })
        let candidates = s.processes.filter {
            !ignored.contains($0.name.lowercased()) && !ctx.mutedProcesses.contains($0.name)
        }

        if set.isEnabled(.runawayProcess) {
            for p in candidates {
                let key = "process.cpu.\(p.pid)"
                guard p.cpuPercent >= ctx.limit(set.processCPUThreshold, key: key) else { continue }
                out.append(Condition(
                    key: key, rule: .runawayProcess, severity: .warning,
                    title: "\(p.name) hängt bei \(Format.percent(p.cpuPercent)) CPU",
                    body: "Seit über \(Format.duration(set.processCPUSustain)) ununterbrochen hohe Last (PID \(p.pid)).",
                    sustain: set.processCPUSustain,
                    process: ProcessRef(pid: p.pid, name: p.name)))
            }
        }

        if set.isEnabled(.memoryHog), s.memoryTotalBytes > 0 {
            let base = Double(s.memoryTotalBytes) * set.memoryHogFraction
            for p in candidates {
                let key = "process.memory.\(p.pid)"
                guard Double(p.footprintBytes) >= ctx.limit(base, key: key) else { continue }
                out.append(Condition(
                    key: key, rule: .memoryHog, severity: .warning,
                    title: "\(p.name) belegt \(Format.bytes(p.footprintBytes)) RAM",
                    body: "Das sind \(Format.percent(Double(p.footprintBytes) / Double(s.memoryTotalBytes) * 100)) deines Arbeitsspeichers (PID \(p.pid)).",
                    sustain: set.memoryHogSustain,
                    process: ProcessRef(pid: p.pid, name: p.name)))
            }
        }

        if set.isEnabled(.cpuHigh) {
            let key = "system.cpu"
            if s.cpuPercent >= ctx.limit(set.cpuTotalThreshold, key: key) {
                let top = candidates.prefix(3).filter { $0.cpuPercent >= 10 }
                    .map { "\($0.name) \(Format.percent($0.cpuPercent))" }.joined(separator: ", ")
                out.append(Condition(
                    key: key, rule: .cpuHigh, severity: .warning,
                    title: "CPU seit \(Format.duration(set.cpuTotalSustain)) bei \(Format.percent(s.cpuPercent))",
                    body: top.isEmpty ? "Der Mac ist dauerhaft ausgelastet." : "Größte Verbraucher: \(top)",
                    sustain: set.cpuTotalSustain))
            }
        }

        if set.isEnabled(.memoryPressure), s.memoryPressure >= .warning {
            let critical = s.memoryPressure == .critical
            out.append(Condition(
                key: "system.memoryPressure", rule: .memoryPressure,
                severity: critical ? .critical : .warning,
                title: critical ? "Speicherdruck kritisch" : "Speicherdruck erhöht",
                body: "\(Format.bytes(s.memoryUsedBytes)) von \(Format.bytes(s.memoryTotalBytes)) belegt, Swap \(Format.bytes(s.swapUsedBytes)). Schließe große Apps, sonst wird der Mac langsam.",
                sustain: critical ? 0 : set.memoryPressureSustain))
        }

        if set.isEnabled(.swap) {
            // Swap only shrinks when the owning apps quit, so a high value alone is often a leftover.
            // Report it while it is still growing or memory is actually tight.
            let key = "system.swap"
            let limit = ctx.limit(set.swapThresholdGB * 1_073_741_824, key: key)
            let growing = ctx.swapGrowthBytes >= 1_073_741_824
            let tight = s.memoryPressure >= .warning
            if Double(s.swapUsedBytes) >= limit, growing || tight || ctx.isActive(key) {
                let growth = growing ? " (+\(Format.bytes(ctx.swapGrowthBytes)) in 10 min)" : ""
                out.append(Condition(
                    key: key, rule: .swap, severity: .warning,
                    title: "Swap bei \(Format.bytes(s.swapUsedBytes))\(growth)",
                    body: "Der Arbeitsspeicher reicht nicht, macOS lagert auf die SSD aus.",
                    sustain: 0))
            }
        }

        if set.isEnabled(.thermal), s.thermal >= .serious {
            let critical = s.thermal == .critical
            let top = candidates.first.map { " Größter Verbraucher: \($0.name) (\(Format.percent($0.cpuPercent)))." } ?? ""
            out.append(Condition(
                key: "system.thermal", rule: .thermal, severity: critical ? .critical : .warning,
                title: critical ? "Mac überhitzt" : "Mac wird heiß und drosselt",
                body: "macOS reduziert die Leistung.\(top)",
                sustain: 0))
        }

        if set.isEnabled(.disk), let disk = s.disk {
            let key = "system.disk"
            // Lower bound: while active, free space must climb clearly above the limit to clear.
            let factor = ctx.isActive(key) ? 1 / Rules.hysteresis : 1
            let tooLowFraction = disk.freeFraction * 100 < set.diskMinFreePercent * factor
            let tooLowBytes = Double(disk.availableBytes) < set.diskMinFreeGB * 1_073_741_824 * factor
            if tooLowFraction || tooLowBytes {
                out.append(Condition(
                    key: key, rule: .disk, severity: disk.availableBytes < 5 * 1_073_741_824 ? .critical : .warning,
                    title: "Nur noch \(Format.bytes(disk.availableBytes)) frei",
                    body: "Die SSD ist zu \(Format.percent((1 - disk.freeFraction) * 100)) voll.",
                    sustain: 0))
            }
        }

        if set.isEnabled(.network), !s.isOnline {
            out.append(Condition(
                key: "system.network", rule: .network, severity: .warning,
                title: "Keine Internetverbindung",
                body: "Seit \(Format.duration(set.networkOfflineSustain)) offline.",
                sustain: set.networkOfflineSustain))
        }

        if set.isEnabled(.sleepBlocker), s.power.onBattery {
            for blocker in s.sleepBlockers
            where !ignored.contains(blocker.name.lowercased()) && !ctx.mutedProcesses.contains(blocker.name) {
                // Keyed by tool and launcher, not PID: `caffeinate -t 300` chains get a new PID every
                // few minutes but keep the Mac awake all the same.
                let launcher = blocker.parentName.map { ", gestartet von \($0)" } ?? ""
                out.append(Condition(
                    key: "sleep.\(blocker.identity)", rule: .sleepBlocker, severity: .warning,
                    title: "\(blocker.name) verhindert den Ruhezustand",
                    body: "Seit über \(Format.duration(set.sleepBlockerSustain)) im Akkubetrieb\(launcher): „\(blocker.reason)“.",
                    sustain: set.sleepBlockerSustain,
                    process: ProcessRef(pid: blocker.pid, name: blocker.name)))
            }
        }

        out += extended(s, ctx, ignored: ignored)
        return out
    }
}
