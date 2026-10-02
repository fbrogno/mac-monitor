import MonitorCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var sortIndex = 0
    @State private var hoveredPID: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.reported.isEmpty { issues }
            if let s = model.snapshot {
                metrics(s)
                processes(s)
            } else {
                Text("Erste Messung läuft …")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            if !model.events.isEmpty { history }
            Divider().opacity(0.6)
            footer
        }
        .padding(14)
        .frame(width: 340)
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(size: 22)
            Text("MacMonitor").font(.system(size: 14, weight: .semibold))
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let count = model.reported.count
        let worst = model.reported.map(\.severity).max()
        let color = worst.map(Palette.severity) ?? Palette.ok
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(count == 0 ? "Alles ruhig" : count == 1 ? "1 Auffälligkeit" : "\(count) Auffälligkeiten")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: Issues

    private var issues: some View {
        VStack(spacing: 6) {
            ForEach(model.reported.prefix(3)) { c in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: c.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.severity(c.severity))
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(c.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if let p = c.process {
                        Button("Beenden") { model.confirmKill(p) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.severity(c.severity))
                    }
                }
                .padding(10)
                .background(Palette.severity(c.severity).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    // MARK: Metrics

    private func metrics(_ s: SystemSnapshot) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                chartCard(title: "CPU", value: Format.percent(s.cpuPercent),
                          detail: "\(ProcessInfo.processInfo.activeProcessorCount) Kerne",
                          values: model.cpuHistory.elements, tint: Palette.load(s.cpuPercent))
                chartCard(title: "Arbeitsspeicher", value: Format.bytes(s.memoryUsedBytes),
                          detail: "von \(Format.bytes(s.memoryTotalBytes)) · \(pressureText(s.memoryPressure))",
                          values: model.memoryHistory.elements, tint: pressureColor(s.memoryPressure))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                stat("Swap", Format.bytes(s.swapUsedBytes), symbol: "arrow.left.arrow.right",
                     tint: s.swapUsedBytes > 4 * 1_073_741_824 ? Palette.warn : .secondary)
                stat("Temperatur", thermalText(s.thermal), symbol: "thermometer.medium",
                     tint: s.thermal >= .serious ? Palette.critical : s.thermal == .fair ? Palette.warn : .secondary)
                stat("SSD frei", s.disk.map { Format.bytes($0.availableBytes) } ?? "–", symbol: "internaldrive",
                     tint: (s.disk?.freeFraction ?? 1) < 0.1 ? Palette.warn : .secondary)
                stat(powerTitle(s), powerValue(s), symbol: powerSymbol(s),
                     tint: s.isOnline ? .secondary : Palette.critical)
            }
        }
    }

    private func chartCard(title: String, value: String, detail: String, values: [Double], tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Sparkline(values: values, tint: tint).frame(height: 30).padding(.top, 2)
            }
        }
    }

    private func stat(_ title: String, _ value: String, symbol: String, tint: Color) -> some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    // MARK: Processes

    private func processes(_ s: SystemSnapshot) -> some View {
        let rows = sortIndex == 0
            ? Array(s.processes.prefix(6))
            : Array(s.processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prozesse").font(.system(size: 12, weight: .semibold))
                Spacer()
                MiniSegment(options: ["CPU", "RAM"], selection: $sortIndex)
            }
            VStack(spacing: 0) {
                ForEach(rows) { p in processRow(p) }
            }
        }
    }

    private func processRow(_ p: ProcessStat) -> some View {
        let hovered = hoveredPID == p.pid
        return HStack(spacing: 8) {
            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Format.percent(p.cpuPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(p.cpuPercent >= 90 ? Palette.critical : .primary)
                .frame(width: 52, alignment: .trailing)
            Text(Format.bytes(p.footprintBytes))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Button { model.confirmKill(ProcessRef(pid: p.pid, name: p.name)) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
            .help("\(p.name) beenden")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(hovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hoveredPID = $0 ? p.pid : (hoveredPID == p.pid ? nil : hoveredPID) }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verlauf").font(.system(size: 12, weight: .semibold))
            ForEach(model.events.prefix(4)) { e in
                HStack(spacing: 8) {
                    Image(systemName: e.kind == .resolved ? "checkmark.circle.fill" : "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(e.kind == .resolved ? Palette.ok : Palette.severity(e.condition.severity))
                        .frame(width: 14)
                    Text(e.kind == .resolved ? "Behoben: \(e.condition.title)" : e.condition.title)
                        .font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(e.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Einstellungen", symbol: "gearshape", action: onOpenSettings)
            FooterButton(title: "Aktivität", symbol: "chart.bar.xaxis", action: model.openActivityMonitor)
            Spacer()
            FooterButton(title: "Beenden", symbol: "power", action: onQuit)
        }
    }

    // MARK: Text helpers

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: "Druck normal"
        case .warning: "Druck erhöht"
        case .critical: "Druck kritisch"
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: Palette.ok
        case .warning: Palette.warn
        case .critical: Palette.critical
        }
    }

    private func thermalText(_ t: ThermalLevel) -> String {
        switch t {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Heiß – drosselt"
        case .critical: "Kritisch"
        }
    }

    private func powerTitle(_ s: SystemSnapshot) -> String {
        s.isOnline ? (s.power.batteryPercent == nil ? "Netz" : "Strom") : "Netz"
    }

    private func powerValue(_ s: SystemSnapshot) -> String {
        guard s.isOnline else { return "Offline" }
        guard let percent = s.power.batteryPercent else { return "Online" }
        return s.power.onBattery ? "Akku \(percent) %" : "Netzteil · \(percent) %"
    }

    private func powerSymbol(_ s: SystemSnapshot) -> String {
        guard s.isOnline else { return "wifi.slash" }
        guard let percent = s.power.batteryPercent else { return "wifi" }
        if !s.power.onBattery { return "powerplug" }
        return percent > 60 ? "battery.75percent" : percent > 25 ? "battery.50percent" : "battery.25percent"
    }
}
