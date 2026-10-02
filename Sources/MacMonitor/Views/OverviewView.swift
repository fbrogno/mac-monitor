import MonitorCore
import SwiftUI

/// The place to understand and fix things: every reported condition with an explanation and
/// buttons that solve it, disk cleanup, the biggest consumers, sleep blockers and the history.
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                OverviewContent(model: model)
            }
            .onChange(of: model.overviewFocus) { _, focus in scroll(proxy, to: focus) }
            .onAppear {
                model.isOverviewOpen = true
                scroll(proxy, to: model.overviewFocus)
            }
            .onDisappear { model.isOverviewOpen = false }
        }
        .frame(minWidth: 640, minHeight: 560)
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    private func scroll(_ proxy: ScrollViewProxy, to section: OverviewSection?) {
        guard let section else { return }
        withAnimation { proxy.scrollTo(section, anchor: .top) }
        model.overviewFocus = nil
    }
}

/// Everything inside the overview's scroll view; rendered directly for the README.
struct OverviewContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let s = model.snapshot {
                quickStats(s)
                issuesSection(s).id(OverviewSection.issues)
                CleanupSection(model: model, disk: s.disk).id(OverviewSection.cleanup)
                consumersSection(s)
                sleepSection(s)
            }
            if !model.events.isEmpty { historySection }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    // MARK: Header

    private var header: some View {
        let count = model.reported.count
        let worst = model.reported.map(\.severity).max()
        return HStack(spacing: 14) {
            AppIconView(size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Übersicht").font(.system(size: 22, weight: .bold))
                Text(count == 0 ? "Alles in Ordnung" : count == 1 ? "1 Auffälligkeit braucht deine Aufmerksamkeit"
                                                                  : "\(count) Auffälligkeiten brauchen deine Aufmerksamkeit")
                    .font(.system(size: 13))
                    .foregroundStyle(worst.map(Palette.severity) ?? Palette.ok)
            }
            Spacer()
            if let date = model.snapshot?.date {
                Text("Stand \(date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func quickStats(_ s: SystemSnapshot) -> some View {
        HStack(spacing: 10) {
            pill("CPU", Format.percent(s.cpuPercent), Palette.load(s.cpuPercent))
            pill("Arbeitsspeicher", "\(Format.bytes(s.memoryUsedBytes)) / \(Format.bytes(s.memoryTotalBytes))",
                 s.memoryPressure == .normal ? Palette.ok : s.memoryPressure == .warning ? Palette.warn : Palette.critical)
            pill("Swap", Format.bytes(s.swapUsedBytes), s.swapUsedBytes > 4 * 1_073_741_824 ? Palette.warn : Palette.ok)
            pill("SSD frei", s.disk.map { Format.bytes($0.availableBytes) } ?? "–",
                 (s.disk?.freeFraction ?? 1) < 0.1 ? Palette.critical : Palette.ok)
            if let battery = s.power.batteryPercent {
                pill("Akku", "\(battery) %", battery <= 15 && s.power.onBattery ? Palette.critical : Palette.ok)
            }
        }
    }

    private func pill(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Issues

    private func issuesSection(_ s: SystemSnapshot) -> some View {
        let leftoverSwap = s.swapUsedBytes >= UInt64(model.settings.swapThresholdGB * 1_073_741_824)
            && !model.reported.contains { $0.rule == .swap }
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Auffälligkeiten", symbol: "exclamationmark.triangle")
            if model.reported.isEmpty && !leftoverSwap {
                calmCard
            }
            ForEach(model.reported) { condition in
                if let remedy = model.remedy(for: condition) {
                    IssueCard(model: model, condition: condition, remedy: remedy)
                }
            }
            if leftoverSwap {
                let hint = Condition(
                    key: "hint.swap", rule: .swap, severity: .info,
                    title: "Swap bei \(Format.bytes(s.swapUsedBytes)) – ein Rest früherer Speicherknappheit",
                    body: "Gerade ist genug Arbeitsspeicher frei, deshalb keine Warnung. Der Swap belegt aber SSD-Platz.",
                    sustain: 0)
                IssueCard(model: model, condition: hint, remedy: Remedies.remedy(for: hint, in: s))
            }
        }
    }

    private var calmCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Palette.ok)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keine Auffälligkeiten").font(.system(size: 13, weight: .semibold))
                Text("MacMonitor meldet sich, sobald etwas länger aus dem Rahmen fällt.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Consumers

    private func consumersSection(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Größte Verbraucher", symbol: "chart.bar")
            HStack(alignment: .top, spacing: 14) {
                consumerList("CPU", Array(s.processes.prefix(6))) { Format.percent($0.cpuPercent) }
                consumerList("Arbeitsspeicher", Array(s.processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(6))) {
                    Format.bytes($0.footprintBytes)
                }
            }
        }
    }

    private func consumerList(_ title: String, _ processes: [ProcessStat], value: @escaping (ProcessStat) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(processes) { p in
                ProcessActionRow(model: model, process: p, value: value(p))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Sleep

    private func sleepSection(_ s: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Ruhezustand", symbol: "moon.zzz")
            if s.sleepBlockers.isEmpty {
                Text("Nichts hält den Mac wach.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text(s.power.onBattery
                     ? "Diese Prozesse halten den Mac wach und kosten Akku:"
                     : "Diese Prozesse halten den Mac wach (am Netzteil unkritisch):")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(s.sleepBlockers, id: \.self) { blocker in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(blocker.name).font(.system(size: 12, weight: .medium))
                            Text(blocker.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        ActionButton(title: "Beenden", tint: Palette.critical) {
                            model.perform(.quit(ProcessRef(pid: blocker.pid, name: blocker.name)))
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Verlauf", symbol: "clock")
            ForEach(model.events) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.kind == .resolved ? "checkmark.circle.fill" : "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(e.kind == .resolved ? Palette.ok : Palette.severity(e.condition.severity))
                        .frame(width: 16)
                    Text(e.kind == .resolved ? "Behoben: \(e.condition.title)" : e.condition.title)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(e.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
    }
}

// MARK: - Building blocks

struct IssueCard: View {
    let model: AppModel
    let condition: Condition
    let remedy: Remedy

    var body: some View {
        let tint = Palette.severity(condition.severity)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: condition.severity == .critical ? "exclamationmark.octagon.fill"
                                  : condition.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(condition.title).font(.system(size: 14, weight: .semibold))
                    Text(condition.body).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(remedy.explanation).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(remedy.steps, id: \.self) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(tint)
                        Text(step).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let actions = remedy.actions.filter(model.canPerform)
            if !actions.isEmpty {
                FlowButtons(actions: actions, model: model)
            }
            if !remedy.suspects.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wahrscheinliche Ursache").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(remedy.suspects) { p in
                        ProcessActionRow(model: model, process: p,
                                         value: condition.rule == .cpuHigh || condition.rule == .thermal
                                            ? Format.percent(p.cpuPercent) : Format.bytes(p.footprintBytes))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

private struct FlowButtons: View {
    let actions: [RemedyAction]
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                ActionButton(title: model.title(for: action),
                             tint: isDestructive(action) ? Palette.critical : index == 0 ? Palette.accent : .primary,
                             prominent: index == 0) {
                    model.perform(action)
                }
            }
        }
    }

    private func isDestructive(_ action: RemedyAction) -> Bool {
        switch action {
        case .quit, .forceQuit: true
        default: false
        }
    }
}

struct ProcessActionRow: View {
    let model: AppModel
    let process: ProcessStat
    let value: String
    @State private var hovering = false

    var body: some View {
        let ref = ProcessRef(pid: process.pid, name: process.name)
        HStack(spacing: 8) {
            Text(process.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if hovering {
                if model.canPerform(.restartApp(ref)) {
                    ActionButton(title: "Neu starten", compact: true) { model.perform(.restartApp(ref)) }
                }
                ActionButton(title: "Beenden", tint: Palette.critical, compact: true) { model.perform(.quit(ref)) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ActionButton: View {
    var title: String
    var tint: Color = .primary
    var prominent = false
    var compact = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, compact ? 7 : 11)
                .padding(.vertical, compact ? 2 : 5)
                .background(prominent ? tint.opacity(hovering ? 0.85 : 1) : Color.primary.opacity(hovering ? 0.13 : 0.07),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CleanupSection: View {
    let model: AppModel
    let disk: DiskStat?

    var body: some View {
        let cleanup = model.cleanup
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SSD aufräumen", systemImage: "internaldrive").font(.system(size: 15, weight: .semibold))
                Spacer()
                if cleanup.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Messe …").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ActionButton(title: cleanup.sizes.isEmpty ? "Größen messen" : "Neu messen", compact: false) { cleanup.scan() }
                }
            }
            if let disk {
                Text("\(Format.bytes(disk.availableBytes)) von \(Format.bytes(disk.totalBytes)) frei. Alles hier baut sich bei Bedarf von selbst neu auf – deine Dateien bleiben unberührt.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(cleanup.targets) { target in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.title).font(.system(size: 12, weight: .medium))
                            Text(target.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(cleanup.sizes[target.id].map(Format.bytes) ?? "–")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle((cleanup.sizes[target.id] ?? 0) > 2 * 1_073_741_824 ? Palette.warn : .secondary)
                            .frame(width: 80, alignment: .trailing)
                        if cleanup.busyTarget == target.id {
                            ProgressView().controlSize(.small).frame(width: 84)
                        } else {
                            ActionButton(title: target.isRevealOnly ? "Öffnen" : "Aufräumen",
                                         tint: target.isRevealOnly ? .primary : Palette.accent) {
                                cleanup.clean(target) { model.confirm($0, $1, ok: $2) }
                            }
                            .frame(width: 84, alignment: .trailing)
                            .disabled(cleanup.busyTarget != nil)
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    if target.id != cleanup.targets.last?.id { Divider().opacity(0.5) }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                if cleanup.reclaimableBytes > 0 {
                    Text("Zusammen \(Format.bytes(cleanup.reclaimableBytes)) frei machbar.")
                        .font(.system(size: 12, weight: .medium))
                }
                if let freed = cleanup.lastFreed {
                    Text("\(freed.title): \(Format.bytes(freed.bytes)) freigegeben.")
                        .font(.system(size: 12)).foregroundStyle(Palette.ok)
                }
                Spacer()
                ActionButton(title: "Speicherverwaltung von macOS") { model.perform(.openStorageSettings) }
            }
        }
        .onAppear {
            // Measure automatically only when space is actually short; walking caches costs CPU.
            if cleanup.sizes.isEmpty, (disk?.freeFraction ?? 1) < 0.1 { cleanup.scan() }
        }
    }
}
