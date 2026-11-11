import MonitorCore
import SwiftUI

/// Tiles with the live value and a small history, current findings, uptime and load.
struct OverviewPane: View {
    let model: AppModel
    let data: DashboardData

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let s = model.snapshot {
                LazyVGrid(columns: columns, spacing: 12) {
                    tiles(s)
                }
            } else {
                Text("Erste Messung läuft …").font(.callout).foregroundStyle(.secondary)
            }
            findings
            if let runtime = model.snapshot?.runtime { runtimeCard(runtime) }
        }
    }

    @ViewBuilder private func tiles(_ s: SystemSnapshot) -> some View {
        let d = data
        MetricTile(title: String(localized: "CPU"), symbol: "cpu", value: Format.percent(s.cpuPercent),
                   detail: String(localized: "\(s.cpuCores?.perCore.count ?? ProcessInfo.processInfo.activeProcessorCount) Kerne"),
                   tint: Palette.load(s.cpuPercent), lines: [d.line(.cpuTotal, "CPU", Palette.accent)],
                   from: d.from, to: d.to, domain: 0...100)
        if s.gpu != nil || d.hasSeries(.gpuPercent) {
            MetricTile(title: String(localized: "GPU"), symbol: "display", value: s.gpu.map { Format.percent($0.utilizationPercent) } ?? "–",
                       detail: s.gpu?.memoryUsedBytes.map { String(localized: "\(Format.bytes($0)) Speicher") },
                       tint: s.gpu.map { Palette.load($0.utilizationPercent) } ?? .secondary,
                       lines: [d.line(.gpuPercent, "GPU", Palette.accent)], from: d.from, to: d.to, domain: 0...100)
        }
        MetricTile(title: String(localized: "Arbeitsspeicher"), symbol: "memorychip", value: Format.bytes(s.memoryUsedBytes),
                   detail: String(localized: "von \(Format.bytes(s.memoryTotalBytes))"),
                   tint: pressureColor(s.memoryPressure), lines: [d.line(.memoryPercent, "RAM", Palette.accent)],
                   from: d.from, to: d.to, domain: 0...100)
        if let thermals = s.thermals, thermals.cpuAverageCelsius != nil || thermals.cpuMaxCelsius != nil || d.hasSeries(.cpuTempAvg) {
            MetricTile(title: String(localized: "Temperatur"), symbol: "thermometer.medium",
                       value: (thermals.cpuAverageCelsius ?? thermals.cpuMaxCelsius).map(Format.celsius) ?? "–",
                       detail: thermals.cpuMaxCelsius.map { String(localized: "Spitze \(Format.celsius($0))") },
                       tint: s.thermal >= .serious ? Palette.critical : s.thermal == .fair ? Palette.warn : Palette.ok,
                       lines: [d.line(.cpuTempAvg, "CPU", Palette.warn)], from: d.from, to: d.to, domain: nil, unit: .celsius)
        }
        if let power = s.powerDraw?.systemWatts {
            MetricTile(title: String(localized: "Leistung"), symbol: "bolt.fill", value: Format.watts(power),
                       detail: powerDetail(s.powerDraw), tint: Palette.accent,
                       lines: [d.line(.powerSystem, "System", Palette.accent)], from: d.from, to: d.to, domain: nil, unit: .watts)
        }
        if let battery = s.power.batteryPercent {
            MetricTile(title: String(localized: "Akku"), symbol: "battery.75percent", value: "\(battery) %",
                       detail: batteryDetail(s.power),
                       tint: battery <= 15 && s.power.onBattery ? Palette.critical : Palette.ok,
                       lines: [d.line(.batteryPercent, "Akku", Palette.ok)], from: d.from, to: d.to, domain: 0...100)
        }
        MetricTile(title: String(localized: "SSD"), symbol: "internaldrive",
                   value: s.disk.map { String(localized: "\(Format.bytes($0.availableBytes)) frei") } ?? "–",
                   detail: s.diskThroughput.map { String(localized: "Lesen \(Format.rate($0.readBytesPerSecond)) · Schreiben \(Format.rate($0.writeBytesPerSecond))") },
                   tint: (s.disk?.freeFraction ?? 1) < 0.1 ? Palette.warn : Palette.ok,
                   lines: [d.line(.diskWrite, "Schreiben", Palette.warn)], from: d.from, to: d.to, domain: nil, unit: .bytesPerSecond)
        MetricTile(title: String(localized: "Netzwerk"), symbol: s.isOnline ? "arrow.up.arrow.down" : "wifi.slash",
                   value: s.isOnline ? (s.network.map { "↓ \(Format.rate($0.downBytesPerSecond))" } ?? String(localized: "Online")) : String(localized: "Offline"),
                   detail: s.network.map { "↑ \(Format.rate($0.upBytesPerSecond))" },
                   tint: s.isOnline ? Palette.accent : Palette.critical,
                   lines: [d.line(.netDown, "Empfangen", Palette.accent)], from: d.from, to: d.to, domain: nil, unit: .bytesPerSecond)
    }

    private func powerDetail(_ power: SystemPowerDraw?) -> String? {
        guard let power else { return nil }
        switch (power.cpuWatts, power.gpuWatts) {
        case let (cpu?, gpu?): return String(localized: "CPU \(Format.watts(cpu)) · GPU \(Format.watts(gpu))")
        case let (cpu?, nil): return String(localized: "CPU \(Format.watts(cpu))")
        default: return nil
        }
    }

    private func batteryDetail(_ p: PowerState) -> String {
        if p.onBattery { return p.minutesRemaining.map { String(localized: "noch \(Format.hoursMinutes($0))") } ?? String(localized: "Akkubetrieb") }
        return p.isCharging ? String(localized: "lädt") : String(localized: "Netzteil")
    }

    private var findings: some View {
        DashCard(String(localized: "Auffälligkeiten")) {
            if model.reported.isEmpty {
                Label("Keine Auffälligkeiten – MacMonitor meldet sich, sobald etwas länger aus dem Rahmen fällt.",
                      systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.ok)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.reported) { c in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: c.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.severity(c.severity))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.system(size: 12, weight: .semibold))
                                Text(c.body).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            ActionButton(title: String(localized: "Lösen")) { model.openOverview() }
                        }
                    }
                }
            }
        }
    }

    private func runtimeCard(_ r: RuntimeStat) -> some View {
        DashCard(String(localized: "Laufzeit und Last")) {
            HStack(alignment: .top, spacing: 28) {
                BigValue(value: Format.uptime(r.uptimeSeconds), caption: String(localized: "Laufzeit seit Start"))
                if let load = r.loadAverage {
                    BigValue(value: "\(Format.decimal(load.one, digits: 2)) · \(Format.decimal(load.five, digits: 2)) · \(Format.decimal(load.fifteen, digits: 2))",
                             caption: String(localized: "Last 1 · 5 · 15 min"))
                }
                BigValue(value: "\(r.processCount)", caption: String(localized: "Prozesse"))
                if r.threadCount > 0 { BigValue(value: "\(r.threadCount)", caption: String(localized: "Threads")) }
                Spacer(minLength: 0)
            }
        }
    }
}

func pressureColor(_ p: MemoryPressure) -> Color {
    switch p {
    case .normal: Palette.ok
    case .warning: Palette.warn
    case .critical: Palette.critical
    }
}

func pressureLabel(_ p: MemoryPressure) -> String {
    switch p {
    case .normal: String(localized: "Druck normal")
    case .warning: String(localized: "Druck erhöht")
    case .critical: String(localized: "Druck kritisch")
    }
}
