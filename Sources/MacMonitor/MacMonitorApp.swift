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

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                model: delegate.model,
                onOpenSettings: { delegate.model.open(delegate.model.lastSettingsSection) },
                onQuit: { NSApp.terminate(nil) })
            .onAppear { delegate.model.isPopoverOpen = true }
            .onDisappear { delegate.model.isPopoverOpen = false }
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        // The one window. It does not open at launch (menu bar app); everything leads here.
        Window("MacMonitor", id: "main") {
            MainWindowView(model: delegate.model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commands { MainCommands(model: delegate.model) }
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

    /// Clicking the Dock icon, or starting the app again from Finder, brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.isMainWindowVisible { model.showMainWindow() }
        return true
    }

    /// `open macmonitor://test|overview|cleanup|welcome|about|settings[/<Reiter>]|dashboard[/<Bereich>]|open/<Bereich>`
    /// — from scripts, widgets, shortcuts and the terminal.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let route = AppRoute.resolve(url, current: model.section, lastSettings: model.lastSettingsSection) else { continue }
            model.handle(route)
        }
    }
}

/// The menu of the regular app: shown while the main window is open.
struct MainCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .appInfo) {
            Button("Über MacMonitor") { model.open(.about) }
            Button("Nach Updates suchen …") { model.updater.checkForUpdates() }
                .disabled(!model.updater.isConfigured)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Einstellungen …") { model.open(model.section.isSettings ? model.section : model.lastSettingsSection) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Verlauf exportieren …") { model.open(.data) }
            Button("Fenster schließen") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(SidebarGroup.allCases.filter { $0 != .settings }) { group in
                ForEach(group.sections) { section in
                    if let key = section.shortcutKey {
                        Button(section.title) { model.open(section) }.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    } else {
                        Button(section.title) { model.open(section) }
                    }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Link("MacMonitor auf GitHub", destination: AppLinks.github)
        }
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.menuBarAlert == nil ? "waveform.path.ecg" : "exclamationmark.triangle.fill")
            if !model.menuBarText.isEmpty {
                Text(model.menuBarText).monospacedDigit()
            }
        }
        // The label exists for the app's whole lifetime, so it is the place to hand the
        // window opener to code outside SwiftUI (notifications, alert panel, links).
        .onAppear {
            model.openWindowAction = { id in
                NSApp.setActivationPolicy(.regular)
                openWindow(id: id)
            }
        }
    }
}
