import AppKit
import MonitorCore

/// Carries out what custom rules decided (`PlannedAction`): notifications, shortcuts, web addresses,
/// ending and slowing down processes. Every action ends up in the event log, errors included.
@MainActor
extension AppModel {
    func execute(_ planned: [PlannedAction], in snapshot: SystemSnapshot, quiet: QuietContext) {
        for item in planned {
            switch item.action {
            case .showNotification:
                showNotification(for: item, quiet: quiet)
            case .runShortcut(let name):
                runShortcut(name, rule: item.ruleName)
            case .openURL(let text):
                openURL(text, rule: item.ruleName)
            case .quitProcess:
                quit(item, snapshot: snapshot)
            case .throttleProcess:
                throttle(item, snapshot: snapshot)
            }
        }
    }

    // MARK: Notification

    private func showNotification(for item: PlannedAction, quiet: QuietContext) {
        let event = AlertEvent(date: Date(), kind: .fired, condition: item.condition)
        let decision = QuietPolicy.decide(severity: item.condition.severity, kind: .fired, settings: settings.quiet, context: quiet)
        notifier.deliver(event, decision: decision)
        if decision.overlay { overlay.show(event, mode: settings.overlayMode) }
        logAction("Regel „\(item.ruleName)“ hat eine Mitteilung gezeigt.")
    }

    // MARK: Shortcut

    private func runShortcut(_ name: String, rule: String) {
        Task { @MainActor [weak self] in
            let result = await ShortcutRunner.run(name: name, timeout: 60)
            switch result {
            case .success:
                self?.logAction("Regel „\(rule)“ hat den Kurzbefehl „\(name)“ ausgeführt.")
            case .failed(let message):
                self?.logAction("Regel „\(rule)“: Der Kurzbefehl „\(name)“ ist fehlgeschlagen.", detail: message, isError: true)
            case .timedOut:
                self?.logAction("Regel „\(rule)“: Der Kurzbefehl „\(name)“ wurde nach einer Minute abgebrochen.", isError: true)
            case .unavailable:
                self?.logAction("Regel „\(rule)“: Das Programm für Kurzbefehle ist auf diesem Mac nicht verfügbar.", isError: true)
            case .invalidName:
                self?.logAction("Regel „\(rule)“: Der Name des Kurzbefehls ist ungültig.", isError: true)
            }
        }
    }

    // MARK: URL

    private func openURL(_ text: String, rule: String) {
        guard let url = ActionURLPolicy.url(from: text) else {
            logAction("Regel „\(rule)“: Die Adresse „\(text)“ darf nicht geöffnet werden.", isError: true)
            return
        }
        // A web address always opens in the browser; any other scheme only if some app handles it.
        guard ActionURLPolicy.isWeb(url) || NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            logAction("Regel „\(rule)“: Kein Programm auf diesem Mac öffnet „\(text)“.", isError: true)
            return
        }
        if NSWorkspace.shared.open(url) {
            logAction("Regel „\(rule)“ hat „\(text)“ geöffnet.")
        } else {
            logAction("Regel „\(rule)“: „\(text)“ konnte nicht geöffnet werden.", isError: true)
        }
    }

    // MARK: Processes

    /// The processes of the action with the names they had in the snapshot the rule looked at;
    /// the name is what later tells a reused PID from the original process.
    private func targets(of item: PlannedAction, in snapshot: SystemSnapshot) -> [ProcessRef] {
        let names = Dictionary(snapshot.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return item.pids.compactMap { pid in names[pid].map { ProcessRef(pid: pid, name: $0) } }
    }

    private func quit(_ item: PlannedAction, snapshot: SystemSnapshot) {
        let targets = targets(of: item, in: snapshot)
        guard let main = item.process, !targets.isEmpty else { return }
        let appName = snapshot.processes.first { $0.pid == main.pid }?.appName ?? main.name
        let label = appName.isEmpty ? main.name : appName
        guard item.requiresConfirmation else {
            finishQuit(targets, rule: item.ruleName, label: label)
            return
        }
        // One open question per rule is enough.
        if pendingConfirmation?.title.contains(label) == true { return }
        let helpers = targets.count - 1
        ask(Confirmation(
            title: "„\(label)“ beenden?",
            message: helpers > 0
                ? "Die Regel „\(item.ruleName)“ möchte „\(label)“ beenden, dazu \(helpers) Hilfsprozesse. Ungesicherte Daten können verloren gehen."
                : "Die Regel „\(item.ruleName)“ möchte „\(label)“ beenden. Ungesicherte Daten können verloren gehen.",
            confirmTitle: "Beenden",
            action: { [weak self] in self?.finishQuit(targets, rule: item.ruleName, label: label) }))
    }

    /// Sends SIGTERM, main process first. Right before, every PID is checked again (protected list, still the same process).
    func finishQuit(_ targets: [ProcessRef], rule: String, label: String) {
        let results = ProcessControl.terminate(targets.filter { !isProtectedNow($0) })
        report(results, rule: rule, label: label, verb: "beendet", failure: "konnte nicht beendet werden")
        requestSample()
    }

    private func throttle(_ item: PlannedAction, snapshot: SystemSnapshot) {
        let targets = targets(of: item, in: snapshot).filter { !isProtectedNow($0) }
        guard let main = item.process, !targets.isEmpty else { return }
        let appName = snapshot.processes.first { $0.pid == main.pid }?.appName ?? main.name
        let label = appName.isEmpty ? main.name : appName
        let results = ProcessControl.throttle(targets)
        if results.contains(where: { $0.outcome == .done }) {
            throttledByRule[item.ruleID, default: []].append(label)
        }
        report(results, rule: item.ruleName, label: label, verb: "gedrosselt", failure: "konnte nicht gedrosselt werden",
               note: "Die Priorität bleibt niedrig, bis das Programm neu gestartet wird.")
    }

    /// The full protection check on the newest snapshot, for PIDs that are in it.
    private func isProtectedNow(_ ref: ProcessRef) -> Bool {
        guard let stat = snapshot?.processes.first(where: { $0.pid == ref.pid }) else { return false }
        return ProtectedProcesses.isProtected(stat)
    }

    private func report(_ results: [ProcessControl.Result], rule: String, label: String, verb: String, failure: String, note: String = "") {
        let done = results.filter { $0.outcome == .done }.count
        let reused = results.filter { if case .skipped(.pidReused) = $0.outcome { return true } else { return false } }.count
        let failed = results.filter { if case .failed = $0.outcome { return true } else { return false } }.count
        let protected = results.filter { $0.outcome == .skipped(.protected) }.count
        if done > 0 {
            var detail = [String]()
            if reused > 0 { detail.append("\(reused) Prozesse wurden übersprungen, weil ihre Nummer inzwischen ein anderes Programm betrifft.") }
            if failed > 0 { detail.append("\(failed) Prozesse ließen sich nicht ändern.") }
            if !note.isEmpty { detail.append(note) }
            let count = done > 1 ? " (\(done) Prozesse)" : ""
            logAction("Regel „\(rule)“ hat „\(label)“ \(verb)\(count).", detail: detail.joined(separator: " "), isError: failed > 0)
        } else if reused > 0 {
            logAction("Regel „\(rule)“: „\(label)“ läuft nicht mehr, die Prozessnummer gehört jetzt einem anderen Programm. Es wurde nichts verändert.", isError: true)
        } else if protected > 0 {
            logAction("Regel „\(rule)“: „\(label)“ ist geschützt und wurde nicht angefasst.", isError: true)
        } else if failed > 0 {
            logAction("Regel „\(rule)“: „\(label)“ \(failure).", isError: true)
        } else {
            logAction("Regel „\(rule)“: „\(label)“ läuft schon nicht mehr.")
        }
    }

    /// Tells in the log when the condition of a rule that slowed an app down is over: the slowdown stays.
    func noteEndedThrottles(_ events: [AlertEvent]) {
        for event in events where event.kind == .resolved {
            guard let rule = settings.customRules.first(where: { $0.conditionKey == event.condition.key }),
                  let apps = throttledByRule.removeValue(forKey: rule.id) else { continue }
            let list = Array(Set(apps)).sorted().map { "„\($0)“" }.joined(separator: ", ")
            logAction("Die Bedingung der Regel „\(rule.name)“ ist vorbei.",
                      detail: "\(list) bleibt gedrosselt, bis das Programm neu gestartet wird.")
        }
    }

    // MARK: Shortcuts and welcome

    func handle(hotKey action: HotKeyAction) {
        switch action {
        case .openPopover: togglePopover()
        case .openDashboard: openDashboard()
        case .openOverview: openOverview()
        }
    }

    /// Opens the menu bar window the way a click would: MenuBarExtra has no public call for it, so
    /// the status item's button is looked up and pressed. Without it, the overview opens instead.
    private func togglePopover() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = Self.statusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
        openOverview()
    }

    private static func statusButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews { if let found = statusButton(in: sub) { return found } }
        return nil
    }

    func showWelcomeWhenReady() {
        Task { @MainActor [weak self] in
            // The window opener exists once the menu bar item has appeared.
            for _ in 0..<20 {
                if self?.openWindowAction != nil { self?.showWindow("welcome"); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}
