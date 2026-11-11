import MonitorCore
import SwiftUI

// The widget views live in their own library so the extension and the screenshot renderer
// (`MacMonitor --render-docs`) draw exactly the same thing. No WidgetKit here: the extension
// adds the container background and the tap target.

public enum WidgetSize: Sendable {
    case small, medium, large
}

/// Same colours as the app (`Palette` in the app target).
enum WidgetPalette {
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.47)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let critical = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let accent = Color(red: 0.24, green: 0.80, blue: 0.86)

    static func load(_ percent: Double) -> Color {
        percent >= 85 ? critical : percent >= 60 ? warn : ok
    }

    static func severity(_ severity: Severity?) -> Color {
        switch severity {
        case nil: ok
        case .info?: accent
        case .warning?: warn
        case .critical?: critical
        }
    }

    /// Free space: the less is left, the louder.
    static func free(_ fraction: Double) -> Color {
        fraction < 0.1 ? critical : fraction < 0.2 ? warn : ok
    }
}

// MARK: - Frame for missing or stale data

/// Shows `live` content, or a calm "MacMonitor läuft nicht" message instead of old values.
public struct WidgetStateView<Live: View>: View {
    let content: WidgetContent
    let size: WidgetSize
    @ViewBuilder let live: (WidgetSnapshot) -> Live

    public init(content: WidgetContent, size: WidgetSize, @ViewBuilder live: @escaping (WidgetSnapshot) -> Live) {
        self.content = content
        self.size = size
        self.live = live
    }

    public var body: some View {
        switch content {
        case .live(let snapshot):
            live(snapshot)
        case .stale(let lastSeen, _):
            message(String(localized: "MacMonitor läuft nicht"),
                    detail: String(localized: "Zuletzt gesehen: \(lastSeen.formatted(date: .abbreviated, time: .shortened))"))
        case .noData:
            message(String(localized: "MacMonitor läuft nicht"),
                    detail: String(localized: "Noch keine Werte. Starte MacMonitor, dann erscheinen sie hier."))
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: size == .small ? 22 : 28))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: size == .small ? 14 : 16, weight: .semibold))
            Text(detail)
                .font(.system(size: size == .small ? 11 : 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Building blocks

struct Ring: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 7
    var label: String
    var value: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.001), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

struct MiniSparkline: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let step = geo.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - min(max(v, 0), 100) / 100))
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

struct Bar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

private func headline(_ text: String, symbol: String) -> some View {
    Label(text, systemImage: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
}

private func percentText(_ value: Double) -> String { "\(Int(value.rounded())) %" }

// MARK: - Status

public struct StatusWidgetView: View {
    let content: WidgetContent
    let size: WidgetSize

    public init(content: WidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        WidgetStateView(content: content, size: size) { s in
            let tint = WidgetPalette.severity(s.worstSeverity)
            let count = s.anomalies.count
            let title = count == 0 ? String(localized: "Alles ruhig") : String(localized: "\(count) Auffälligkeiten")
            if size == .small {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        lamp(tint, count: count, diameter: 30)
                        if count == 0 {
                            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(count)").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(count == 1 ? "Auffälligkeit" : "Auffälligkeiten")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Ring(fraction: s.cpuPercent / 100, tint: WidgetPalette.load(s.cpuPercent), lineWidth: 6,
                             label: "CPU", value: percentText(s.cpuPercent))
                        Ring(fraction: s.memoryPercent / 100, tint: WidgetPalette.load(s.memoryPercent), lineWidth: 6,
                             label: "RAM", value: percentText(s.memoryPercent))
                    }
                    .frame(height: 62)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            lamp(tint, count: count, diameter: 34)
                            Text(count == 1 ? String(localized: "1 Auffälligkeit") : title)
                                .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        if s.anomalies.isEmpty {
                            Text("Keine Auffälligkeiten in den letzten Messungen.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(s.anomalies.prefix(size == .large ? 5 : 2).enumerated()), id: \.offset) { _, a in
                                HStack(spacing: 6) {
                                    Circle().fill(WidgetPalette.severity(Severity(rawValue: a.severity))).frame(width: 7, height: 7)
                                    Text(a.title).font(.system(size: 12)).lineLimit(1)
                                }
                            }
                            if s.anomalies.count > (size == .large ? 5 : 2) {
                                Text("+ \(s.anomalies.count - (size == .large ? 5 : 2)) weitere")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Ring(fraction: s.cpuPercent / 100, tint: WidgetPalette.load(s.cpuPercent), lineWidth: 7,
                             label: "CPU", value: percentText(s.cpuPercent))
                        Ring(fraction: s.memoryPercent / 100, tint: WidgetPalette.load(s.memoryPercent), lineWidth: 7,
                             label: "RAM", value: percentText(s.memoryPercent))
                    }
                    .frame(width: 128, height: 62)
                }
            }
        }
    }

    private func lamp(_ tint: Color, count: Int, diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.18))
            Circle().strokeBorder(tint, lineWidth: 2.5)
            Image(systemName: count == 0 ? "checkmark" : "exclamationmark")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Auslastung

public struct LoadWidgetView: View {
    let content: WidgetContent
    var showTemperature: Bool
    var showPower: Bool

    public init(content: WidgetContent, showTemperature: Bool = true, showPower: Bool = true) {
        self.content = content
        self.showTemperature = showTemperature
        self.showPower = showPower
    }

    public var body: some View {
        WidgetStateView(content: content, size: .medium) { s in
            VStack(alignment: .leading, spacing: 8) {
                headline(String(localized: "Auslastung"), symbol: "gauge.with.dots.needle.50percent")
                HStack(spacing: 12) {
                    column("CPU", value: s.cpuPercent, series: s.cpuSeries)
                    column("RAM", value: s.memoryPercent, series: s.memorySeries)
                    if let gpu = s.gpuPercent { column("GPU", value: gpu, series: s.gpuSeries) }
                }
                if showTemperature || showPower {
                    HStack(spacing: 14) {
                        if showTemperature, let t = s.temperatureCelsius {
                            Label(Format.celsius(t), systemImage: "thermometer.medium")
                        }
                        if showPower, let w = s.powerWatts {
                            Label(Format.watts(w), systemImage: "bolt.fill")
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private func column(_ label: String, value: Double, series: [Double]) -> some View {
        let tint = WidgetPalette.load(value)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(percentText(value)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint)
            MiniSparkline(values: series, tint: tint)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Akku & Energie

public struct BatteryWidgetView: View {
    let content: WidgetContent
    let size: WidgetSize

    public init(content: WidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        WidgetStateView(content: content, size: size) { s in
            if let b = s.battery {
                let tint = b.isCharging || !b.onBattery ? WidgetPalette.ok : (b.percent <= 10 ? WidgetPalette.critical : b.percent <= 20 ? WidgetPalette.warn : WidgetPalette.ok)
                if size == .small {
                    VStack(alignment: .leading, spacing: 6) {
                        headline(String(localized: "Akku"), symbol: symbol(b))
                        Spacer(minLength: 0)
                        Text("\(b.percent) %").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Bar(fraction: Double(b.percent) / 100, tint: tint)
                        Text(state(b)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            headline(String(localized: "Akku & Energie"), symbol: symbol(b))
                            Spacer(minLength: 0)
                            Text("\(b.percent) %").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            Bar(fraction: Double(b.percent) / 100, tint: tint)
                            Text(state(b)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            fact("bolt.fill", String(localized: "Leistung"), s.powerWatts.map(Format.watts) ?? "–")
                            fact("heart.fill", String(localized: "Zustand"), b.healthPercent.map { "\($0) %" } ?? "–")
                            fact("arrow.triangle.2.circlepath", String(localized: "Ladezyklen"), b.cycleCount.map(String.init) ?? "–")
                        }
                        .frame(width: 130, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    headline(String(localized: "Energie"), symbol: "powerplug.fill")
                    Spacer(minLength: 0)
                    Text(s.powerWatts.map(Format.watts) ?? "–")
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("Kein Akku, Netzbetrieb").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func symbol(_ b: WidgetSnapshot.Battery) -> String {
        b.isCharging ? "battery.100.bolt" : b.percent > 60 ? "battery.100" : b.percent > 25 ? "battery.50" : "battery.25"
    }

    private func state(_ b: WidgetSnapshot.Battery) -> String {
        if b.isCharging { return String(localized: "Lädt") }
        if !b.onBattery { return String(localized: "Netzteil, voll") }
        if let m = b.minutesRemaining { return String(localized: "Noch \(Format.hoursMinutes(m))") }
        return String(localized: "Auf Akku")
    }

    private func fact(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(WidgetPalette.accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
        }
    }
}

// MARK: - Speicherplatz

public struct StorageWidgetView: View {
    let content: WidgetContent
    let size: WidgetSize

    public init(content: WidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        WidgetStateView(content: content, size: size) { s in
            if let free = s.diskFreeBytes, let total = s.diskTotalBytes, total > 0 {
                let freeFraction = Double(free) / Double(total)
                let tint = WidgetPalette.free(freeFraction)
                if size == .small {
                    VStack(alignment: .leading, spacing: 6) {
                        headline(String(localized: "Speicherplatz"), symbol: "internaldrive.fill")
                        Spacer(minLength: 0)
                        Text(Format.bytes(free)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.7).lineLimit(1)
                        Text("frei von \(Format.bytes(total))").font(.system(size: 11)).foregroundStyle(.secondary)
                        Bar(fraction: 1 - freeFraction, tint: tint)
                    }
                } else {
                    HStack(spacing: 18) {
                        Ring(fraction: 1 - freeFraction, tint: tint, lineWidth: 9, label: "belegt",
                             value: percentText((1 - freeFraction) * 100))
                            .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            headline(String(localized: "Speicherplatz"), symbol: "internaldrive.fill")
                            Text(Format.bytes(free)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("frei von \(Format.bytes(total))").font(.system(size: 12)).foregroundStyle(.secondary)
                            Bar(fraction: 1 - freeFraction, tint: tint)
                            if freeFraction < 0.1 {
                                Text("Wenig Platz. Aufräumen lohnt sich.").font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                            }
                        }
                    }
                }
            } else {
                Text("Kein Wert für den Speicherplatz").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Top-Apps

public struct TopAppsWidgetView: View {
    let content: WidgetContent
    let size: WidgetSize

    public init(content: WidgetContent, size: WidgetSize) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        WidgetStateView(content: content, size: size) { s in
            let rows = Array(s.topApps.prefix(size == .large ? 5 : 3))
            VStack(alignment: .leading, spacing: size == .large ? 10 : 8) {
                HStack {
                    headline(String(localized: "Größte Verbraucher"), symbol: "list.number")
                    Spacer()
                    Text("CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, app in
                    if size == .large && index > 0 { Divider().opacity(0.5) }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            if size == .large {
                                Text("\(Format.bytes(app.memoryBytes)) RAM · \(Format.milliwatts(app.energyMilliwatts))")
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Bar(fraction: min(app.cpuPercent, 100) / 100, tint: WidgetPalette.load(app.cpuPercent), height: 5)
                            .frame(width: size == .large ? 56 : 40)
                        Text("\(Int(app.cpuPercent.rounded())) %").font(.system(size: 12)).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if rows.isEmpty {
                    Text("Keine Apps mit nennenswerter Last").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if size == .large {
                    Text("Nach CPU sortiert, Stand \(s.date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Demo data

extension WidgetSnapshot {
    /// Fixed, plausible values for the rendered docs and previews.
    public static func demo(alerts: Bool, now: Date = Date()) -> WidgetSnapshot {
        let gb: UInt64 = 1_073_741_824
        func series(_ base: Double, _ amp: Double, _ phase: Double, bump: Double = 0) -> [Double] {
            var values: [Double] = []
            for i in 0..<60 {
                let wave: Double = amp * sin(Double(i) / 6 + phase)
                let jitter = Double((i * 37) % 7)
                let spike: Double = i > 48 ? bump : 0
                values.append(max(2, base + wave + spike + jitter))
            }
            return values
        }
        return WidgetSnapshot(
            date: now, cpuPercent: alerts ? 47 : 18, memoryPercent: alerts ? 66 : 58, memoryUsedBytes: 15_800_000_000,
            memoryTotalBytes: 24 * gb, gpuPercent: alerts ? 34 : 9, temperatureCelsius: alerts ? 58 : 44,
            powerWatts: alerts ? 24.6 : 11.3,
            battery: .init(percent: 82, onBattery: true, isCharging: false, minutesRemaining: 312, healthPercent: 96, cycleCount: 143),
            diskFreeBytes: 312 * gb, diskTotalBytes: 994 * gb,
            anomalies: alerts ? [
                .init(key: "a", title: "node hängt bei 100 % CPU", severity: Severity.warning.rawValue),
                .init(key: "b", title: "Arbeitsspeicher wird knapp", severity: Severity.warning.rawValue),
                .init(key: "c", title: "Swap wächst schnell", severity: Severity.info.rawValue),
            ] : [],
            topApps: [
                .init(name: "node", cpuPercent: alerts ? 99.6 : 12.4, memoryBytes: 1_400_000_000, energyMilliwatts: alerts ? 5200 : 640),
                .init(name: "Xcode", cpuPercent: 50, memoryBytes: 4_100_000_000, energyMilliwatts: 2860),
                .init(name: "Google Chrome", cpuPercent: 35, memoryBytes: 4_000_000_000, energyMilliwatts: 2830),
                .init(name: "Docker", cpuPercent: 9.3, memoryBytes: 4 * gb, energyMilliwatts: 940),
                .init(name: "Claude", cpuPercent: 6.1, memoryBytes: 900_000_000, energyMilliwatts: 520),
            ],
            cpuSeries: series(24, 12, 0, bump: alerts ? 22 : 0), memorySeries: series(58, 5, 1, bump: alerts ? 6 : 0),
            gpuSeries: series(10, 6, 2, bump: alerts ? 20 : 0))
    }
}
