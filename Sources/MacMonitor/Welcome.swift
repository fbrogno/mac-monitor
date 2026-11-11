import Foundation

/// Whether the one-time welcome window is still due.
enum Welcome {
    private static let seenKey = "welcome.seen"

    /// Decided once, at the first access, which must come before `LoginItem.enableOnFirstInstalledLaunch()`
    /// (that sets one of the markers). People who already used the app (saved settings, or the login item
    /// was set up on an earlier start) are not greeted unasked; they count as having seen it.
    static let pendingAtLaunch: Bool = {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: seenKey) { return false }
        if defaults.data(forKey: "settings.v1") != nil || defaults.bool(forKey: "loginItem.autoEnabled") {
            defaults.set(true, forKey: seenKey)
            return false
        }
        return true
    }()

    static var isPending: Bool { pendingAtLaunch && !UserDefaults.standard.bool(forKey: seenKey) }

    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }
}
