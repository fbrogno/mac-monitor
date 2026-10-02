import AppKit
import MonitorCore
import UserNotifications

/// Sends alerts as native notifications. Process alerts carry „Beenden …“ and
/// „1 h stumm“ actions; their callbacks run on the main actor.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onKill: ((ProcessRef) -> Void)?
    var onMute: ((String) -> Void)?
    private(set) var isAuthorized = false

    private enum Category {
        static let process = "process"
        static let system = "system"
    }

    private enum Action {
        static let kill = "kill"
        static let mute = "mute"
        static let activity = "activity"
    }

    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.delegate = self
        let kill = UNNotificationAction(identifier: Action.kill, title: "Beenden …", options: [.foreground, .destructive])
        let mute = UNNotificationAction(identifier: Action.mute, title: "1 h stumm", options: [])
        let activity = UNNotificationAction(identifier: Action.activity, title: "Aktivitätsanzeige", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.process, actions: [kill, mute, activity], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.system, actions: [activity], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("MacMonitor: Mitteilungen nicht erlaubt: \(error.localizedDescription)") }
            Task { @MainActor in self.isAuthorized = granted }
        }
    }

    func deliver(_ event: AlertEvent) {
        let c = event.condition
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .fired, .escalated:
            content.title = c.title
            content.body = c.body
        case .reminder:
            content.title = "Immer noch: \(c.title)"
            content.body = c.body
        case .resolved:
            // Only the end of an outage is news; other recoveries stay silent.
            guard c.rule == .network else { return }
            content.title = "Wieder online"
            content.body = "Die Internetverbindung ist zurück."
        }
        content.threadIdentifier = c.rule.rawValue
        if event.kind != .resolved {
            content.sound = c.severity == .critical ? .defaultCritical : .default
            content.interruptionLevel = c.severity == .critical ? .timeSensitive : .active
        }
        if let process = c.process, event.kind != .resolved {
            content.categoryIdentifier = Category.process
            content.userInfo = ["pid": Int(process.pid), "name": process.name]
        } else {
            content.categoryIdentifier = Category.system
        }
        // Same identifier per condition: a reminder replaces the earlier banner in the list.
        center.add(UNNotificationRequest(identifier: c.key, content: content, trigger: nil))
    }

    func sendTest() {
        deliver(AlertEvent(date: Date(), kind: .fired, condition: Condition(
            key: "test", rule: .cpuHigh, severity: .info,
            title: "MacMonitor ist bereit",
            body: "So sehen Warnungen aus. Du wirst nur gestört, wenn etwas wirklich auffällt.",
            sustain: 0)))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let pid = (info["pid"] as? Int).map(Int32.init)
        let name = info["name"] as? String
        await MainActor.run {
            switch action {
            case Action.kill:
                if let pid, let name { onKill?(ProcessRef(pid: pid, name: name)) }
            case Action.mute:
                if let name { onMute?(name) }
            case Action.activity:
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                    configuration: NSWorkspace.OpenConfiguration())
            default:
                break
            }
        }
    }
}
