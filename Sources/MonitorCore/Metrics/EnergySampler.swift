import Foundation

/// Raw energy counters of one interval, in joules.
struct EnergyDelta: Equatable {
    var cpu = 0.0, gpu = 0.0, ane = 0.0, dram = 0.0

    /// Average power over `seconds`; nil when no time passed.
    func watts(over seconds: TimeInterval) -> SystemPowerDraw? {
        guard seconds > 0 else { return nil }
        return SystemPowerDraw(cpuWatts: cpu / seconds, gpuWatts: gpu / seconds,
                               aneWatts: ane / seconds, dramWatts: dram / seconds)
    }

    /// Adds one IOReport channel to the matching bucket. Unknown channels are ignored.
    mutating func add(channel: String, value: Int64, unit: String) {
        guard value >= 0, let scale = Self.joulesPerUnit(unit) else { return }
        let joules = Double(value) * scale
        switch Self.bucket(of: channel) {
        case .cpu: cpu += joules
        case .gpu: gpu += joules
        case .ane: ane += joules
        case .dram: dram += joules
        case nil: break
        }
    }

    enum Bucket { case cpu, gpu, ane, dram }

    /// The aggregate channels we use; per-core and per-cluster channels would double-count.
    /// Multi-die chips prefix the name (`DIE_1_CPU Energy`).
    static func bucket(of channel: String) -> Bucket? {
        if channel == "CPU Energy" || channel.hasSuffix("_CPU Energy") { return .cpu }
        if channel == "GPU Energy" || channel.hasSuffix("_GPU Energy") { return .gpu }
        if channel == "ANE" || channel.hasSuffix("_ANE") { return .ane }
        if channel == "DRAM" || channel.hasSuffix("_DRAM") { return .dram }
        return nil
    }

    /// IOReport unit labels as printed by `IOReportChannelGetUnitLabel`.
    static func joulesPerUnit(_ label: String) -> Double? {
        switch label {
        case "J": 1
        case "mJ": 1e-3
        case "uJ", "µJ": 1e-6
        case "nJ": 1e-9
        default: nil
        }
    }
}

/// CPU/GPU/ANE/DRAM power from the private IOReport "Energy Model" group. The subscription is
/// created once; each `sample()` returns the average power since the previous call (the first
/// call only primes the baseline and returns nil). Symbols are resolved at runtime.
public final class EnergySampler {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Iterate = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let iterate: Iterate
    private let channelName: ChannelString
    private let unitLabel: ChannelString
    private let integerValue: IntegerValue

    private var previous: (sample: CFDictionary, time: TimeInterval)?

    public init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copyChannels = dlsym(lib, "IOReportCopyChannelsInGroup"),
              let createSubscription = dlsym(lib, "IOReportCreateSubscription"),
              let createSamples = dlsym(lib, "IOReportCreateSamples"),
              let createDelta = dlsym(lib, "IOReportCreateSamplesDelta"),
              let iterate = dlsym(lib, "IOReportIterate"),
              let channelName = dlsym(lib, "IOReportChannelGetChannelName"),
              let unitLabel = dlsym(lib, "IOReportChannelGetUnitLabel"),
              let integerValue = dlsym(lib, "IOReportSimpleGetIntegerValue"),
              let wanted = unsafeBitCast(copyChannels, to: CopyChannels.self)("Energy Model" as CFString, nil, 0, 0, 0)?
                  .takeRetainedValue()
        else { return nil }
        Self.keepOnlyAggregateChannels(wanted)
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = unsafeBitCast(createSubscription, to: CreateSubscription.self)(nil, wanted, &subscribed, 0, nil)?
                  .takeRetainedValue(),
              let subscribedChannels = subscribed?.takeRetainedValue() else { return nil }
        self.subscription = subscription
        self.channels = subscribedChannels
        self.createSamples = unsafeBitCast(createSamples, to: CreateSamples.self)
        self.createDelta = unsafeBitCast(createDelta, to: CreateDelta.self)
        self.iterate = unsafeBitCast(iterate, to: Iterate.self)
        self.channelName = unsafeBitCast(channelName, to: ChannelString.self)
        self.unitLabel = unsafeBitCast(unitLabel, to: ChannelString.self)
        self.integerValue = unsafeBitCast(integerValue, to: IntegerValue.self)
        previous = takeSample()
    }

    /// The group lists ~280 channels; reading and iterating them all costs ~4 ms. Narrowing the
    /// list to the few aggregate channels makes each sample far cheaper. If the private layout
    /// changes, the list stays as it is (slower, but still correct).
    private static func keepOnlyAggregateChannels(_ channels: CFMutableDictionary) {
        let dictionary = channels as NSMutableDictionary
        guard let all = dictionary["IOReportChannels"] as? [NSDictionary] else { return }
        let keep = all.filter { entry in
            guard let name = (entry["LegendChannel"] as? [Any])?.last as? String else { return false }
            return EnergyDelta.bucket(of: name) != nil
        }
        if !keep.isEmpty { dictionary["IOReportChannels"] = keep }
    }

    public func reset() { previous = takeSample() }

    /// Average CPU/GPU/ANE/DRAM power since the last call; nil on the first call, on Intel Macs
    /// or when the interval was empty.
    public func sample() -> SystemPowerDraw? {
        guard let current = takeSample() else { return nil }
        // Too short an interval makes the average meaningless; keep the old baseline.
        if let last = previous, current.time - last.time < 0.5 { return nil }
        defer { previous = current }
        guard let last = previous,
              let deltaDict = createDelta(last.sample, current.sample, nil)?.takeRetainedValue() else { return nil }
        var energy = EnergyDelta()
        let name = channelName, unit = unitLabel, value = integerValue
        iterate(deltaDict) { channel in
            if let n = name(channel)?.takeUnretainedValue() as String?,
               let u = unit(channel)?.takeUnretainedValue() as String? {
                energy.add(channel: n, value: value(channel, 0), unit: u)
            }
            return 0
        }
        guard let draw = energy.watts(over: current.time - last.time),
              (draw.cpuWatts ?? 0) + (draw.gpuWatts ?? 0) + (draw.dramWatts ?? 0) > 0 else { return nil }
        return draw
    }

    private func takeSample() -> (sample: CFDictionary, time: TimeInterval)? {
        guard let sample = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        return (sample, ProcessInfo.processInfo.systemUptime)
    }
}
