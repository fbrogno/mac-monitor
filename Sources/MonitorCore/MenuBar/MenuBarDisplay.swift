import Foundation

/// A value that can be shown as text next to the menu bar icon.
public enum MenuBarItem: String, CaseIterable, Codable, Sendable, Hashable {
    case cpu, memory, gpu, temperature, power, networkDown, battery

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Arbeitsspeicher"
        case .gpu: "GPU"
        case .temperature: "Temperatur"
        case .power: "Leistung"
        case .networkDown: "Netz ↓ (Download)"
        case .battery: "Akku"
        }
    }

    /// Prefix shown when several values are on display and the unit alone would not tell them apart.
    var tag: String? {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .gpu: "GPU"
        case .battery: "Akku"
        case .temperature, .power, .networkDown: nil
        }
    }

    /// Without duplicates, at most `MenuBarDisplay.maxItems`, in the given order.
    public static func normalized(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var seen = Set<MenuBarItem>()
        return Array(items.filter { seen.insert($0).inserted }.prefix(MenuBarDisplay.maxItems))
    }
}

/// The current readings the menu bar text is built from. A nil value is not shown.
public struct MenuBarValues: Sendable, Equatable {
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var gpuPercent: Double?
    public var temperatureCelsius: Double?
    public var watts: Double?
    public var downBytesPerSecond: Double?
    public var batteryPercent: Double?

    public init(cpuPercent: Double, memoryPercent: Double, gpuPercent: Double? = nil,
                temperatureCelsius: Double? = nil, watts: Double? = nil,
                downBytesPerSecond: Double? = nil, batteryPercent: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.temperatureCelsius = temperatureCelsius
        self.watts = watts
        self.downBytesPerSecond = downBytesPerSecond
        self.batteryPercent = batteryPercent
    }

    public init(_ s: SystemSnapshot) {
        self.init(cpuPercent: s.cpuPercent, memoryPercent: s.memoryFraction * 100,
                  gpuPercent: s.gpu?.utilizationPercent, temperatureCelsius: s.thermals?.cpuMaxCelsius,
                  watts: s.powerDraw?.systemWatts, downBytesPerSecond: s.network?.downBytesPerSecond,
                  batteryPercent: s.power.batteryPercent.map(Double.init))
    }

    func value(_ item: MenuBarItem) -> Double? {
        switch item {
        case .cpu: cpuPercent
        case .memory: memoryPercent
        case .gpu: gpuPercent
        case .temperature: temperatureCelsius
        case .power: watts
        case .networkDown: downBytesPerSecond
        case .battery: batteryPercent
        }
    }
}

/// Builds the menu bar text and decides when it may change.
///
/// Every change of the text makes macOS redraw the status item on every display (about 40 ms each),
/// so the text only changes when the SHOWN text would change, in coarse steps per quantity and at most
/// every `minInterval` seconds. Numbers are padded with figure spaces (as wide as a digit) so the item
/// keeps its width while the values move.
public struct MenuBarDisplay: Sendable {
    public static let maxItems = 3
    public static let minInterval: TimeInterval = 10
    /// Width of a digit; used to pad numbers.
    static let pad: Character = "\u{2007}"

    public private(set) var text = ""
    private var shown: [MenuBarItem: Double] = [:]
    private var lastChange: Date?

    public init() {}

    /// The new text, or nil when the menu bar should stay as it is. `force` is for a changed choice of items.
    public mutating func update(items: [MenuBarItem], values: MenuBarValues, now: Date, force: Bool = false) -> String? {
        let items = MenuBarItem.normalized(items).filter { values.value($0) != nil }
        guard !items.isEmpty else {
            shown = [:]
            guard !text.isEmpty else { return nil }
            text = ""
            lastChange = now
            return text
        }
        let sameItems = Set(items) == Set(shown.keys)
        let moved = !sameItems || items.contains { item in
            guard let old = shown[item], let new = values.value(item) else { return true }
            return Self.moved(item, from: old, to: new)
        }
        guard force || moved else { return nil }
        if !force, sameItems, let last = lastChange, now.timeIntervalSince(last) < Self.minInterval { return nil }

        shown = Dictionary(uniqueKeysWithValues: items.compactMap { item in values.value(item).map { (item, $0) } })
        let built = Self.build(items: items, values: values)
        guard built != text else { return nil }
        text = built
        lastChange = now
        return built
    }

    /// Whether a change from `old` to `new` is big enough to redraw.
    static func moved(_ item: MenuBarItem, from old: Double, to new: Double) -> Bool {
        switch item {
        case .cpu, .memory, .gpu, .battery: abs(new - old) >= 5
        case .temperature: abs(new - old) >= 2
        case .power: abs(new - old) >= (old < 20 ? 1 : 5)
        case .networkDown: networkStep(old) != networkStep(new)
        }
    }

    /// Download in coarse steps (bytes per second): idle, 100 KB/s, 500 KB/s, 1, 2, 5, 10, 25, 50, 100 MB/s.
    static func networkStep(_ bytesPerSecond: Double) -> Int {
        let mb = bytesPerSecond / 1_048_576
        return [0.05, 0.1, 0.5, 1, 2, 5, 10, 25, 50, 100].filter { mb >= $0 }.count
    }

    /// The text for the given items and values, without any change throttling (for previews).
    public static func build(items: [MenuBarItem], values: MenuBarValues) -> String {
        let tagged = items.count > 1
        return items.compactMap { item -> String? in
            guard let v = values.value(item) else { return nil }
            let body: String
            switch item {
            case .cpu, .memory, .gpu, .battery: body = padded("\(Int(v.rounded()))", 3) + "%"
            case .temperature: body = padded("\(Int(v.rounded()))", 3) + "°C"
            case .power: body = padded("\(Int(v.rounded()))", 3) + " W"
            case .networkDown:
                let mb = v / 1_048_576
                let number = mb < 0.1 ? "0" : mb < 10 ? Format.decimal(mb, digits: 1) : "\(Int(mb.rounded()))"
                body = "↓" + padded(number, 3) + " MB/s"
            }
            if tagged, let tag = item.tag { return "\(tag) \(body)" }
            return body
        }.joined(separator: " · ")
    }

    static func padded(_ text: String, _ width: Int) -> String {
        String(repeating: pad, count: max(0, width - text.count)) + text
    }
}
