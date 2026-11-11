import Foundation
import Testing
@testable import MonitorCore

private func url(_ text: String) -> URL {
    // Umlauts in a link arrive percent-encoded from the system; do the same here.
    URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) ?? text)!
}

private func route(_ text: String, current: AppSection = .overview, lastSettings: AppSection = .general) -> AppRoute? {
    AppRoute.resolve(url(text), current: current, lastSettings: lastSettings)
}

// MARK: - Links

@Suite(.germanFormatting)
struct AppRouteTests {
    @Test func fixedCommands() {
        #expect(route("macmonitor://overview") == .section(.issues))
        #expect(route("macmonitor://cleanup") == .section(.cleanup))
        #expect(route("macmonitor://about") == .section(.about))
        #expect(route("macmonitor://welcome") == .welcome)
        #expect(route("macmonitor://test") == .test)
    }

    @Test func fixedCommandsIgnoreCurrentArea() {
        for current in AppSection.allCases {
            #expect(route("macmonitor://overview", current: current) == .section(.issues))
            #expect(route("macmonitor://cleanup", current: current) == .section(.cleanup))
        }
    }

    @Test func dashboardWithoutNameKeepsMonitorAndHistoryAreas() {
        for section in AppSection.allCases where section.group == .monitor || section.group == .history {
            #expect(route("macmonitor://dashboard", current: section) == .section(section))
            #expect(route("macmonitor://dashboard/", current: section) == .section(section))
        }
    }

    @Test func dashboardWithoutNameOtherwiseOpensOverview() {
        for section in AppSection.allCases where section.group == .tools || section.group == .settings {
            #expect(route("macmonitor://dashboard", current: section) == .section(.overview))
        }
    }

    @Test(arguments: [
        ("cpu", AppSection.cpu), ("speicher", .memory), ("ram", .memory), ("memory", .memory),
        ("energie", .energy), ("akku", .energy), ("energy", .energy),
        ("netzwerk", .network), ("laufwerke", .network), ("network", .network),
        ("sensors", .sensors), ("ereignisse", .events), ("events", .events),
        ("bericht", .report), ("report", .report),
        ("apps", .apps), ("ueberblick", .overview), ("überblick", .overview), ("%C3%BCberblick", .overview),
        ("overview", .overview), ("issues", .issues), ("auffaelligkeiten", .issues),
    ])
    func dashboardNames(name: String, expected: AppSection) {
        #expect(route("macmonitor://dashboard/\(name)") == .section(expected))
        // The current area does not matter when a name is given.
        #expect(route("macmonitor://dashboard/\(name)", current: .general) == .section(expected))
    }

    @Test func dashboardWithSettingsNameFallsBack() {
        #expect(route("macmonitor://dashboard/rules", current: .cpu) == .section(.cpu))
        #expect(route("macmonitor://dashboard/allgemein", current: .general) == .section(.overview))
    }

    @Test func dashboardWithUnknownNameFallsBack() {
        #expect(route("macmonitor://dashboard/unsinn", current: .memory) == .section(.memory))
        #expect(route("macmonitor://dashboard/unsinn", current: .quiet) == .section(.overview))
    }

    @Test func settingsWithoutNameKeepsCurrentSettingsArea() {
        for section in AppSection.allCases where section.isSettings {
            #expect(route("macmonitor://settings", current: section, lastSettings: .data) == .section(section))
        }
    }

    @Test func settingsWithoutNameOtherwiseUsesLastSettings() {
        for section in AppSection.allCases where !section.isSettings {
            #expect(route("macmonitor://settings", current: section, lastSettings: .quiet) == .section(.quiet))
            #expect(route("macmonitor://settings/", current: section, lastSettings: .ignored) == .section(.ignored))
        }
    }

    @Test(arguments: [
        ("allgemein", AppSection.general), ("general", .general),
        ("menueleiste", .menuBar), ("menüleiste", .menuBar), ("menuBar", .menuBar), ("menubar", .menuBar),
        ("regeln", .rules), ("rules", .rules),
        ("eigene-regeln", .customRules), ("eigene", .customRules), ("customRules", .customRules),
        ("ruhe", .quiet), ("quiet", .quiet), ("ignoriert", .ignored), ("ignored", .ignored),
        ("daten", .data), ("data", .data),
        ("info", .about), ("updates", .about), ("about", .about),
    ])
    func settingsNames(name: String, expected: AppSection) {
        #expect(route("macmonitor://settings/\(name)", current: .cpu, lastSettings: .data) == .section(expected))
        #expect(route("macmonitor://settings/\(name)", current: .general, lastSettings: .data) == .section(expected))
    }

    @Test func settingsWithNonSettingsNameFallsBack() {
        #expect(route("macmonitor://settings/cpu", current: .cpu, lastSettings: .quiet) == .section(.quiet))
        #expect(route("macmonitor://settings/cpu", current: .rules, lastSettings: .quiet) == .section(.rules))
        #expect(route("macmonitor://settings/unsinn", current: .apps, lastSettings: .data) == .section(.data))
    }

    @Test func openNamesEveryArea() {
        for section in AppSection.allCases {
            #expect(route("macmonitor://open/\(section.rawValue)", current: .cpu) == .section(section))
            #expect(route("macmonitor://open/\(section.rawValue.uppercased())", current: .cpu) == .section(section))
        }
    }

    @Test func openWithoutNameKeepsCurrentArea() {
        for section in AppSection.allCases {
            #expect(route("macmonitor://open", current: section) == .section(section))
            #expect(route("macmonitor://open/", current: section) == .section(section))
            #expect(route("macmonitor://open/unsinn", current: section) == .section(section))
        }
    }

    @Test func foreignSchemeOrHostIsNil() {
        #expect(route("https://overview") == nil)
        #expect(route("macmonitor2://overview") == nil)
        #expect(route("macmonitor://unknown") == nil)
        #expect(route("macmonitor://") == nil)
        #expect(route("macmonitor:overview") == nil)
        #expect(route("file:///macmonitor://overview") == nil)
    }

    @Test func caseDoesNotMatter() {
        #expect(route("MacMonitor://Overview") == .section(.issues))
        #expect(route("MACMONITOR://CLEANUP") == .section(.cleanup))
        #expect(route("macmonitor://Dashboard/CPU") == .section(.cpu))
        #expect(route("macmonitor://SETTINGS/Menüleiste".replacingOccurrences(of: "ü", with: "%C3%BC")) == .section(.menuBar))
        #expect(route("macmonitor://Settings/MENUBAR") == .section(.menuBar))
        #expect(route("macmonitor://Welcome") == .welcome)
        #expect(route("macmonitor://TEST") == .test)
    }

    @Test func trailingPathAfterNameIsIgnored() {
        #expect(route("macmonitor://dashboard/cpu/extra") == .section(.cpu))
        #expect(route("macmonitor://open/rules?x=1") == .section(.rules))
    }
}

// MARK: - Areas

@Suite(.germanFormatting)
struct AppSectionModelTests {
    @Test func everySectionHasTitleSymbolAndGroup() {
        for section in AppSection.allCases {
            #expect(!section.title.isEmpty, "\(section) has no title")
            #expect(!section.symbol.isEmpty, "\(section) has no symbol")
            #expect(SidebarGroup.allCases.contains(section.group))
            #expect(section.id == section.rawValue)
        }
    }

    @Test func rawValuesTitlesAndSymbolsAreUnique() {
        let all = AppSection.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(Set(all.map(\.title)).count == all.count)
        #expect(Set(all.map(\.symbol)).count == all.count)
    }

    @Test func rawValuesSurviveTheSlugRoundTrip() {
        for section in AppSection.allCases {
            #expect(AppSection(slug: section.rawValue) == section)
            #expect(AppSection(slug: section.rawValue.uppercased()) == section)
        }
        #expect(AppSection(slug: "") == nil)
        #expect(AppSection(slug: "unsinn") == nil)
    }

    @Test func aliasesDoNotCollideAcrossAreas() {
        // Every spelling used in a link names exactly one area.
        let spellings = ["ueberblick", "uebersicht", "auffaelligkeiten", "prozesse", "speicher", "ram", "energie", "akku",
                         "netzwerk", "laufwerke", "ereignisse", "bericht", "aufraeumen", "werkzeuge", "ssd", "allgemein",
                         "menueleiste", "regeln", "eigene-regeln", "eigene", "ruhe", "ignoriert", "daten", "info", "updates", "ueber"]
        for spelling in spellings {
            let hits = AppSection.allCases.filter { AppSection(slug: spelling) == $0 }
            #expect(hits.count == 1, "\(spelling)")
        }
    }

    @Test func shortcutKeysForTheFirstTenAreas() {
        let all = AppSection.allCases
        let expected: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        #expect(all.count > 10)
        for (index, key) in expected.enumerated() {
            #expect(all[index].shortcutKey == key)
        }
        for section in all.dropFirst(10) {
            #expect(section.shortcutKey == nil)
        }
        let keys = all.compactMap(\.shortcutKey)
        #expect(keys.count == 10)
        #expect(Set(keys).count == 10)
    }

    @Test func groupsContainEverySectionExactlyOnce() {
        let all = AppSection.allCases
        let joined = SidebarGroup.allCases.flatMap(\.sections)
        #expect(joined.count == all.count)
        #expect(Set(joined.map(\.rawValue)) == Set(all.map(\.rawValue)))
        for group in SidebarGroup.allCases {
            #expect(!group.sections.isEmpty)
            #expect(group.sections.allSatisfy { $0.group == group })
            #expect(!group.title.isEmpty)
        }
    }

    @Test func groupsFollowTheSidebarOrder() {
        // The sidebar and the numbering of the shortcuts read the same list.
        #expect(SidebarGroup.allCases.flatMap(\.sections) == AppSection.allCases)
        #expect(SidebarGroup.allCases == [.monitor, .history, .tools, .settings])
    }

    @Test func groupContents() {
        #expect(SidebarGroup.monitor.sections == [.overview, .issues, .apps])
        #expect(SidebarGroup.history.sections == [.cpu, .memory, .energy, .sensors, .network, .events, .report])
        #expect(SidebarGroup.tools.sections == [.cleanup])
        #expect(SidebarGroup.settings.sections == [.general, .menuBar, .rules, .customRules, .quiet, .ignored, .data, .about])
        #expect(SidebarGroup.settings.sections.count == 8)
    }

    @Test func isSettingsMatchesTheGroup() {
        for section in AppSection.allCases {
            #expect(section.isSettings == (section.group == .settings))
        }
    }

    @Test func rangeAndReportPeriod() {
        #expect(AppSection.report.usesReportPeriod)
        #expect(!AppSection.report.usesRange)
        for section in [AppSection.overview, .apps, .cpu, .memory, .energy, .sensors, .network, .events] {
            #expect(section.usesRange, "\(section)")
            #expect(!section.usesReportPeriod, "\(section)")
        }
        for section in AppSection.allCases where section == .issues || section == .cleanup || section.isSettings {
            #expect(!section.usesRange, "\(section)")
            #expect(!section.usesReportPeriod, "\(section)")
        }
        #expect(AppSection.allCases.filter(\.usesReportPeriod) == [.report])
    }

    @Test func subtitlesOnlyOutsideSettings() {
        for section in AppSection.allCases {
            #expect(section.subtitle.isEmpty == section.isSettings, "\(section)")
        }
    }

    @Test func everySectionHasKeywords() {
        for section in AppSection.allCases {
            #expect(!section.keywords.isEmpty, "\(section)")
        }
    }
}

// MARK: - Search

@Suite(.germanFormatting)
struct SectionSearchTests {
    @Test func titleAndKeywordFindTheArea() {
        #expect(SectionSearch.matches("cpu").first == .cpu)
        #expect(SectionSearch.matches("anmelden") == [.general])
        #expect(SectionSearch.matches("Autostart") == [.general])
        #expect(SectionSearch.matches("swap").contains(.memory))
        #expect(SectionSearch.matches("lüfter").contains(.sensors))
        #expect(SectionSearch.matches("lufter").contains(.sensors))
    }

    @Test func menuBarIsFoundWithUmlaut() {
        #expect(SectionSearch.matches("Menüleiste").first == .menuBar)
        #expect(SectionSearch.matches("menuleiste").first == .menuBar)
    }

    @Test func menuBarIsFoundWithTransliteration() {
        // Links spell it "menueleiste"; typing it in the field should work as well.
        #expect(SectionSearch.matches("menueleiste").first == .menuBar)
    }

    @Test func titleBeatsKeywordAndEarlierBeatsLater() {
        let akku = SectionSearch.matches("akku")
        #expect(akku.first == .energy)
        let ssd = SectionSearch.matches("ssd")
        #expect(ssd.first == .cleanup)
        #expect(ssd.contains(.sensors))
    }

    @Test func allWordsMustMatch() {
        #expect(SectionSearch.matches("eigene regeln") == [.customRules])
        #expect(SectionSearch.matches("regeln eigene") == [.customRules])
        #expect(SectionSearch.matches("speicher druck").first == .memory)
        #expect(SectionSearch.matches("cpu zzzzzz").isEmpty)
        #expect(SectionSearch.matches("akku zzzzzz").isEmpty)
    }

    @Test func caseAndSpacingDoNotMatter() {
        #expect(SectionSearch.matches("  CPU  ").first == .cpu)
        #expect(SectionSearch.matches("EIGENE    REGELN") == [.customRules])
        #expect(SectionSearch.matches("cpu") == SectionSearch.matches("CPU"))
    }

    @Test func emptyOrBlankQueryFindsNothing() {
        #expect(SectionSearch.matches("").isEmpty)
        #expect(SectionSearch.matches("   ").isEmpty)
        #expect(SectionSearch.matches("\n\t").isEmpty)
    }

    @Test func nonsenseFindsNothing() {
        #expect(SectionSearch.matches("xyzzyqwx").isEmpty)
        #expect(SectionSearch.matches("🙂").isEmpty)
    }

    @Test func groupNameFindsItsAreas() {
        #expect(Set(SectionSearch.matches("einstellungen")) == Set(SidebarGroup.settings.sections))
        #expect(Set(SectionSearch.matches("verlauf")).isSuperset(of: [.report]))
    }

    @Test func searchCanBeRestrictedToAList() {
        let result = SectionSearch.matches("cpu", in: [.apps, .cpu, .memory])
        #expect(result == [.cpu])
        #expect(SectionSearch.matches("cpu", in: []).isEmpty)
    }

    @Test func resultHasNoDuplicates() {
        for query in ["a", "e", "cpu", "speicher", "regeln", "daten", "info"] {
            let result = SectionSearch.matches(query)
            #expect(Set(result).count == result.count, "\(query)")
        }
    }

    @Test func everyTitleFindsItsOwnArea() {
        for section in AppSection.allCases {
            #expect(SectionSearch.matches(section.title).contains(section), "\(section)")
        }
    }

    @Test func filterRequiresEveryWord() {
        #expect(SectionSearch.filter("Google Chrome Helper", by: "chrome helper"))
        #expect(SectionSearch.filter("Google Chrome Helper", by: "helper chrome"))
        #expect(!SectionSearch.filter("Google Chrome Helper", by: "chrome safari"))
        #expect(!SectionSearch.filter("Safari", by: "chrome"))
    }

    @Test func filterIgnoresCaseAndAccents() {
        #expect(SectionSearch.filter("Müll-Helfer", by: "MULL"))
        #expect(SectionSearch.filter("photoanalysisd", by: "PHOTO"))
        #expect(SectionSearch.filter("  Safari ", by: " safari  "))
    }

    @Test func emptyFilterKeepsEverything() {
        #expect(SectionSearch.filter("Safari", by: ""))
        #expect(SectionSearch.filter("Safari", by: "   "))
        #expect(SectionSearch.filter("", by: ""))
        #expect(!SectionSearch.filter("", by: "x"))
    }
}

// MARK: - Stored selection

@Suite(.germanFormatting)
struct AppSectionRestoreTests {
    @Test func missingOrEmptyOpensOverview() {
        #expect(AppSection.restored(from: nil) == .overview)
        #expect(AppSection.restored(from: "") == .overview)
    }

    @Test func rawValuesComeBack() {
        for section in AppSection.allCases {
            #expect(AppSection.restored(from: section.rawValue) == section)
        }
    }

    @Test func unknownValuesOpenOverview() {
        for stored in ["unsinn", "   ", "/", "dashboard/", "settings/nichtda", "dashboard", "settings", "🙂", "cpu2"] {
            #expect(AppSection.restored(from: stored) == .overview, "\(stored)")
        }
    }

    @Test func oldPerWindowNamesStillWork() {
        #expect(AppSection.restored(from: "dashboard/cpu") == .cpu)
        #expect(AppSection.restored(from: "dashboard/overview") == .overview)
        #expect(AppSection.restored(from: "dashboard/memory") == .memory)
        #expect(AppSection.restored(from: "dashboard/events") == .events)
        #expect(AppSection.restored(from: "dashboard/report") == .report)
        #expect(AppSection.restored(from: "settings/rules") == .rules)
        #expect(AppSection.restored(from: "settings/menuBar") == .menuBar)
        #expect(AppSection.restored(from: "settings/customRules") == .customRules)
        #expect(AppSection.restored(from: "settings/about") == .about)
        #expect(AppSection.restored(from: "settings.quiet") == .quiet)
        #expect(AppSection.restored(from: "settings:data") == .data)
    }

    @Test func germanNamesAndCaseAreAccepted() {
        #expect(AppSection.restored(from: "energie") == .energy)
        #expect(AppSection.restored(from: "Energie") == .energy)
        #expect(AppSection.restored(from: "Menüleiste") == .menuBar)
        #expect(AppSection.restored(from: "überblick") == .overview)
        #expect(AppSection.restored(from: "ENERGY") == .energy)
        #expect(AppSection.restored(from: "eigene-regeln") == .customRules)
    }

    @Test func oldOverviewWindowMeantTheIssueList() {
        // "uebersicht" was the old alert window, now called issues.
        #expect(AppSection.restored(from: "uebersicht") == .issues)
    }
}
