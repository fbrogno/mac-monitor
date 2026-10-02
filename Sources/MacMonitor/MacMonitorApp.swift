import AppKit
import MonitorCore
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-docs") {
            let dir = args.indices.contains(i + 1) ? args[i + 1] : "docs/images"
            MainActor.assumeIsolated { DocRenderer.render(to: dir) }
            return
        }
        MacMonitorApp.main()
    }
}

struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                model: delegate.model,
                onOpenSettings: {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: { NSApp.terminate(nil) })
            .onAppear { delegate.model.isPopoverOpen = true }
            .onDisappear { delegate.model.isPopoverOpen = false }
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("MacMonitor – Einstellungen", id: "settings") {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        LoginItem.enableOnFirstInstalledLaunch()
        model.start()
    }

    /// `open macmonitor://test` sends a test notification, handy from scripts and the terminal.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macmonitor" {
            switch url.host {
            case "test": model.notifier.sendTest()
            default: break
            }
        }
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.reported.isEmpty ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
            if !model.menuBarText.isEmpty {
                Text(model.menuBarText).monospacedDigit()
            }
        }
    }
}
