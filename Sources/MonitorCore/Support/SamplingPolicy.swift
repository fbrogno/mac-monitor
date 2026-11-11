import Foundation

/// How often to sample. Short while someone is looking, long when nobody is and power is scarce.
public enum SamplingPolicy {
    public static func interval(popoverOpen: Bool, power: PowerState) -> TimeInterval {
        if popoverOpen { return 2 }
        if power.lowPowerMode { return 30 }
        return power.onBattery ? 20 : 10
    }

    /// How many seconds a sample stands for when CPU time is summed up (CPU time = percent / 100 × seconds).
    /// The real time since the previous sample, even when an extra sample came right after the regular one
    /// (a window opened, memory pressure changed): replacing that by the nominal interval would inflate the CPU
    /// time of the ranking. Only upward limited, so a sleep gap counts as at most three regular intervals.
    /// Without a previous sample, or when the clock went backwards, the nominal interval is used.
    public static func recordedSeconds(elapsed: TimeInterval?, nominal: TimeInterval) -> TimeInterval {
        let nominal = Swift.max(nominal, 1)
        guard let elapsed, elapsed >= 0 else { return nominal }
        return Swift.min(elapsed, 3 * nominal)
    }
}
