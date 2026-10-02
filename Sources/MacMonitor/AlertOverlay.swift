import AppKit
import MonitorCore
import SwiftUI

/// Shows `AlertHUDView` in a borderless, non-activating panel at the top right of the screen the
/// pointer is on. Complements notification banners, which macOS only shows on the main display.
@MainActor
final class AlertOverlay {
    var onKill: ((ProcessRef) -> Void)?
    var onMute: ((String) -> Void)?
    var onOpen: (() -> Void)?

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ event: AlertEvent, mode: OverlayMode) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        // NSScreen.screens[0] is the display with the menu bar, where macOS shows banners.
        guard mode.shouldShow(pointerOnMainScreen: screen == NSScreen.screens.first) else { return }

        hide(animated: false)

        let view = AlertHUDView(
            event: event,
            onKill: { [weak self] ref in self?.hide(animated: true); self?.onKill?(ref) },
            onMute: { [weak self] name in self?.hide(animated: true); self?.onMute?(name) },
            onClose: { [weak self] in self?.hide(animated: true) },
            onOpen: { [weak self] in self?.hide(animated: true); self?.onOpen?() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        let seconds: UInt64 = event.condition.severity == .critical ? 30 : 12
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}
