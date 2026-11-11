import Foundation

/// Export and import of all settings as one JSON file.
public enum SettingsTransfer {
    public static let format = "macmonitor-settings"
    public static let version = 1

    public enum ImportError: Error, Equatable, Sendable {
        case notReadable
        case wrongFormat
        case newerVersion(Int)

        public var message: String {
            switch self {
            case .notReadable: L("Die Datei ist kein gültiges JSON und konnte nicht gelesen werden.")
            case .wrongFormat: L("Die Datei stammt nicht von MacMonitor oder enthält keine Einstellungen.")
            case .newerVersion: L("Die Datei stammt aus einer neueren Version von MacMonitor. Aktualisiere die App und versuche es erneut.")
            }
        }
    }

    public struct Imported: Sendable {
        public let settings: MonitorSettings
        /// Custom rules that were unreadable or invalid and therefore not taken over.
        public let skippedRules: Int
    }

    private struct Header: Decodable { let format: String?; let version: Int? }
    private struct Envelope: Encodable { let format: String; let version: Int; let exportedAt: Date; let settings: MonitorSettings }
    private struct Body: Decodable { let settings: MonitorSettings }

    public static func export(_ settings: MonitorSettings, date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(format: format, version: version, exportedAt: date, settings: settings))
    }

    public static func importSettings(from data: Data) throws -> Imported {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.notReadable }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == format,
              let body = try? JSONDecoder().decode(Body.self, from: data) else { throw ImportError.wrongFormat }
        if let v = header.version, v > version { throw ImportError.newerVersion(v) }

        var settings = body.settings
        let rawCount = ((object["settings"] as? [String: Any])?["customRules"] as? [Any])?.count ?? 0
        settings.customRules = settings.customRules.filter(\.isValid)
        return Imported(settings: settings, skippedRules: max(0, rawCount - settings.customRules.count))
    }
}
