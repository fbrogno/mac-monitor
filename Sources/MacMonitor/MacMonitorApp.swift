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
        if args.contains("--automation-proof") {
            MainActor.assumeIsolated { AutomationProof.run() }
            return
        }
        if args.contains("--headless-proof") {
            MainActor.assumeIsolated { HeadlessProof.run() }
            return
        }
        if args.contains("--intent-proof") {
            MainActor.assumeIsolated { IntentProof.run() }
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
                onOpenSettings: { delegate.model.showWindow("settings") },
                onQuit: { NSApp.terminate(nil) })
            .onAppear { delegate.model.isPopoverOpen = true }
            .onDisappear { delegate.model.isPopoverOpen = false }
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("MacMonitor – Übersicht", id: "overview") {
            OverviewView(model: delegate.model)
        }
        .defaultSize(width: 760, height: 820)
        .defaultLaunchBehavior(.suppressed)

        Window("MacMonitor – Dashboard", id: "dashboard") {
            DashboardView(model: delegate.model)
        }
        .defaultSize(width: 1120, height: 780)
        .defaultLaunchBehavior(.suppressed)

        Window("MacMonitor – Einstellungen", id: "settings") {
            SettingsRoot(model: delegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Willkommen bei MacMonitor", id: "welcome") {
            WelcomeView(model: delegate.model) { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("welcome") == true }?.close() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Über MacMonitor", id: "about") {
            AboutView()
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
        _ = Welcome.pendingAtLaunch   // before the login item marker below is set
        LoginItem.enableOnFirstInstalledLaunch()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }

    /// `open macmonitor://test|overview|cleanup|welcome|about|settings[/<Reiter>]|dashboard[/<Bereich>]` — from scripts and the terminal.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macmonitor" {
            switch url.host {
            case "test": model.sendTest()
            case "overview": model.openOverview()
            case "cleanup": model.openOverview(section: .cleanup)
            case "welcome": model.showWindow("welcome")
            case "about": model.showWindow("about")
            case "settings":
                if let slug = url.pathComponents.dropFirst().first, let tab = SettingsTab(slug: slug) { model.settingsTab = tab }
                model.showWindow("settings")
            case "dashboard":
                let slug = url.pathComponents.dropFirst().first
                model.openDashboard(section: slug.flatMap(DashboardSection.init(slug:)) ?? model.dashboard.section)
            default: break
            }
        }
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.reported.isEmpty ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
            if !model.menuBarText.isEmpty {
                Text(model.menuBarText).monospacedDigit()
            }
        }
        // The label exists for the app's whole lifetime, so it is the place to hand the
        // window opener to code outside SwiftUI (notifications, alert panel).
        .onAppear { model.openWindowAction = { openWindow(id: $0) } }
    }
}
