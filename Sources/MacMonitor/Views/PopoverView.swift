import MonitorCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var sortIndex: Int
    @State private var showApps: Bool

    init(model: AppModel, onOpenSettings: @escaping () -> Void = {}, onQuit: @escaping () -> Void = {},
         showApps: Bool = false) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        _sortIndex = State(initialValue: 0)
        _showApps = State(initialValue: showApps)
    }
    @State private var hoveredPID: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let feedback = model.feedback {
                FeedbackBanner(feedback: feedback) { model.feedback = nil }
            }
            if let confirmation = model.pendingConfirmation, model.confirmationHost == .popover {
                ConfirmationStrip(confirmation: confirmation) { model.pendingConfirmation = nil }
            }
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
            Text(count == 0 ? String(localized: "Alles ruhig") : String(localized: "\(count) Auffälligkeiten"))
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
                    Button("Lösen") { model.openOverview() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.severity(c.severity))
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
                          detail: "\(s.cpuCores?.perCore.count ?? ProcessInfo.processInfo.activeProcessorCount) Kerne",
                          values: model.cpuHistory.elements, tint: Palette.load(s.cpuPercent))
                chartCard(title: "Arbeitsspeicher", value: Format.bytes(s.memoryUsedBytes),
                          detail: "von \(Format.bytes(s.memoryTotalBytes)) · \(pressureText(s.memoryPressure))",
                          values: model.memoryHistory.elements, tint: pressureColor(s.memoryPressure))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                stat("Swap", Format.bytes(s.swapUsedBytes), symbol: "arrow.left.arrow.right",
                     tint: s.swapUsedBytes > 4 * 1_073_741_824 ? Palette.warn : .secondary)
                stat("Temperatur", temperatureText(s), symbol: "thermometer.medium",
                     tint: s.thermal >= .serious ? Palette.critical : s.thermal == .fair ? Palette.warn : .secondary)
                if let gpu = s.gpu {
                    stat("GPU", Format.percent(gpu.utilizationPercent), symbol: "display",
                         tint: gpu.utilizationPercent >= 85 ? Palette.warn : .secondary)
                }
                if let watts = s.powerDraw?.systemWatts {
                    stat("Leistung", Format.watts(watts), symbol: "bolt.fill", tint: .secondary)
                }
                if let fan = s.fans.map(\.rpm).max() {
                    stat("Lüfter", Format.rpm(fan), symbol: "fanblades", tint: .secondary)
                }
                stat("SSD frei", s.disk.map { Format.bytes($0.availableBytes) } ?? "–", symbol: "internaldrive",
                     tint: (s.disk?.freeFraction ?? 1) < 0.1 ? Palette.warn : .secondary)
                stat("Netzwerk", networkValue(s), symbol: s.isOnline ? "arrow.up.arrow.down" : "wifi.slash",
                     tint: s.isOnline ? .secondary : Palette.critical)
                if s.power.batteryPercent != nil {
                    stat(batteryTitle(s.power), batteryValue(s.power), symbol: batterySymbol(s.power),
                         tint: (s.power.batteryPercent ?? 100) <= 15 && s.power.onBattery ? Palette.critical : .secondary)
                        .help(s.power.health.map { String(localized: "Akkuzustand \($0.capacityPercent) % der ursprünglichen Kapazität, \($0.cycleCount) Ladezyklen") } ?? "")
                }
                let blockers = visibleBlockers(s)
                stat("Ruhezustand", sleepValue(blockers), symbol: blockers.isEmpty ? "moon.zzz" : "cup.and.saucer",
                     tint: blockers.isEmpty ? .secondary : Palette.warn)
            }
        }
    }

    private func chartCard(title: LocalizedStringKey, value: String, detail: LocalizedStringKey, values: [Double], tint: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Sparkline(values: values, tint: tint).frame(height: 30).padding(.top, 2)
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, symbol: String, tint: Color) -> some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
    }

    // MARK: Processes

    private func processes(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MiniSegment(options: [String(localized: "Prozesse"), String(localized: "Apps")],
                            selection: Binding(get: { showApps ? 1 : 0 }, set: { showApps = $0 == 1 }))
                Spacer()
                MiniSegment(options: ["CPU", "RAM"], selection: $sortIndex)
            }
            VStack(spacing: 0) {
                if showApps {
                    let apps = AppGrouping.aggregate(s.processes)
                    let rows = sortIndex == 0 ? apps : apps.sorted { $0.footprintBytes > $1.footprintBytes }
                    ForEach(rows.prefix(6)) { app in appRow(app) }
                } else {
                    let rows = sortIndex == 0
                        ? Array(s.processes.prefix(6))
                        : Array(s.processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(6))
                    ForEach(rows) { p in processRow(p) }
                }
            }
        }
    }

    private func appRow(_ app: AppUsage) -> some View {
        HStack(spacing: 8) {
            Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if app.pids.count > 1 {
                Text("\(app.pids.count)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(Format.percent(app.cpuPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(app.cpuPercent >= 90 ? Palette.critical : .primary)
                .frame(width: 52, alignment: .trailing)
            Text(Format.bytes(app.footprintBytes))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Color.clear.frame(width: 12)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
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
            Button { model.confirmKill(ProcessRef(p), host: .popover) } label: {
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
                    Text(e.kind == .resolved ? String(localized: "Behoben: \(e.condition.title)") : e.condition.title)
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
            FooterButton(title: "Übersicht", symbol: "square.grid.2x2", action: { model.openOverview() })
            FooterButton(title: "Dashboard", symbol: "chart.xyaxis.line", action: { model.openDashboard() })
            FooterButton(title: "Einstellungen", symbol: "gearshape", iconOnly: true, action: onOpenSettings)
            if let version = model.updater.availableVersion {
                FooterButton(title: "Update \(version)", symbol: "arrow.down.circle", action: { model.updater.checkForUpdates() })
            }
            Spacer()
            FooterButton(title: "Beenden", symbol: "power", iconOnly: true, action: onQuit)
        }
    }

    // MARK: Text helpers

    private func pressureText(_ p: MemoryPressure) -> String {
        switch p {
        case .normal: String(localized: "Druck normal")
        case .warning: String(localized: "Druck erhöht")
        case .critical: String(localized: "Druck kritisch")
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
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Heiß – drosselt")
        case .critical: String(localized: "Kritisch")
        }
    }

    private func temperatureText(_ s: SystemSnapshot) -> String {
        guard let celsius = s.thermals?.cpuAverageCelsius ?? s.thermals?.cpuMaxCelsius else { return thermalText(s.thermal) }
        return s.thermal == .nominal ? Format.celsius(celsius) : "\(Format.celsius(celsius)) · \(thermalText(s.thermal))"
    }

    private func networkValue(_ s: SystemSnapshot) -> String {
        guard s.isOnline else { return String(localized: "Offline") }
        guard let n = s.network else { return String(localized: "Online") }
        return "↓ \(Format.rate(n.downBytesPerSecond))  ↑ \(Format.rate(n.upBytesPerSecond))"
    }

    private func batteryTitle(_ p: PowerState) -> LocalizedStringKey {
        guard let health = p.health else { return "Akku" }
        return "Akku · \(health.capacityPercent) %"
    }

    private func batteryValue(_ p: PowerState) -> String {
        let percent = Format.percent(Double(p.batteryPercent ?? 0))
        if p.onBattery, let minutes = p.minutesRemaining { return "\(percent) · \(Format.hoursMinutes(minutes))" }
        if !p.onBattery {
            return p.isCharging ? String(localized: "\(percent) · lädt") : String(localized: "\(percent) · Netzteil")
        }
        return percent
    }

    private func batterySymbol(_ p: PowerState) -> String {
        if !p.onBattery { return p.isCharging ? "battery.100percent.bolt" : "powerplug" }
        let percent = p.batteryPercent ?? 100
        return percent > 60 ? "battery.75percent" : percent > 25 ? "battery.50percent" : "battery.25percent"
    }

    private func visibleBlockers(_ s: SystemSnapshot) -> [SleepBlocker] {
        let ignored = Set(model.settings.ignoredProcesses.map { $0.lowercased() })
        return s.sleepBlockers.filter { !ignored.contains($0.name.lowercased()) }
    }

    private func sleepValue(_ blockers: [SleepBlocker]) -> String {
        guard let first = blockers.first else { return String(localized: "möglich") }
        let more = blockers.count > 1 ? " +\(blockers.count - 1)" : ""
        return String(localized: "blockiert: \(first.name)\(more)")
    }
}
