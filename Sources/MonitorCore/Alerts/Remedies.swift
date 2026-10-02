import Foundation

/// Something the user can do about a condition, executed by the app.
public enum RemedyAction: Hashable, Sendable {
    /// Quit the app and open it again; only offered by the app when the process is a GUI app.
    case restartApp(ProcessRef)
    case quit(ProcessRef)
    case forceQuit(ProcessRef)
    case mute(String)
    case ignoreForever(String)
    case showCleanup
    case openStorageSettings
    case openActivityMonitor
    case restartWiFi
    case openNetworkSettings
}

/// Plain-language help for one condition: what it means, what to do, and buttons that do it.
public struct Remedy: Sendable, Equatable {
    public let explanation: String
    public let steps: [String]
    /// Actions on the condition itself.
    public let actions: [RemedyAction]
    /// Processes that are most likely the cause, each offered with its own actions.
    public let suspects: [ProcessStat]

    public init(explanation: String, steps: [String], actions: [RemedyAction], suspects: [ProcessStat] = []) {
        self.explanation = explanation
        self.steps = steps
        self.actions = actions
        self.suspects = suspects
    }
}

public enum Remedies {
    public static func remedy(for c: Condition, in s: SystemSnapshot) -> Remedy {
        let byCPU = Array(s.processes.prefix(4)).filter { $0.cpuPercent >= 5 }
        let byMemory = Array(s.processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(4))

        func processActions(_ p: ProcessRef) -> [RemedyAction] {
            [.restartApp(p), .quit(p), .forceQuit(p), .mute(p.name), .ignoreForever(p.name)]
        }

        switch c.rule {
        case .runawayProcess:
            return Remedy(
                explanation: "Der Prozess rechnet seit Minuten ununterbrochen. Entweder arbeitet er gerade einen großen Auftrag ab (Build, Export, Indexierung) oder er hängt in einer Schleife.",
                steps: ["Arbeitet er absichtlich, warte ab oder schalte die Warnung stumm.",
                        "Sonst beende ihn. Bei Apps reicht meist ein Neustart der App."],
                actions: c.process.map(processActions) ?? [])
        case .memoryHog:
            return Remedy(
                explanation: "Der Prozess belegt ungewöhnlich viel Arbeitsspeicher. Wächst das mit der Laufzeit, ist es meist ein Speicherleck.",
                steps: ["Ein Neustart der App gibt den Speicher sofort frei.",
                        "Bei Browsern helfen auch weniger offene Tabs."],
                actions: c.process.map(processActions) ?? [])
        case .cpuHigh:
            return Remedy(
                explanation: "Der Mac ist insgesamt dauerhaft ausgelastet, Apps reagieren langsamer und der Akku leert sich schneller.",
                steps: ["Beende, was du gerade nicht brauchst. Die größten Verbraucher stehen unten."],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .memoryPressure:
            return Remedy(
                explanation: "Der Arbeitsspeicher wird knapp. macOS komprimiert und lagert aus, dadurch wird alles träge.",
                steps: ["Schließe große Apps oder Browser-Tabs.",
                        "Apps mit viel Speicher neu starten gibt ihn sofort frei."],
                actions: [.openActivityMonitor], suspects: byMemory)
        case .swap:
            return Remedy(
                explanation: "macOS lagert Speicher auf die SSD aus. Der Swap schrumpft erst, wenn die Apps, deren Speicher ausgelagert wurde, beendet werden.",
                steps: ["Starte die Apps mit dem meisten Speicher neu.",
                        "Ein Neustart des Macs leert den Swap vollständig."],
                actions: [.openActivityMonitor], suspects: byMemory)
        case .thermal:
            return Remedy(
                explanation: "Der Mac ist so warm, dass macOS die Leistung drosselt.",
                steps: ["Reduziere die Last, die größten Verbraucher stehen unten.",
                        "Lüftungsschlitze frei halten, nicht auf weicher Unterlage betreiben."],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .disk:
            return Remedy(
                explanation: "Bei wenig freiem Platz fehlen macOS die Reserven für Swap, Updates und Caches. Unter etwa 10 % wird der Mac spürbar langsamer.",
                steps: ["Räume Caches auf, die sich von selbst neu aufbauen (unten unter „SSD aufräumen“).",
                        "Prüfe große Dateien in Downloads und Filme."],
                actions: [.showCleanup, .openStorageSettings])
        case .network:
            return Remedy(
                explanation: "Der Mac hat keine Verbindung ins Internet.",
                steps: ["WLAN aus- und wieder einschalten löst die meisten Hänger.",
                        "Hilft das nicht, Router oder Dock-Verbindung prüfen."],
                actions: [.restartWiFi, .openNetworkSettings])
        case .sleepBlocker:
            return Remedy(
                explanation: "Der Prozess hält den Mac wach und leert so im Akkubetrieb den Akku, auch wenn du nicht arbeitest.",
                steps: ["Brauchst du ihn nicht mehr, beende ihn."],
                actions: c.process.map { [.quit($0), .mute($0.name), .ignoreForever($0.name)] } ?? [])
        }
    }
}
