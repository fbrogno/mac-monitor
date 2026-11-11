import Foundation
import MonitorCore

enum SettingsStore {
    private static let key = "settings.v1"

    static func load() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) else {
            return MonitorSettings()
        }
        return settings
    }

    static func save(_ settings: MonitorSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Keeps when the rules with a long reminder interval (battery health, SSD wear) last reported, so the note
/// is not repeated after every launch. A small table of key and time, trimmed by `AlertEngine`.
enum AlertStateStore {
    private static let key = "alerts.lastReported.v1"

    static func load() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func save(_ table: [String: Date]) {
        UserDefaults.standard.set(table.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
