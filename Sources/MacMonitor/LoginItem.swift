import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`. Registration only sticks for an app installed in an
/// Applications folder, so a debug build in `.build/` never registers itself.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var isInstalled: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("MacMonitor: Anmeldeobjekt konnte nicht geändert werden: \(error.localizedDescription)")
            return false
        }
    }

    /// Turns on launch-at-login once, on the first start from an installed location.
    static func enableOnFirstInstalledLaunch() {
        let flag = "loginItem.autoEnabled"
        guard isInstalled, !UserDefaults.standard.bool(forKey: flag) else { return }
        if setEnabled(true) { UserDefaults.standard.set(true, forKey: flag) }
    }
}
