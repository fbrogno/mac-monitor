import Foundation

/// How often to sample. Short while someone is looking, long when nobody is and power is scarce.
public enum SamplingPolicy {
    public static func interval(popoverOpen: Bool, power: PowerState) -> TimeInterval {
        if popoverOpen { return 2 }
        if power.lowPowerMode { return 30 }
        return power.onBattery ? 20 : 10
    }
}
