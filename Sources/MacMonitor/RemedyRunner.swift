import AppKit
import Darwin
import MonitorCore

/// Executes `RemedyAction`s. Everything that ends a process or touches the network asks first
/// (see `ask(_:)`).
@MainActor
extension AppModel {
    func canPerform(_ action: RemedyAction) -> Bool {
        if case .restartApp(let ref) = action { return Self.owningApp(of: ref.pid) != nil }
        return true
    }

    func title(for action: RemedyAction) -> String {
        switch action {
        case .restartApp(let ref):
            let app = Self.owningApp(of: ref.pid)?.localizedName ?? ref.name
            return "\(app) neu starten"
        case .quit: return "Beenden"
        case .forceQuit: return "Sofort beenden"
        case .mute: return "1 h stumm"
        case .ignoreForever: return "Nie mehr melden"
        case .showCleanup: return "SSD aufräumen"
        case .openStorageSettings: return "Speicherverwaltung"
        case .openActivityMonitor: return "Aktivitätsanzeige"
        case .restartWiFi: return "WLAN neu starten"
        case .openNetworkSettings: return "Netzwerk-Einstellungen"
        }
    }

    func perform(_ action: RemedyAction) {
        switch action {
        case .restartApp(let ref):
            restartApp(ref)
        case .quit(let ref):
            confirmKill(ref)
        case .forceQuit(let ref):
            ask(Confirmation(title: "„\(ref.name)“ sofort beenden?",
                             message: "Der Prozess bekommt keine Gelegenheit zu speichern.",
                             confirmTitle: "Sofort beenden",
                             action: { [weak self] in self?.signal(ref, SIGKILL) }))
        case .mute(let name):
            mute(name)
        case .ignoreForever(let name):
            if !settings.ignoredProcesses.contains(name) { settings.ignoredProcesses.append(name) }
            requestSample()
        case .showCleanup:
            openOverview(section: .cleanup)
        case .openStorageSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        case .openActivityMonitor:
            openActivityMonitor()
        case .restartWiFi:
            restartWiFi()
        case .openNetworkSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        }
    }

    /// The GUI app a process belongs to: the process itself, or the `.app` bundle its
    /// executable lives in (so a "Google Chrome Helper" maps to Google Chrome).
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy == .regular {
            return app
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        guard let id = Bundle(path: bundlePath)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.activationPolicy == .regular }
    }

    private func restartApp(_ ref: ProcessRef) {
        guard let app = Self.owningApp(of: ref.pid), let url = app.bundleURL else { return }
        let name = app.localizedName ?? ref.name
        ask(Confirmation(
            title: "\(name) neu starten?",
            message: "Die App wird beendet und sofort wieder geöffnet. Sie fragt selbst nach, falls etwas ungespeichert ist.",
            confirmTitle: "Neu starten", isDestructive: false,
            action: { [weak self] in
                // The question may have been open for a while: is this still the process that was meant?
                guard ProcessControl.isRunning(ref) else {
                    self?.feedback = Feedback(text: "„\(ref.name)“ läuft schon nicht mehr.")
                    return
                }
                app.terminate()
                Task { @MainActor in
                    // Give the app up to 20 s to quit (it may show its own save dialog).
                    for _ in 0..<40 where !app.isTerminated {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    guard app.isTerminated else { return }
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    self?.requestSample()
                }
            }))
    }

    private func restartWiFi() {
        ask(Confirmation(
            title: "WLAN neu starten?", message: "Das WLAN wird für etwa 3 Sekunden ausgeschaltet.",
            confirmTitle: "Neu starten", isDestructive: false,
            action: {
                Task.detached {
                    let device = Self.wifiDevice() ?? "en0"
                    Self.networksetup(["-setairportpower", device, "off"])
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    Self.networksetup(["-setairportpower", device, "on"])
                }
            }))
    }

    nonisolated private static func wifiDevice() -> String? {
        let output = networksetup(["-listallhardwareports"])
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("WLAN") }),
              index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") else { return nil }
        return String(lines[index + 1].dropFirst("Device: ".count))
    }

    @discardableResult
    nonisolated private static func networksetup(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

}
