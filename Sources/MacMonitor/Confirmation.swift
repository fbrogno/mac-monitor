import MonitorCore
import SwiftUI

/// A question shown inside MacMonitor's own UI before something irreversible happens.
/// Replaces modal `NSAlert`s, which closed the popover and rendered poorly for a menu bar app.
struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive = true
    /// Optional second way to confirm, e.g. „Sofort beenden“.
    var alternativeTitle: String?
    var alternative: (() -> Void)?
    let action: () -> Void
}

enum ConfirmationHost {
    case popover, overview
}

/// Inline confirmation for the popover, so answering it does not close the popover.
struct ConfirmationStrip: View {
    let confirmation: Confirmation
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmation.title).font(.system(size: 12, weight: .semibold))
            Text(confirmation.message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ActionButton(title: confirmation.confirmTitle,
                             tint: confirmation.isDestructive ? Palette.critical : Palette.accent, prominent: true) {
                    confirmation.action()
                    onFinish()
                }
                if let title = confirmation.alternativeTitle, let alternative = confirmation.alternative {
                    ActionButton(title: title, tint: Palette.critical) {
                        alternative()
                        onFinish()
                    }
                }
                Spacer()
                ActionButton(title: "Abbrechen", action: onFinish)
            }
        }
        .padding(12)
        .background(Palette.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.warn.opacity(0.35)))
    }
}

extension View {
    /// Presents the model's pending confirmation as a native alert attached to this window.
    func confirmationAlert(model: AppModel, host: ConfirmationHost) -> some View {
        let isPresented = Binding(
            get: { model.pendingConfirmation != nil && model.confirmationHost == host },
            set: { if !$0 { model.pendingConfirmation = nil } })
        return alert(model.pendingConfirmation?.title ?? "", isPresented: isPresented, presenting: model.pendingConfirmation) { c in
            Button(c.confirmTitle, role: c.isDestructive ? .destructive : nil) { c.action() }
            if let title = c.alternativeTitle, let alternative = c.alternative {
                Button(title, role: .destructive) { alternative() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }
}
