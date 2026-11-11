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
                explanation: L("Der Prozess rechnet seit Minuten ununterbrochen. Entweder arbeitet er gerade einen großen Auftrag ab (Build, Export, Indexierung) oder er hängt in einer Schleife."),
                steps: [L("Arbeitet er absichtlich, warte ab oder schalte die Warnung stumm."),
                        L("Sonst beende ihn. Bei Apps reicht meist ein Neustart der App.")],
                actions: c.process.map(processActions) ?? [])
        case .memoryHog:
            return Remedy(
                explanation: L("Der Prozess belegt ungewöhnlich viel Arbeitsspeicher. Wächst das mit der Laufzeit, ist es meist ein Speicherleck."),
                steps: [L("Ein Neustart der App gibt den Speicher sofort frei."),
                        L("Bei Browsern helfen auch weniger offene Tabs.")],
                actions: c.process.map(processActions) ?? [])
        case .cpuHigh:
            return Remedy(
                explanation: L("Der Mac ist insgesamt dauerhaft ausgelastet, Apps reagieren langsamer und der Akku leert sich schneller."),
                steps: [L("Beende, was du gerade nicht brauchst. Die größten Verbraucher stehen unten.")],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .memoryPressure:
            return Remedy(
                explanation: L("Der Arbeitsspeicher wird knapp. macOS komprimiert und lagert aus, dadurch wird alles träge."),
                steps: [L("Schließe große Apps oder Browser-Tabs."),
                        L("Apps mit viel Speicher neu starten gibt ihn sofort frei.")],
                actions: [.openActivityMonitor], suspects: byMemory)
        case .swap:
            return Remedy(
                explanation: L("macOS lagert Speicher auf die SSD aus. Der Swap schrumpft erst, wenn die Apps, deren Speicher ausgelagert wurde, beendet werden."),
                steps: [L("Starte die Apps mit dem meisten Speicher neu."),
                        L("Ein Neustart des Macs leert den Swap vollständig.")],
                actions: [.openActivityMonitor], suspects: byMemory)
        case .thermal:
            return Remedy(
                explanation: L("Der Mac ist so warm, dass macOS die Leistung drosselt."),
                steps: [L("Reduziere die Last, die größten Verbraucher stehen unten."),
                        L("Lüftungsschlitze frei halten, nicht auf weicher Unterlage betreiben.")],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .disk:
            return Remedy(
                explanation: L("Bei wenig freiem Platz fehlen macOS die Reserven für Swap, Updates und Caches. Unter etwa 10 % wird der Mac spürbar langsamer."),
                steps: [L("Räume Caches auf, die sich von selbst neu aufbauen (unten unter „SSD aufräumen“)."),
                        L("Prüfe große Dateien in Downloads und Filme.")],
                actions: [.showCleanup, .openStorageSettings])
        case .network:
            return Remedy(
                explanation: L("Der Mac hat keine Verbindung ins Internet."),
                steps: [L("WLAN aus- und wieder einschalten löst die meisten Hänger."),
                        L("Hilft das nicht, Router oder Dock-Verbindung prüfen.")],
                actions: [.restartWiFi, .openNetworkSettings])
        case .sleepBlocker:
            return Remedy(
                explanation: L("Der Prozess hält den Mac wach und leert so im Akkubetrieb den Akku, auch wenn du nicht arbeitest."),
                steps: [L("Brauchst du ihn nicht mehr, beende ihn.")],
                actions: c.process.map { [.quit($0), .mute($0.name), .ignoreForever($0.name)] } ?? [])
        case .cpuTemperature:
            return Remedy(
                explanation: L("Die CPU ist ungewöhnlich heiß. Bleibt das so, drosselt macOS bald die Leistung, und der Mac wird laut."),
                steps: [L("Reduziere die Last, die größten Verbraucher stehen unten."),
                        L("Lüftungsschlitze frei halten, nicht auf weicher Unterlage betreiben.")],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .fanMaxed:
            return Remedy(
                explanation: L("Der Lüfter dreht seit Minuten fast mit voller Drehzahl. Der Mac schafft es nur mit Mühe, die Wärme loszuwerden."),
                steps: [L("Beende rechenintensive Apps, die größten Verbraucher stehen unten."),
                        L("Prüfe, ob die Lüftungsschlitze frei sind und die Umgebung nicht zu warm ist.")],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .batteryHealth:
            return Remedy(
                explanation: L("Der Akku hat durch Alterung Kapazität verloren oder macOS empfiehlt einen Service. Das ist normal, wenn der Mac schon viele Ladezyklen hinter sich hat."),
                steps: [L("Plane bei Bedarf einen Akkutausch über Apple oder einen Servicepartner."),
                        L("Bis dahin hilft es, den Mac nicht dauerhaft heiß oder bei 0 % zu betreiben.")],
                actions: [])
        case .batteryDrainOnAC:
            return Remedy(
                explanation: L("Das Netzteil liefert weniger Strom, als der Mac gerade braucht, deshalb leert sich der Akku trotz Kabel."),
                steps: [L("Nutze das Original-Netzteil mit ausreichender Leistung und ein passendes Kabel."),
                        L("Beende Apps mit hohem Verbrauch, die größten stehen unten.")],
                actions: [.openActivityMonitor], suspects: byCPU)
        case .energyHog:
            return Remedy(
                explanation: L("Die App verbraucht im Akkubetrieb viel Energie und verkürzt die Laufzeit deutlich."),
                steps: [L("Beende die App, wenn du sie gerade nicht brauchst."),
                        L("Hilft das nicht, schalte die Warnung für diese App stumm.")],
                actions: c.process.map { [.quit($0), .mute($0.name), .ignoreForever($0.name)] } ?? [])
        case .ssdWear:
            return Remedy(
                explanation: L("Die SSD meldet, dass ein großer Teil ihrer geplanten Schreibmenge verbraucht ist oder die Reserve schrumpft. Sie läuft meist noch lange, kann aber irgendwann ausfallen."),
                steps: [L("Sichere wichtige Daten regelmäßig mit Time Machine oder einem anderen Backup."),
                        L("Vermeide dauerhaft hohen Swap, indem du Apps mit viel Speicher neu startest.")],
                actions: [.openStorageSettings])
        case .volumeFull:
            return Remedy(
                explanation: L("Auf dem Volume ist kaum noch Platz frei. Dateien lassen sich dann nicht mehr speichern, und bei der Systemplatte wird der Mac langsam."),
                steps: [L("Lösche große, nicht mehr benötigte Dateien oder verschiebe sie auf ein anderes Laufwerk."),
                        L("Die Speicherverwaltung zeigt, was am meisten Platz belegt.")],
                actions: [.openStorageSettings])
        case .gpuHigh:
            return Remedy(
                explanation: L("Die Grafikeinheit ist dauerhaft stark ausgelastet. Das kostet Akku und erzeugt Wärme."),
                steps: [L("Beende grafikintensive Apps, Spiele oder Videoexporte, die du nicht brauchst.")],
                actions: [.openActivityMonitor])
        case .custom:
            return Remedy(
                explanation: L("Diese Meldung stammt aus einer eigenen Regel, die du selbst eingerichtet hast."),
                steps: [L("Passe die Regel in den Einstellungen an, wenn sie zu oft oder zu früh meldet.")],
                actions: c.process.map { [.quit($0), .mute($0.name)] } ?? [])
        }
    }
}
