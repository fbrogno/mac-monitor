import Foundation

/// Every area of the main window. One list, in the order of the sidebar: the order also numbers the
/// shortcuts ⌘1 … ⌘9 (the tenth is ⌘0). The raw value is what is stored between launches.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview, issues, apps
    case cpu, memory, energy, sensors, network, events, report
    case cleanup
    case general, menuBar, rules, customRules, quiet, ignored, data, about

    public var id: String { rawValue }

    public var group: SidebarGroup {
        switch self {
        case .overview, .issues, .apps: .monitor
        case .cpu, .memory, .energy, .sensors, .network, .events, .report: .history
        case .cleanup: .tools
        case .general, .menuBar, .rules, .customRules, .quiet, .ignored, .data, .about: .settings
        }
    }

    public var isSettings: Bool { group == .settings }

    /// Areas that draw measurements over a time range; only these show the range switch.
    public var usesRange: Bool {
        switch self {
        case .overview, .apps, .cpu, .memory, .energy, .sensors, .network, .events: true
        default: false
        }
    }

    /// The report has its own period (day or week) instead of the range.
    public var usesReportPeriod: Bool { self == .report }

    public var title: String {
        switch self {
        case .overview: L("Überblick")
        case .issues: L("Auffälligkeiten")
        case .apps: L("Apps & Prozesse")
        case .cpu: L("CPU & GPU")
        case .memory: L("Speicher")
        case .energy: L("Energie & Akku")
        case .sensors: L("Sensoren")
        case .network: L("Netzwerk & Laufwerke")
        case .events: L("Ereignisse")
        case .report: L("Bericht")
        case .cleanup: L("SSD aufräumen")
        case .general: L("Allgemein")
        case .menuBar: L("Menüleiste")
        case .rules: L("Regeln")
        case .customRules: L("Eigene Regeln")
        case .quiet: L("Ruhe")
        case .ignored: L("Ignoriert")
        case .data: L("Daten")
        case .about: L("Updates & Info")
        }
    }

    /// One line under the title in the window's title bar.
    public var subtitle: String {
        switch self {
        case .overview: L("Aktuelle Werte und Verlauf")
        case .issues: L("Was gerade auffällt und wie du es löst")
        case .apps: L("Verbrauch nach App")
        case .cpu: L("Auslastung, Kerne und Grafikprozessor")
        case .memory: L("Belegung, Druck und Swap")
        case .energy: L("Leistungsaufnahme und Akku")
        case .sensors: L("Temperaturen, Lüfter und SSD-Zustand")
        case .network: L("Datendurchsatz und Speicherplatz")
        case .events: L("Vorfälle und Protokoll")
        case .report: L("Auswertung, Export und Verlauf verwalten")
        case .cleanup: L("Platz schaffen, ohne eigene Dateien anzufassen")
        case .general, .menuBar, .rules, .customRules, .quiet, .ignored, .data, .about: ""
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .issues: "exclamationmark.triangle"
        case .apps: "app.badge"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .energy: "bolt"
        case .sensors: "thermometer.medium"
        case .network: "network"
        case .events: "bell"
        case .report: "doc.text"
        case .cleanup: "internaldrive"
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .rules: "bell.badge"
        case .customRules: "wand.and.stars"
        case .quiet: "moon"
        case .ignored: "eye.slash"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    /// Key of the shortcut ⌘<key> that jumps to this area, nil beyond the first ten.
    public var shortcutKey: Character? {
        guard let index = Self.allCases.firstIndex(of: self), index < 10 else { return nil }
        return index == 9 ? "0" : Character(String(index + 1))
    }

    /// Words (besides the title) under which the area is found by the search field.
    public var keywords: [String] {
        switch self {
        case .overview: [L("Kacheln"), L("Live"), L("Laufzeit"), L("Last")]
        case .issues: [L("Warnung"), L("Problem"), L("Lösen"), L("Ruhezustand"), L("Alles ruhig")]
        case .apps: [L("Prozesse"), L("Beenden"), L("Neu starten"), L("Verbraucher")]
        case .cpu: [L("Prozessor"), L("Grafik"), L("Kerne"), L("Auslastung"), L("Last")]
        case .memory: [L("RAM"), L("Arbeitsspeicher"), L("Swap"), L("Speicherdruck")]
        case .energy: [L("Akku"), L("Strom"), L("Watt"), L("Batterie"), L("Ladezyklen")]
        case .sensors: [L("Temperatur"), L("Lüfter"), L("Hitze"), L("SSD-Zustand")]
        case .network: [L("Internet"), L("WLAN"), L("Festplatte"), L("Laufwerke"), L("Datenträger")]
        case .events: [L("Vorfälle"), L("Protokoll"), L("Log")]
        case .report: [L("Zusammenfassung"), L("Export"), L("Tag"), L("Woche"), L("Vergleich")]
        case .cleanup: [L("Cache"), L("Speicherplatz"), L("Platz"), L("Papierkorb"), L("Aufräumen"), L("Festplatte voll")]
        case .general: [L("Anmelden"), L("Autostart"), L("Mitteilungen"), L("Hinweisfenster"), L("Sprache"), L("Erinnerung"), L("Testmitteilung")]
        case .menuBar: [L("Symbol"), L("Menüleiste anzeigen"), L("Text in der Menüleiste"), L("Tastenkürzel"), L("Kurzbefehl")]
        case .rules: [L("Schwellenwert"), L("Grenzwert"), L("Dauer"), L("Meldung"), L("Warnungen ein- und ausschalten")]
        case .customRules: [L("Automatik"), L("Aktion"), L("Bedingung"), L("Vorlage"), L("Drosseln")]
        case .quiet: [L("Ruhezeiten"), L("Nicht stören"), L("Ton"), L("Banner"), L("Nacht")]
        case .ignored: [L("Ausnahmen"), L("Stummgeschaltet"), L("Ausgeblendet")]
        case .data: [L("Verlauf löschen"), L("Export"), L("Import"), L("CSV"), L("JSON"), L("Sichern"), L("Aufbewahrung")]
        case .about: [L("Update"), L("Version"), L("Lizenz"), L("Datenschutz"), L("GitHub"), L("Willkommen"), L("Über")]
        }
    }

    // MARK: - Names in URLs and stored values

    /// Further spellings accepted in `macmonitor://` links, lower case and without umlauts.
    private var aliases: [String] {
        switch self {
        case .overview: ["ueberblick", "uebersicht-live"]
        case .issues: ["auffaelligkeiten", "uebersicht", "meldungen"]
        case .apps: ["prozesse", "apps-prozesse"]
        case .memory: ["speicher", "ram"]
        case .energy: ["energie", "akku"]
        case .network: ["netzwerk", "laufwerke"]
        case .events: ["ereignisse"]
        case .report: ["bericht"]
        case .cleanup: ["aufraeumen", "werkzeuge", "ssd"]
        case .general: ["allgemein"]
        case .menuBar: ["menueleiste", "menuebar"]
        case .rules: ["regeln"]
        case .customRules: ["eigene-regeln", "eigene"]
        case .quiet: ["ruhe"]
        case .ignored: ["ignoriert"]
        case .data: ["daten"]
        case .about: ["info", "updates", "ueber"]
        case .cpu, .sensors: []
        }
    }

    /// The area a link or a stored value names: the raw value, a German or English alias, any case.
    public init?(slug: String) {
        let key = Self.fold(slug).replacingOccurrences(of: "_", with: "-")
        if let match = Self.allCases.first(where: { Self.fold($0.rawValue) == key || $0.aliases.contains(key) }) {
            self = match
        } else {
            return nil
        }
    }

    /// "ü" → "ue" etc., so "Menüleiste" and "menueleiste" are the same slug.
    private static func fold(_ text: String) -> String {
        var s = text.lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { s = s.replacingOccurrences(of: from, with: to) }
        return s
    }

    /// The area stored by an earlier launch. Unknown or missing values (a renamed area, a damaged
    /// preference) open the overview instead of failing; the old per-window names also count
    /// ("dashboard/cpu", "settings/rules").
    public static func restored(from stored: String?) -> AppSection {
        guard let stored, !stored.isEmpty else { return .overview }
        let last = stored.split(whereSeparator: { "/.:".contains($0) }).last.map(String.init) ?? stored
        return AppSection(slug: last) ?? .overview
    }
}

public enum SidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case monitor, history, tools, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .monitor: L("Monitor")
        case .history: L("Verlauf")
        case .tools: L("Werkzeuge")
        case .settings: L("Einstellungen")
        }
    }

    public var sections: [AppSection] { AppSection.allCases.filter { $0.group == self } }
}

// MARK: - Links

/// What a `macmonitor://` link asks for.
public enum AppRoute: Equatable, Sendable {
    case section(AppSection)
    case welcome
    case test

    /// `macmonitor://test|overview|cleanup|welcome|about|settings[/<Reiter>]|dashboard[/<Bereich>]|open/<Bereich>`.
    /// `overview` is the list of issues (the old "Übersicht"); `dashboard` and `settings` without a name keep
    /// the area the window shows if it fits (the last settings area otherwise).
    public static func resolve(_ url: URL, current: AppSection = .overview, lastSettings: AppSection = .general) -> AppRoute? {
        guard url.scheme?.lowercased() == "macmonitor", let host = url.host?.lowercased() else { return nil }
        let slug = url.pathComponents.dropFirst().first.flatMap { $0 == "/" ? nil : $0 }
        let named = slug.flatMap { AppSection(slug: $0) }
        switch host {
        case "test": return .test
        case "overview": return .section(.issues)
        case "cleanup": return .section(.cleanup)
        case "welcome": return .welcome
        case "about": return .section(.about)
        case "settings":
            if let named, named.isSettings { return .section(named) }
            return .section(current.isSettings ? current : lastSettings)
        case "dashboard":
            if let named, !named.isSettings { return .section(named) }
            return .section(current.group == .monitor || current.group == .history ? current : .overview)
        case "open":
            return .section(named ?? current)
        default: return nil
        }
    }
}

// MARK: - Search

/// The search field of the main window: finds areas (also settings) by title and keyword.
public enum SectionSearch {
    /// Areas matching every word of `query`, best first: title before keyword, earlier in the list before later.
    public static func matches(_ query: String, in sections: [AppSection] = AppSection.allCases) -> [AppSection] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(AppSection, Int, Int)] = []
        for (index, section) in sections.enumerated() {
            let title = normalized(section.title)
            let group = normalized(section.group.title)
            let keywords = section.keywords.map(normalized)
            var score = 0
            var all = true
            for word in words {
                if title.hasPrefix(word) || title.contains(" \(word)") { score += 0 }
                else if title.contains(word) { score += 1 }
                else if keywords.contains(where: { $0.hasPrefix(word) || $0.contains(" \(word)") }) { score += 2 }
                else if keywords.contains(where: { $0.contains(word) }) { score += 3 }
                else if group.hasPrefix(word) { score += 4 }
                else { all = false; break }
            }
            if all { scored.append((section, score, index)) }
        }
        return scored.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }

    /// Lower case, without accents, single spaces.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True when `text` contains every word of `query` (the filter of the app list).
    public static func filter(_ text: String, by query: String) -> Bool {
        let words = normalized(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let haystack = normalized(text)
        return words.allSatisfy { haystack.contains($0) }
    }
}
