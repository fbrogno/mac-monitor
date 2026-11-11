import MonitorCore
import SwiftUI

/// Every reported issue with explanation, steps and fix buttons; below it what keeps the Mac awake.
struct IssuesPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let s = model.snapshot {
                issues(s)
                sleepSection(s)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Erste Messung läuft …").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Issues

    @ViewBuilder private func issues(_ s: SystemSnapshot) -> some View {
        let leftoverSwap = s.swapUsedBytes >= UInt64(model.settings.swapThresholdGB * 1_073_741_824)
            && !model.reported.contains { $0.rule == .swap }
        if model.reported.isEmpty && !leftoverSwap {
            calm
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.reported) { condition in
                    if let remedy = model.remedy(for: condition) {
                        IssueCard(model: model, condition: condition, remedy: remedy)
                    }
                }
                if leftoverSwap {
                    let hint = Condition(
                        key: "hint.swap", rule: .swap, severity: .info,
                        title: String(localized: "Swap bei \(Format.bytes(s.swapUsedBytes)) – ein Rest früherer Speicherknappheit"),
                        body: String(localized: "Gerade ist genug Arbeitsspeicher frei, deshalb keine Warnung. Der Swap belegt aber SSD-Platz."),
                        sustain: 0)
                    IssueCard(model: model, condition: hint, remedy: Remedies.remedy(for: hint, in: s))
                }
            }
        }
    }

    private var calm: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48)).foregroundStyle(Palette.ok)
            Text("Alles ruhig").font(.title2.weight(.semibold))
            Text("MacMonitor meldet sich, sobald etwas länger aus dem Rahmen fällt.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Sleep

    @ViewBuilder private func sleepSection(_ s: SystemSnapshot) -> some View {
        let ignored = Set(model.settings.ignoredProcesses.map { $0.lowercased() })
        let blockers = s.sleepBlockers.filter { !ignored.contains($0.name.lowercased()) }
        if !blockers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ruhezustand").font(.headline)
                Text(s.power.onBattery
                     ? String(localized: "Diese Prozesse halten den Mac wach und kosten Akku:")
                     : String(localized: "Diese Prozesse halten den Mac wach (am Netzteil unkritisch):"))
                    .font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(blockers.enumerated()), id: \.offset) { index, blocker in
                        if index > 0 { Divider().opacity(0.5) }
                        blockerRow(blocker)
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func blockerRow(_ blocker: SleepBlocker) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(blocker.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(blocker.parentName.map { String(localized: "gestartet von \($0) · \(blocker.reason)") } ?? blocker.reason)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            ActionButton(title: String(localized: "Ignorieren")) { model.perform(.ignoreForever(blocker.name)) }
            ActionButton(title: String(localized: "Beenden"), tint: Palette.critical) {
                model.perform(.quit(model.processRef(pid: blocker.pid, name: blocker.name)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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

/// Fix buttons; they wrap to a second line when the page is narrow.
private struct FlowButtons: View {
    let actions: [RemedyAction]
    let model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            VStack(alignment: .leading, spacing: 6) { row }
        }
    }

    private var row: some View {
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
