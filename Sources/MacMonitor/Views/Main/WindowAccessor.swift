import AppKit
import SwiftUI

/// Connects the main window to the model: remembers the window, keeps its size and position between launches,
/// and turns the app into a regular app (Dock icon, menu bar) while the window is open.
///
/// MacMonitor is a menu bar app (`LSUIElement`, activation policy `.accessory`). Such an app is not allowed to
/// bring a window forward on recent macOS. Therefore the policy changes to `.regular` as soon as the window
/// exists and back to `.accessory` when it is closed; the app itself keeps running either way.
struct WindowAccessor: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { context.coordinator.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window, context.coordinator.window !== window { context.coordinator.attach(to: window) }
    }

    @MainActor
    final class Coordinator {
        let model: AppModel
        weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(model: AppModel) { self.model = model }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            model.mainWindow = window
            window.setFrameAutosaveName("MacMonitorMainWindow")
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = false

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed() }
            })
            becameVisible()
            refresh()
        }

        private func becameVisible() {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        }

        private func refresh() {
            guard let window else { return }
            let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
            if window.isVisible { becameVisible() }
            if model.isMainWindowVisible != visible { model.isMainWindowVisible = visible }
        }

        private func closed() {
            model.isMainWindowVisible = false
            // Only the menu bar item stays; the app keeps running.
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
