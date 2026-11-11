import AppKit
import Observation
import Sparkle

/// Wraps Sparkle's standard updater for a menu bar (LSUIElement) app.
///
/// The updater only starts when the build carries a public EdDSA key (`SUPublicEDKey`);
/// without one there is nothing to verify updates against, so checking stays off.
/// Scheduled checks are "gentle": no window pops up unasked. A found update shows as a button in
/// the popover plus one notification, and the update window opens when the user asks for it.
@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Version of an update found by a scheduled check that the user has not looked at yet.
    private(set) var availableVersion: String?
    /// Called once per found scheduled update, so the app can post a notification.
    @ObservationIgnored var onScheduledUpdateFound: ((String) -> Void)?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    func start() {
        guard isConfigured, !started else { return }
        started = true
        controller.startUpdater()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Brings the app forward first: a background app's Sparkle window would otherwise open behind others.
    func checkForUpdates() {
        guard started else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// "Version 1.2.0 (123)", or a note for builds without a bundle (SwiftPM debug runs).
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return String(localized: "Entwicklungsbuild") }
        let build = info?["CFBundleVersion"] as? String
        return String(localized: "Version \(short)") + (build.map { " (\($0))" } ?? "")
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled alerts only show on their own when the app is already in focus.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Task { @MainActor in
            if state.userInitiated {
                NSApp.activate()
            } else if !handleShowingUpdate {
                availableVersion = version
                onScheduledUpdateFound?(version)
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in availableVersion = nil }
    }
}
