import AppKit
import MonitorCore
import SwiftUI

/// Apps with their helper processes: sortable, expandable, with the same actions as the overview.
struct AppsPane: View {
    let model: AppModel
    let data: DashboardData

    enum Sort: CaseIterable {
        case cpu, memory, energy, threads, disk
    }

    @State private var sort: Sort
    @State private var expanded: Set<String>
    @State private var hovered: String?

    init(model: AppModel, data: DashboardData, sort: Sort = .cpu, expanded: Set<String> = []) {
        self.model = model
        self.data = data
        _sort = State(initialValue: sort)
        _expanded = State(initialValue: expanded)
    }

    private static let nameWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = model.snapshot {
                table(s)
            } else {
                Text("Erste Messung läuft …").font(.callout).foregroundStyle(.secondary)
            }
            consumers
        }
    }

    // MARK: Table

    private func table(_ s: SystemSnapshot) -> some View {
        let apps = sorted(AppGrouping.aggregate(s.processes))
        let shown = Array(apps.prefix(30))
        return DashCard(String(localized: "Apps jetzt"), subtitle: String(localized: "\(apps.count) Apps, \(s.processes.count) Prozesse")) {
            VStack(spacing: 0) {
                headerRow
                Divider().opacity(0.5)
                ForEach(shown) { app in
                    appRow(app, in: s)
                    if expanded.contains(app.key) {
                        ForEach(members(of: app, in: s)) { process in processRow(process) }
                    }
                }
                if apps.count > shown.count {
                    Text("und \(apps.count - shown.count) weitere").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("App").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(String(localized: "CPU"), .cpu, width: 62)
            sortHeader(String(localized: "RAM"), .memory, width: 76)
            sortHeader(String(localized: "Energie"), .energy, width: 72)
            sortHeader(String(localized: "Threads"), .threads, width: 58)
            sortHeader(String(localized: "Platte"), .disk, width: 84)
            Color.clear.frame(width: 118)
        }
        .padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func sortHeader(_ title: String, _ key: Sort, width: CGFloat) -> some View {
        Button { sort = key } label: {
            HStack(spacing: 2) {
                Text(title)
                if sort == key { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(sort == key ? Color.primary : Color.secondary)
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
    }

    private func sorted(_ apps: [AppUsage]) -> [AppUsage] {
        switch sort {
        case .cpu: apps.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: apps.sorted { $0.footprintBytes > $1.footprintBytes }
        case .energy: apps.sorted { $0.energyMilliwatts > $1.energyMilliwatts }
        case .threads: apps.sorted { $0.threads > $1.threads }
        case .disk: apps.sorted { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond > $1.diskReadBytesPerSecond + $1.diskWriteBytesPerSecond }
        }
    }

    private func members(of app: AppUsage, in s: SystemSnapshot) -> [ProcessStat] {
        let pids = Set(app.pids)
        return s.processes.filter { pids.contains($0.pid) }.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func appRow(_ app: AppUsage, in s: SystemSnapshot) -> some View {
        let isOpen = expanded.contains(app.key)
        let isHovered = hovered == app.key
        let processes = app.pids.count
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                    .opacity(processes > 1 ? 1 : 0)
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if processes > 1 {
                    Text("\(processes)").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metrics(cpu: app.cpuPercent, memory: app.footprintBytes, energy: app.energyMilliwatts, threads: app.threads,
                    read: app.diskReadBytesPerSecond, write: app.diskWriteBytesPerSecond)
            actions(visible: isHovered) {
                if let lead = lead(of: app, in: s) {
                    ActionButton(title: String(localized: "Ignorieren"), compact: true) { model.perform(.ignoreForever(lead.name)) }
                    ActionButton(title: String(localized: "Beenden"), tint: Palette.critical, compact: true) {
                        model.confirmKill(ProcessRef(lead), label: app.name, helpers: processes - 1)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? app.key : (hovered == app.key ? nil : hovered) }
        .onTapGesture {
            guard processes > 1 else { return }
            if isOpen { expanded.remove(app.key) } else { expanded.insert(app.key) }
        }
    }

    private func processRow(_ p: ProcessStat) -> some View {
        let key = "pid:\(p.pid)"
        let isHovered = hovered == key
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(p.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("PID \(p.pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            metrics(cpu: p.cpuPercent, memory: p.footprintBytes, energy: p.energyMilliwatts, threads: p.threads,
                    read: p.diskReadBytesPerSecond, write: p.diskWriteBytesPerSecond, secondary: true)
            actions(visible: isHovered) {
                ActionButton(title: String(localized: "Ignorieren"), compact: true) { model.perform(.ignoreForever(p.name)) }
                ActionButton(title: String(localized: "Beenden"), tint: Palette.critical, compact: true) {
                    model.confirmKill(ProcessRef(p))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }

    private func metrics(cpu: Double, memory: UInt64, energy: Double, threads: Int, read: Double, write: Double,
                         secondary: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(Format.percent(cpu)).frame(width: 62, alignment: .trailing)
                .foregroundStyle(cpu >= 90 ? Palette.critical : secondary ? Color.secondary : Color.primary)
            Text(Format.bytes(memory)).frame(width: 76, alignment: .trailing)
            Text(energy > 0 ? Format.milliwatts(energy) : "–").frame(width: 72, alignment: .trailing)
            Text(threads > 0 ? "\(threads)" : "–").frame(width: 58, alignment: .trailing)
            Text(read + write >= 1024 ? Format.rate(read + write) : "–").frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(secondary ? Color.secondary : Color.primary)
    }

    private func actions<Content: View>(visible: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .opacity(visible ? 1 : 0)
            .frame(width: 118, alignment: .trailing)
    }

    /// The process that stands for the app: its regular application process, else the oldest one.
    private func lead(of app: AppUsage, in s: SystemSnapshot) -> ProcessStat? {
        let candidates = members(of: app, in: s)
        let regular = candidates.first { NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular }
        return regular ?? candidates.min { $0.pid < $1.pid }
    }

    // MARK: Biggest consumers

    private var consumers: some View {
        let top = data.top
        return DashCard(String(localized: "Größte Verbraucher"), subtitle: model.dashboard.range.title) {
            if top.byCPU.isEmpty && top.byMemory.isEmpty {
                Text("Noch keine Messwerte in diesem Zeitraum").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    consumerList(String(localized: "CPU-Zeit"),
                                 top.byCPU.map { ($0.group, durationText($0.cpuSeconds), $0.cpuSeconds) })
                    consumerList(String(localized: "Arbeitsspeicher (Spitze)"),
                                 top.byMemory.map { ($0.group, Format.bytes($0.peakFootprintBytes), Double($0.peakFootprintBytes)) })
                }
            }
        }
    }

    private func consumerList(_ title: String, _ rows: [(name: String, value: String, weight: Double)]) -> some View {
        let top = max(rows.map(\.weight).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(rows.prefix(6), id: \.name) { row in
                MeterBar(label: row.name, value: row.value, fraction: row.weight / top, tint: Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
