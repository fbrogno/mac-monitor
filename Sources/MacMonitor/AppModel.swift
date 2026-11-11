import AppKit
import MonitorCore
import Network
import Observation
import OSLog

/// Owns sampling, alert evaluation and the state the UI shows.
///
/// Sampling runs on a private utility queue driven by a coalescing `DispatchSourceTimer`;
/// event sources (memory pressure, thermal state, network path, wake) trigger an extra
/// sample immediately instead of waiting for the next tick.
@MainActor @Observable
final class AppModel {
    private(set) var snapshot: SystemSnapshot?
    private(set) var cpuHistory = RingBuffer<Double>(capacity: 90)
    private(set) var memoryHistory = RingBuffer<Double>(capacity: 90)
    private(set) var events: [AlertEvent] = []
    /// Current conditions, titles and texts with live values: they differ on nearly every sample, so only views
    /// that show the details (popover, overview, dashboard) may read this. The menu bar reads `menuBarAlert`.
    private(set) var reported: [Condition] = [] {
        didSet {
            // Assigned only on change, so observers of `menuBarAlert` are not woken by changing numbers.
            let worst = AppModel.worstSeverity(of: reported)
            if worst != menuBarAlert { menuBarAlert = worst }
        }
    }
    /// Highest severity among the reported conditions, nil when there are none. All the menu bar symbol depends on.
    private(set) var menuBarAlert: Severity?
    var pendingConfirmation: Confirmation?
    var feedback: Feedback? {
        didSet {
            guard let current = feedback else { return }
            let seconds: UInt64 = current.action == nil ? 6 : 15
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if self?.feedback?.id == current.id { self?.feedback = nil }
            }
        }
    }
    var confirmationHost: ConfirmationHost = .window
    /// Whether the long-term history is available; set once at launch.
    private(set) var historyState: HistoryState = .starting
    /// Menu bar text, only changed when the shown value moves noticeably (see `updateMenuBarText`).
    private(set) var menuBarText = ""

    /// Area the main window shows. Set by the sidebar, links, the popover, notifications and shortcuts; the window
    /// stores it between launches (see `MainWindowView`).
    var section: AppSection = .overview {
        didSet {
            guard section != oldValue else { return }
            if section.isSettings { lastSettingsSection = section }
            if let history = section.dashboardSection { dashboard.section = history }
        }
    }
    /// The settings area ⌘, returns to.
    var lastSettingsSection: AppSection = .general
    /// The welcome sheet of the main window (first start, `macmonitor://welcome`).
    var showsWelcome = false
    /// Search text of the main window's toolbar field.
    var searchText = ""

    var settings: MonitorSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.reminderInterval = settings.reminderInterval
            SettingsStore.save(settings)
            if settings.menuBarItems != oldValue.menuBarItems { updateMenuBarText(force: true) }
            if settings.customRules != oldValue.customRules { customEvaluator.prune(keeping: settings.customRules) }
            if settings.hotKeys != oldValue.hotKeys { hotKeys.apply(settings.hotKeys) }
        }
    }

    var isPopoverOpen = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            updateDetailsVisibility()
            reschedule()
            if isPopoverOpen { requestSample() }
            // An unanswered question in the popover is dropped when it closes.
            if !isPopoverOpen, confirmationHost == .popover { pendingConfirmation = nil }
        }
    }

    /// Whether the main window is on screen (open, not minimized, not covered). The one signal for faster
    /// sampling and for loading history: with the window closed the app stays as quiet as before.
    var isMainWindowVisible = false {
        didSet {
            guard isMainWindowVisible != oldValue else { return }
            updateDetailsVisibility()
            reschedule()
            if isMainWindowVisible { requestSample() }
        }
    }

    /// Charts and history of the main window.
    @ObservationIgnored let dashboard = DashboardModel()
    @ObservationIgnored private(set) var history: HistoryPipeline?
    @ObservationIgnored private var lastIngest: Date?

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let hotKeys = HotKeyManager()
    @ObservationIgnored let quietState = QuietState()
    /// State of the custom rules (cool-downs). Pruned when the rules change.
    @ObservationIgnored private var customEvaluator = CustomRuleEvaluator()
    /// 5-minute mean power per app for the energy-hog rule.
    @ObservationIgnored private var energyAverager = EnergyAverager()
    @ObservationIgnored private var menuBar = MenuBarDisplay()
    /// Apps a rule slowed down, by rule, until its condition ends (only to note that in the log).
    @ObservationIgnored var throttledByRule: [UUID: [String]] = [:]
    @ObservationIgnored let cleanup = CleanupModel()
    @ObservationIgnored let updater = UpdateController()
    /// Set by the SwiftUI scene so non-view code can open the main window.
    @ObservationIgnored var openWindowAction: ((String) -> Void)?
    /// The main window once it exists (set by `WindowAccessor`).
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Sleep blockers the user just ended, to notice when their launcher starts them again.
    @ObservationIgnored private var endedBlockers: [String: (blocker: SleepBlocker, at: Date)] = [:]
    @ObservationIgnored private var swapHistory: [(date: Date, bytes: UInt64)] = []
    @ObservationIgnored let overlay = AlertOverlay()
    @ObservationIgnored private var engine: AlertEngine
    /// What `AlertStateStore` holds, to write only when the engine's table changed.
    @ObservationIgnored private var savedLastReported: [String: Date] = [:]
    @ObservationIgnored private var muted: [String: Date] = [:]
    /// Processes muted for now with the time the mute ends, soonest first.
    var mutedProcesses: [(name: String, until: Date)] {
        muted.filter { $0.value > Date() }.map { (name: $0.key, until: $0.value) }.sorted { $0.until < $1.until }
    }
    @ObservationIgnored private let queue = DispatchQueue(label: "macmonitor.sampling", qos: .utility)
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var currentInterval: TimeInterval = 0
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Written on `queue` by the path monitor, read on `queue` by the sampler.
    @ObservationIgnored nonisolated(unsafe) private var isOnline = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.fbrogno.macmonitor", category: "sampling")

    init(settings: MonitorSettings = SettingsStore.load()) {
        self.settings = settings
        var engine = AlertEngine(reminderInterval: settings.reminderInterval)
        engine.restore(lastReported: AlertStateStore.load(), now: Date())
        self.engine = engine
        savedLastReported = engine.lastReported
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onKill = { [weak self] ref in self?.confirmKill(ref) }
        notifier.onMute = { [weak self] name in self?.mute(name) }
        overlay.onKill = { [weak self] ref in self?.confirmKill(ref) }
        overlay.onMute = { [weak self] name in self?.mute(name) }
        overlay.onOpen = { [weak self] in self?.open(.issues) }
        notifier.onOpen = { [weak self] in self?.open(.issues) }
        notifier.onOpenUpdate = { [weak self] in self?.updater.checkForUpdates() }
        updater.onScheduledUpdateFound = { [weak self] in self?.notifier.deliverUpdate(version: $0) }
        updater.start()
        notifier.configure()
        // A first-time user is asked from the welcome window, where the question makes sense.
        if !Welcome.isPending { notifier.requestAuthorization() }
        hotKeys.onAction = { [weak self] in self?.handle(hotKey: $0) }
        hotKeys.apply(settings.hotKeys)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            guard online != self.isOnline else { return }
            self.isOnline = online
            Task { @MainActor in self.requestSample() }
        }
        pathMonitor.start(queue: queue)

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor in self?.requestSample() }
        }
        pressure.activate()
        pressureSource = pressure

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSample() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSample() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })

        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.history?.flush() }
        })

        openHistory()
        reschedule()
        requestSample()
        if Welcome.isPending { showWelcomeWhenReady() }
    }

    /// Opens the history database; without it the app keeps measuring and the dashboard says so.
    private func openHistory() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMonitor", isDirectory: true)
        do {
            let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: Date())
            history = HistoryPipeline(store: store)
            dashboard.store = store
            historyState = .active
        } catch {
            log.error("Verlauf nicht verfügbar: \(String(describing: error))")
            historyState = .unavailable("\(error)")
        }
    }

    /// Attaches a store without opening the default file (headless proof and tests).
    func useHistory(_ store: HistoryStore) {
        history = HistoryPipeline(store: store)
        dashboard.store = store
        historyState = .active
    }

    /// Writes buffered history before the app quits; gives up after `timeout` so quitting never hangs.
    func prepareForTermination(timeout: TimeInterval = 1.5) {
        history?.flushAndWait(timeout: timeout)
    }

    /// Sensors refresh faster while any window or the popover shows them.
    private func updateDetailsVisibility() {
        let visible = isPopoverOpen || isMainWindowVisible
        queue.async { [sampler] in sampler.detailsVisible = visible }
    }

    private func handleWake() {
        engine.resetPending()
        energyAverager.reset()
        queue.async { [sampler] in sampler.reset() }
        requestSample()
    }

    // MARK: - Sampling

    func requestSample() {
        queue.async { [weak self, sampler] in
            guard let self else { return }
            let snapshot = sampler.collect(isOnline: self.isOnline)
            Task { @MainActor in self.ingest(snapshot) }
        }
    }

    private func reschedule() {
        let interval = SamplingPolicy.interval(popoverOpen: isPopoverOpen || isMainWindowVisible, power: snapshot?.power ?? .unknown)
        guard interval != currentInterval else { return }
        currentInterval = interval
        log.notice("Messintervall \(interval, format: .fixed(precision: 0)) s")

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 25 % leeway lets macOS coalesce our wake-ups with other work.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
        timer.setEventHandler { [weak self, sampler] in
            guard let self else { return }
            let snapshot = sampler.collect(isOnline: self.isOnline)
            Task { @MainActor in self.ingest(snapshot) }
        }
        timer.activate()
        self.timer = timer
    }

    func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        if !endedBlockers.isEmpty { checkRespawnedBlockers(in: snapshot) }
        cpuHistory.append(snapshot.cpuPercent)
        memoryHistory.append(snapshot.memoryFraction * 100)

        let now = snapshot.date
        if let history {
            // The real time since the last sample; a gap (sleep) counts as at most three regular intervals.
            history.record(snapshot, interval: SamplingPolicy.recordedSeconds(
                elapsed: lastIngest.map { now.timeIntervalSince($0) }, nominal: currentInterval))
            lastIngest = now
        }
        muted = muted.filter { $0.value > now }
        swapHistory.append((now, snapshot.swapUsedBytes))
        swapHistory.removeAll { now.timeIntervalSince($0.date) > 600 }
        let swapLow = swapHistory.map(\.bytes).min() ?? snapshot.swapUsedBytes
        energyAverager.add(snapshot.processes, at: now)
        let context = Rules.Context(
            settings: settings,
            isActive: { [engine] in engine.isActive($0) },
            mutedProcesses: Set(muted.keys),
            swapGrowthBytes: snapshot.swapUsedBytes > swapLow ? snapshot.swapUsedBytes - swapLow : 0,
            averagedAppEnergyMilliwatts: energyAverager.averages)
        let custom = CustomRuleEvaluator.conditions(for: settings.customRules, in: snapshot, isActive: { [engine] in engine.isActive($0) })
        let conditions = Rules.evaluate(snapshot, context) + custom
        let allEvents = engine.process(conditions, now: now)
        if engine.lastReported != savedLastReported {
            savedLastReported = engine.lastReported
            AlertStateStore.save(savedLastReported)
        }
        // Custom rules show up only through their actions, never as ordinary alerts.
        let newEvents = allEvents.filter { $0.condition.rule != .custom }
        let customEvents = allEvents.filter { $0.condition.rule == .custom }
        let nowReported = engine.reported.filter { $0.rule != .custom }
        if nowReported != reported { reported = nowReported }
        updateMenuBarText(force: false)

        var overlayEvent: AlertEvent?
        let quietContext = quietState.context(now: Date())
        // "Meldungen stummschalten" (Shortcuts) silences everything; events are still logged.
        let paused = PauseState().isPaused(at: now)
        for event in newEvents {
            let decision = paused
                ? QuietDecision(banner: false, overlay: false, sound: false)
                : QuietPolicy.decide(severity: event.condition.severity, kind: event.kind,
                                     settings: settings.quiet, context: quietContext)
            notifier.deliver(event, decision: decision)
            history?.record(event)
            if decision.overlay, event.kind != .resolved { overlayEvent = event }
        }
        if let overlayEvent { overlay.show(overlayEvent, mode: settings.overlayMode) }
        if !newEvents.isEmpty {
            events = Array((newEvents.reversed() + events).prefix(30))
        }
        if !customEvents.isEmpty {
            let planned = customEvaluator.plan(events: customEvents, rules: settings.customRules, snapshot: snapshot, now: now)
            execute(planned, in: snapshot, quiet: quietContext)
            noteEndedThrottles(customEvents)
        }
        AppIntegration.didIngest(self)
        reschedule()
    }

    nonisolated static func worstSeverity(of conditions: [Condition]) -> Severity? {
        conditions.map(\.severity).max()
    }

    /// Redraws the menu bar only when the shown text would change noticeably (see `MenuBarDisplay`).
    private func updateMenuBarText(force: Bool) {
        guard let s = snapshot else { return }
        if let text = menuBar.update(items: settings.menuBarItems, values: MenuBarValues(s), now: s.date, force: force) {
            menuBarText = text
        }
    }

    // MARK: - Actions

    /// Shows the main window on `section`.
    func open(_ section: AppSection) {
        self.section = section
        searchText = ""
        showMainWindow()
    }

    /// Opens the main window and brings it to the front. While it is open the app is a regular app (Dock icon,
    /// menu); the window's observer switches the policy (see `WindowAccessor`). After the switch the app can
    /// activate itself, so the window is ordered front explicitly on the next run loop turns as well.
    func showMainWindow() {
        openWindowAction?("main")
        NSApp.activate()
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let window = self?.mainWindow
                    ?? NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    /// `macmonitor://…` and the shortcuts: where the link leads, and what else it does.
    func handle(_ route: AppRoute) {
        switch route {
        case .section(let target): open(target)
        case .welcome:
            showsWelcome = true
            showMainWindow()
        case .test: sendTest()
        }
    }

    func remedy(for condition: Condition) -> Remedy? {
        snapshot.map { Remedies.remedy(for: condition, in: $0) }
    }

    func sendTest() {
        let event = Notifier.testEvent()
        notifier.deliver(event, decision: QuietDecision(banner: true, overlay: true, sound: true))
        overlay.show(event, mode: settings.overlayMode)
    }

    func mute(_ processName: String, for duration: TimeInterval = 3600) {
        muted[processName] = Date().addingTimeInterval(duration)
        requestSample()
    }

    /// Puts what a rule did into the event log and tells the user with a short message.
    /// The entry is stored as a complete incident (fired and resolved at once) so it never stays "open".
    func logAction(_ text: String, detail: String = "", isError: Bool = false) {
        let now = Date()
        let condition = Condition(key: "action.\(UUID().uuidString)", rule: .custom, severity: isError ? .warning : .info,
                                  title: text, body: detail, sustain: 0)
        let fired = AlertEvent(date: now, kind: .fired, condition: condition)
        history?.record(fired)
        history?.record(AlertEvent(date: now, kind: .resolved, condition: condition))
        events = Array(([fired] + events).prefix(30))
        feedback = Feedback(text: detail.isEmpty ? text : "\(text) \(detail)", isError: isError)
    }

    func unmute(_ processName: String) {
        muted[processName] = nil
        requestSample()
    }

    /// The reference to a process the snapshot knows (with its start time), for places that only have PID and name.
    func processRef(pid: Int32, name: String) -> ProcessRef {
        snapshot?.processRef(pid: pid, name: name) ?? ProcessRef(pid: pid, name: name)
    }

    /// `label` is the name shown in the question when it differs from the process name (an app and its main process).
    func confirmKill(_ process: ProcessRef, label: String? = nil, helpers: Int = 0, host: ConfirmationHost? = nil) {
        let detail = helpers > 0
            ? String(localized: "PID \(process.pid), dazu \(String(localized: "\(helpers) Hilfsprozesse")), die in der Regel mit enden.")
            : String(localized: "PID \(process.pid).")
        ask(Confirmation(
            title: String(localized: "„\(label ?? process.name)“ beenden?"),
            message: String(localized: "\(detail) Ungesicherte Daten in diesem Prozess können verloren gehen."),
            confirmTitle: String(localized: "Beenden"),
            alternativeTitle: String(localized: "Sofort beenden"),
            alternative: { [weak self] in self?.signal(process, SIGKILL) },
            action: { [weak self] in self?.signal(process, SIGTERM) }), host: host)
    }

    /// Shows a confirmation where the user is looking: inline in the open popover, otherwise as
    /// an alert in the main window (opened if necessary).
    /// `host` names the surface the question came from; without it the most visible one is used.
    func ask(_ confirmation: Confirmation) { ask(confirmation, host: nil) }

    func ask(_ confirmation: Confirmation, host: ConfirmationHost?) {
        if let host {
            confirmationHost = host
        } else if isPopoverOpen && !isMainWindowVisible {
            confirmationHost = .popover
        } else {
            confirmationHost = .window
            if !isMainWindowVisible { showMainWindow() }
        }
        pendingConfirmation = confirmation
    }

    /// Sends a signal, updates the UI at once and reports what happened. Right before, `ProcessControl.send` checks
    /// that the PID still belongs to the process that was meant (name and start time): a late click on an old
    /// notification or a question left open for a long time must never hit a stranger.
    func signal(_ process: ProcessRef, _ signal: Int32) {
        let blocker = snapshot?.sleepBlockers.first { $0.pid == process.pid }
        let result = ProcessControl.send(signal, to: process)
        switch result.outcome {
        case .done:
            break
        case .skipped(.gone), .skipped(.pidReused), .skipped(.allowed):
            forget(process.pid)
            feedback = Feedback(text: String(localized: "„\(process.name)“ läuft schon nicht mehr."))
            return
        case .skipped(.protected):
            feedback = Feedback(text: String(localized: "„\(process.name)“ ist geschützt und wurde nicht angefasst."), isError: true)
            return
        case .failed(let error):
            feedback = Feedback(
                text: error == EPERM
                    ? String(localized: "„\(process.name)“ gehört dem System oder einem anderen Benutzer und kann nicht beendet werden.")
                    : String(localized: "„\(process.name)“ konnte nicht beendet werden (\(String(cString: strerror(error))))."),
                isError: true)
            return
        }
        if let blocker { endedBlockers[blocker.identity] = (blocker, Date()) }
        forget(process.pid)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            if signal == SIGTERM, ProcessControl.isRunning(process) {
                self.feedback = Feedback(
                    text: String(localized: "„\(process.name)“ reagiert nicht auf Beenden."), isError: true,
                    actionTitle: String(localized: "Sofort beenden"), action: { [weak self] in self?.signal(process, SIGKILL) })
            } else {
                self.feedback = Feedback(text: String(localized: "„\(process.name)“ beendet."))
            }
        }
    }

    /// Drops a process from the current snapshot and samples again right away.
    private func forget(_ pid: Int32) {
        snapshot = snapshot?.removing(pid: pid)
        queue.async { [sampler] in sampler.invalidateSleepBlockers() }
        requestSample()
    }

    /// Tells the user when a sleep blocker they ended was started again by its launcher.
    private func checkRespawnedBlockers(in snapshot: SystemSnapshot) {
        let now = snapshot.date
        endedBlockers = endedBlockers.filter { now.timeIntervalSince($0.value.at) < 120 }
        for blocker in snapshot.sleepBlockers {
            guard let ended = endedBlockers[blocker.identity], ended.blocker.pid != blocker.pid else { continue }
            endedBlockers[blocker.identity] = nil
            let launcher = blocker.parentName ?? String(localized: "einem anderen Programm")
            feedback = Feedback(
                text: String(localized: "„\(blocker.name)“ wurde von \(launcher) sofort neu gestartet. Beenden hilft erst, wenn \(launcher) fertig ist. Du kannst „\(blocker.name)“ auch ignorieren."),
                isError: true, actionTitle: String(localized: "Ignorieren"),
                action: { [weak self] in self?.perform(.ignoreForever(blocker.name)) })
        }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Previews and rendered docs

extension AppModel {
    /// A model with plausible, fixed data for screenshots. Does not sample.
    /// With `history`, the dashboard also gets an in-memory store with 30 synthetic days.
    static func demo(alerts: Bool = true, history: Bool = false) -> AppModel {
        let model = AppModel(settings: MonitorSettings())
        let gb: UInt64 = 1_073_741_824
        let chrome = "app:/Applications/Google Chrome.app", xcode = "app:/Applications/Xcode.app"
        let processes = [
            ProcessStat(pid: 4182, name: "node", cpuPercent: alerts ? 99.6 : 12.4, footprintBytes: 1_400_000_000,
                        energyMilliwatts: alerts ? 5200 : 640, threads: 14, diskReadBytesPerSecond: 12_000,
                        diskWriteBytesPerSecond: 380_000, appKey: "proc:4182", appName: "node"),
            ProcessStat(pid: 812, name: "Xcode", cpuPercent: 38.2, footprintBytes: 3 * gb, energyMilliwatts: 2100,
                        threads: 86, diskReadBytesPerSecond: 640_000, diskWriteBytesPerSecond: 90_000,
                        appKey: xcode, appName: "Xcode"),
            ProcessStat(pid: 833, name: "SourceKitService", cpuPercent: 11.4, footprintBytes: 1_100_000_000, energyMilliwatts: 760,
                        threads: 22, appKey: xcode, appName: "Xcode"),
            ProcessStat(pid: 1290, name: "Google Chrome Helper (Renderer)", cpuPercent: 21.7, footprintBytes: 2_100_000_000,
                        energyMilliwatts: 1450, threads: 31, appKey: chrome, appName: "Google Chrome"),
            ProcessStat(pid: 1288, name: "Google Chrome", cpuPercent: 4.1, footprintBytes: 780_000_000, energyMilliwatts: 310,
                        threads: 44, diskWriteBytesPerSecond: 40_000, appKey: chrome, appName: "Google Chrome"),
            ProcessStat(pid: 1301, name: "Google Chrome Helper (GPU)", cpuPercent: 6.8, footprintBytes: 520_000_000, energyMilliwatts: 880,
                        threads: 18, appKey: chrome, appName: "Google Chrome"),
            ProcessStat(pid: 1330, name: "Google Chrome Helper (Renderer)", cpuPercent: 2.4, footprintBytes: 640_000_000, energyMilliwatts: 190,
                        threads: 20, appKey: chrome, appName: "Google Chrome"),
            ProcessStat(pid: 640, name: "Docker", cpuPercent: 9.3, footprintBytes: 4 * gb, energyMilliwatts: 940, threads: 52,
                        diskReadBytesPerSecond: 210_000, diskWriteBytesPerSecond: 1_200_000,
                        appKey: "app:/Applications/Docker.app", appName: "Docker"),
            ProcessStat(pid: 1544, name: "Claude", cpuPercent: 6.1, footprintBytes: 900_000_000, energyMilliwatts: 520, threads: 38,
                        appKey: "app:/Applications/Claude.app", appName: "Claude"),
            ProcessStat(pid: 377, name: "Finder", cpuPercent: 1.2, footprintBytes: 310_000_000, energyMilliwatts: 60, threads: 9,
                        appKey: "app:/System/Library/CoreServices/Finder.app", appName: "Finder"),
        ]
        let snapshot = SystemSnapshot(
            date: Date(), cpuPercent: alerts ? 47 : 18, memoryUsedBytes: 15_800_000_000,
            memoryTotalBytes: 24 * gb, memoryPressure: alerts ? .warning : .normal,
            swapUsedBytes: alerts ? 2_600_000_000 : 300_000_000, thermal: .nominal,
            disk: DiskStat(availableBytes: 312 * gb, totalBytes: 994 * gb), isOnline: true,
            network: NetworkRate(downBytesPerSecond: 1_850_000, upBytesPerSecond: 96_000),
            power: PowerState(onBattery: true, batteryPercent: 82, lowPowerMode: false, minutesRemaining: 312,
                              health: BatteryHealth(cycleCount: 143, capacityPercent: 96)),
            sleepBlockers: alerts ? [SleepBlocker(pid: 4182, name: "node", reason: "caffeinate command-line tool")] : [],
            processes: processes,
            cpuCores: CPUCoreLoad(perCore: alerts ? [14, 22, 9, 18, 71, 64, 58, 82, 39, 47] : [6, 9, 4, 7, 24, 18, 15, 31, 12, 16],
                                  efficiencyCoreCount: 4, performanceCoreCount: 6),
            gpu: GPUStat(utilizationPercent: alerts ? 34 : 9, memoryUsedBytes: 1_900_000_000, memoryAllocatedBytes: 3_200_000_000),
            thermals: ThermalSensors(
                cpuAverageCelsius: alerts ? 58 : 44, cpuMaxCelsius: alerts ? 71 : 52, batteryCelsius: 31.4,
                sensors: [(String(localized: "CPU Performance-Kern \(1)"), 71.0), (String(localized: "CPU Performance-Kern \(2)"), 68.5),
                          (String(localized: "CPU Performance-Kern \(3)"), 66.2), (String(localized: "CPU Performance-Kern \(4)"), 63.9),
                          (String(localized: "CPU Effizienz-Kern \(1)"), 52.4), (String(localized: "CPU Effizienz-Kern \(2)"), 51.8),
                          ("GPU Cluster 1", 49.6), ("GPU Cluster 2", 48.7), ("SSD", 38.0), (String(localized: "Akku"), 31.4),
                          (String(localized: "Gehäuse links"), 33.1), (String(localized: "Gehäuse rechts"), 32.6),
                          (String(localized: "Netzteil-Anschluss"), 29.8)]
                    .map { TemperatureReading(name: $0.0, celsius: $0.1) }),
            fans: [FanStat(index: 0, rpm: alerts ? 2480 : 1210, minRpm: 1200, maxRpm: 5779),
                   FanStat(index: 1, rpm: alerts ? 2510 : 1230, minRpm: 1200, maxRpm: 6241)],
            powerDraw: SystemPowerDraw(systemWatts: alerts ? 24.6 : 11.3, cpuWatts: alerts ? 9.4 : 3.1, gpuWatts: alerts ? 3.8 : 0.9,
                                       aneWatts: 0.2, dramWatts: 1.6),
            batteryDetail: BatteryDetail(designCapacityMah: 6249, maxCapacityMah: 5970, currentCapacityMah: 4890,
                                         temperatureCelsius: 31.4, condition: .normal, minutesToFull: nil,
                                         voltageMillivolts: 12_380, amperageMilliamps: -1_980, adapterWatts: nil),
            networkDetail: NetworkDetail(
                primary: ActiveInterface(name: "en0", kind: .wifi, ipv4: "192.168.1.42"),
                interfaces: [InterfaceRate(name: "en0", rate: NetworkRate(downBytesPerSecond: 1_840_000, upBytesPerSecond: 91_000)),
                             InterfaceRate(name: "utun4", rate: NetworkRate(downBytesPerSecond: 9_000, upBytesPerSecond: 5_000))]),
            volumes: [VolumeStat(name: "Macintosh HD", path: "/", availableBytes: 312 * gb, totalBytes: 994 * gb, isInternal: true),
                      VolumeStat(name: "Extern 1 TB", path: "/Volumes/Extern", availableBytes: 410 * gb, totalBytes: 931 * gb, isInternal: false)],
            diskThroughput: DiskThroughput(readBytesPerSecond: 4_400_000, writeBytesPerSecond: 1_150_000),
            ssdHealth: SSDHealth(isVerified: true, percentageUsed: 3, availableSparePercent: 100, temperatureCelsius: 38,
                                 powerOnHours: 1_840, bytesWritten: 38_000_000_000_000),
            runtime: RuntimeStat(uptimeSeconds: 3 * 86_400 + 4 * 3600 + 900,
                                 loadAverage: LoadAverage(one: 2.41, five: 2.12, fifteen: 1.87), processCount: 612, threadCount: 3450))
        model.snapshot = snapshot
        for i in 0..<90 {
            let x = Double(i)
            model.cpuHistory.append(max(4, 22 + 14 * sin(x / 7) + (alerts && i > 60 ? 22 : 0) + Double((i * 37) % 9)))
            model.memoryHistory.append(58 + 6 * sin(x / 19) + (alerts ? Double(i) / 9 : 0))
        }
        if alerts {
            let runaway = Rules.evaluate(snapshot, .init(settings: MonitorSettings()))
                .filter { $0.rule == .runawayProcess || $0.rule == .memoryPressure }
            model.reported = runaway
            model.events = runaway.enumerated().map {
                AlertEvent(date: Date().addingTimeInterval(Double(-90 - $0.offset * 240)), kind: .fired, condition: $0.element)
            } + [AlertEvent(date: Date().addingTimeInterval(-5400), kind: .resolved,
                            condition: Condition(key: "system.network", rule: .network, severity: .warning,
                                                 title: String(localized: "Keine Internetverbindung"), body: "", sustain: 30))]
        }
        if history {
            model.historyState = .active
            model.dashboard.store = DemoHistory.make()
        }
        return model
    }
}
