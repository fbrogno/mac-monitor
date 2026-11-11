import Foundation

/// Moving mean of each app's energy use over a time window (default 5 min), kept in memory and bounded.
/// Feeds `Rules.Context.averagedAppEnergyMilliwatts`, so a short spike does not count as an energy hog.
public struct EnergyAverager: Sendable {
    public let window: TimeInterval
    public let maxApps: Int
    private var samples: [String: [(date: Date, milliwatts: Double)]] = [:]

    public init(window: TimeInterval = 300, maxApps: Int = 200) {
        self.window = window
        self.maxApps = maxApps
    }

    /// Adds one reading per app (processes grouped by `appKey`, like the rule does).
    public mutating func add(_ processes: [ProcessStat], at date: Date) {
        var perApp: [String: Double] = [:]
        for p in processes {
            perApp[p.appKey.isEmpty ? "proc:\(p.pid)" : p.appKey, default: 0] += p.energyMilliwatts
        }
        for (key, value) in perApp where value > 0 || samples[key] != nil {
            samples[key, default: []].append((date, value))
        }
        // Apps that are no longer running get a zero while they are still tracked, so their mean decays.
        for key in samples.keys where perApp[key] == nil {
            samples[key]?.append((date, 0))
        }
        prune(now: date)
    }

    private mutating func prune(now: Date) {
        for key in Array(samples.keys) {
            samples[key]?.removeAll { now.timeIntervalSince($0.date) > window }
            if samples[key]?.allSatisfy({ $0.milliwatts == 0 }) ?? true { samples[key] = nil }
        }
        if samples.count > maxApps {
            let keep = samples.sorted { ($0.value.last?.milliwatts ?? 0) > ($1.value.last?.milliwatts ?? 0) }.prefix(maxApps)
            samples = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// `appKey` to mean milliwatts over the window.
    public var averages: [String: Double] {
        samples.mapValues { list in list.reduce(0) { $0 + $1.milliwatts } / Double(max(list.count, 1)) }
    }

    public var trackedApps: Int { samples.count }

    public mutating func reset() { samples = [:] }
}
