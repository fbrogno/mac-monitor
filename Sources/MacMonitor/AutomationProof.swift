import Darwin
import Foundation
import AppKit
import MonitorCore

/// `MacMonitor --automation-proof`: sends synthetic snapshots through the real `AppModel.ingest` with
/// custom rules and shows that their actions run, on a throwaway `sleep` child only. Never touches a
/// real program, sends no notification and does not open the history.
@MainActor
enum AutomationProof {
    static func run() {
        _ = NSApplication.shared    // the confirmation path opens a window through NSApp
        var failures = 0
        var children: [Process] = []
        func check(_ ok: Bool, _ text: String) {
            print((ok ? "OK   " : "FEHLT") + " " + text)
            if !ok { failures += 1 }
        }

        func child() -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["600"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            children.append(p)
            return p
        }
        func snapshot(_ pid: Int32, name: String = "sleep", cpu: Double = 99) -> SystemSnapshot {
            SystemSnapshot(date: Date(), cpuPercent: 10, memoryUsedBytes: 8_000_000_000, memoryTotalBytes: 24_000_000_000,
                           memoryPressure: .normal, swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, network: nil,
                           power: PowerState(onBattery: false, batteryPercent: 80, lowPowerMode: false),
                           processes: [ProcessStat(pid: pid, name: name, cpuPercent: cpu, footprintBytes: 1_000_000,
                                                   appKey: "proc:\(pid)", appName: name)])
        }
        func settle(until condition: () -> Bool, seconds: Double = 5) {
            let end = Date().addingTimeInterval(seconds)
            while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }

        // 1. Throttle: the child's priority drops, the log says so.
        let a = child()
        let model = AppModel(settings: MonitorSettings())
        model.settings.customRules = [CustomRule(name: "Probe drosseln", metric: .processCPU, processName: "sleep", threshold: 50,
                                                 minDuration: 0, cooldown: 0, actions: [.throttleProcess])]
        model.ingest(snapshot(a.processIdentifier))
        check(getpriority(PRIO_PROCESS, id_t(a.processIdentifier)) == 10, "Drosseln: nice-Wert des Kindprozesses ist 10")
        check(model.events.first?.condition.title.contains("gedrosselt") == true, "Drosseln: Protokolleintrag \(model.events.first?.condition.title ?? "-")")
        check(model.feedback?.text.contains("neu gestartet") == true, "Drosseln: Hinweis, dass die Drosselung bleibt")
        check(model.reported.isEmpty, "Eigene Regel taucht nicht als normale Meldung auf")

        // 2. Condition ends: a note in the log, the priority stays.
        model.ingest(snapshot(a.processIdentifier, cpu: 1))
        check(model.events.first?.condition.title.contains("Bedingung") == true, "Ende der Bedingung wird vermerkt: \(model.events.first?.condition.title ?? "-")")
        check(getpriority(PRIO_PROCESS, id_t(a.processIdentifier)) == 10, "Priorität bleibt nach Ende der Bedingung gesenkt")

        // 3. Quit without asking: the child ends.
        let b = child()
        let quitModel = AppModel(settings: MonitorSettings())
        quitModel.settings.customRules = [CustomRule(name: "Probe beenden", metric: .processCPU, processName: "sleep", threshold: 50,
                                                     minDuration: 0, cooldown: 0, actions: [.quitProcess(askFirst: false)])]
        quitModel.ingest(snapshot(b.processIdentifier))
        b.waitUntilExit()
        check(b.terminationReason == .uncaughtSignal && b.terminationStatus == SIGTERM, "Beenden: Kindprozess mit SIGTERM beendet")
        check(quitModel.events.first?.condition.title.contains("beendet") == true, "Beenden: Protokolleintrag \(quitModel.events.first?.condition.title ?? "-")")

        // 4. Quit with question: nothing happens until the user confirms.
        let c = child()
        let askModel = AppModel(settings: MonitorSettings())
        askModel.settings.customRules = [CustomRule(name: "Probe fragen", metric: .processCPU, processName: "sleep", threshold: 50,
                                                    minDuration: 0, cooldown: 0, actions: [.quitProcess(askFirst: true)])]
        askModel.openWindowAction = { _ in }
        askModel.ingest(snapshot(c.processIdentifier))
        check(askModel.pendingConfirmation != nil && c.isRunning, "Beenden mit Rückfrage: Frage steht, Prozess läuft noch")
        askModel.pendingConfirmation?.action()
        c.waitUntilExit()
        check(c.terminationStatus == SIGTERM, "Beenden mit Rückfrage: nach Bestätigung beendet")

        // 5. Reused PID: the snapshot said "node", but the PID belongs to the child "sleep": untouched.
        let d = child()
        let reuse = AppModel(settings: MonitorSettings())
        reuse.settings.customRules = [CustomRule(name: "Probe PID", metric: .processCPU, processName: "node", threshold: 50,
                                                 minDuration: 0, cooldown: 0, actions: [.quitProcess(askFirst: false)])]
        reuse.ingest(snapshot(d.processIdentifier, name: "node"))
        check(d.isRunning, "PID-Wiederverwendung: Prozess mit anderem Namen bleibt unangetastet")
        check(reuse.feedback?.isError == true, "PID-Wiederverwendung: Fehler im Protokoll: \(reuse.feedback?.text ?? "-")")

        // 6. Protected name: rejected already when planned, nothing happens.
        let e = child()
        let protected = AppModel(settings: MonitorSettings())
        protected.settings.customRules = [CustomRule(name: "Probe geschützt", metric: .processCPU, processName: "Finder", threshold: 50,
                                                     minDuration: 0, cooldown: 0, actions: [.quitProcess(askFirst: false)])]
        protected.ingest(snapshot(e.processIdentifier, name: "Finder"))
        check(e.isRunning && protected.feedback == nil, "Geschützter Name: abgelehnt, nichts passiert")

        // 7. Shortcut that does not exist: error path.
        let shortcut = AppModel(settings: MonitorSettings())
        shortcut.settings.customRules = [CustomRule(name: "Probe Kurzbefehl", metric: .cpuTotal, threshold: 1, minDuration: 0,
                                                    cooldown: 0, actions: [.runShortcut(name: "MacMonitor-Probe-gibt-es-nicht")])]
        shortcut.ingest(snapshot(1))
        settle { shortcut.feedback != nil }
        check(shortcut.feedback?.isError == true, "Kurzbefehl (nicht vorhanden): Fehler gemeldet: \(shortcut.feedback?.text ?? "-")")

        for child in children where child.isRunning { child.terminate() }
        for child in children { child.waitUntilExit() }
        print(failures == 0 ? "== Automatik-Probe bestanden ==" : "== \(failures) Prüfung(en) fehlgeschlagen ==")
        exit(failures == 0 ? 0 : 1)
    }
}
