import MonitorCore
import SwiftUI

// Small building blocks shared by the monitor pages.

struct ProcessActionRow: View {
    let model: AppModel
    let process: ProcessStat
    let value: String
    @State private var hovering = false

    var body: some View {
        let ref = ProcessRef(process)
        HStack(spacing: 8) {
            Text(process.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if hovering {
                if model.canPerform(.restartApp(ref)) {
                    ActionButton(title: String(localized: "Neu starten"), compact: true) { model.perform(.restartApp(ref)) }
                }
                ActionButton(title: String(localized: "Beenden"), tint: Palette.critical, compact: true) { model.perform(.quit(ref)) }
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
    /// An already localized title (`String(localized:)`, `Confirmation`, `AppModel.title(for:)`), shown as is.
    var title: String
    var tint: Color = .primary
    var prominent = false
    var compact = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
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
