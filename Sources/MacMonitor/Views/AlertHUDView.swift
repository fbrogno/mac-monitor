import MonitorCore
import SwiftUI

/// Content of MacMonitor's own alert panel. Pure SwiftUI so the README image comes from this view.
struct AlertHUDView: View {
    let event: AlertEvent
    var onKill: (ProcessRef) -> Void = { _ in }
    var onMute: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var hoveringClose = false

    private var condition: Condition { event.condition }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.kind == .reminder ? "Immer noch: \(condition.title)" : condition.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Color.primary.opacity(hoveringClose ? 0.15 : 0.07), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onHover { hoveringClose = $0 }
                }
                Text(condition.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let process = condition.process {
                    HStack(spacing: 8) {
                        action("Beenden …", tint: Palette.critical) { onKill(process) }
                        action("1 h stumm") { onMute(process.name) }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.severity(condition.severity))
                .frame(width: 3).padding(.vertical, 18).padding(.leading, 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func action(_ title: String, tint: Color = .primary, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
