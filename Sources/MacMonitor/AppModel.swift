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
    private(set) var reported: [Condition] = []
    var pendingConfirmation: Confirmation?
    var confirmationHost: ConfirmationHost = .overview
    /// Section the overview window should scroll to when it opens.
    var overviewFocus: OverviewSection?
    /// Menu bar text, only changed when the shown value moves noticeably (see `updateMenuBarText`).
    private(set) var menuBarText = ""

    var settings: MonitorSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.reminderInterval = settings.reminderInterval
            SettingsStore.save(settings)
            if settings.menuBarStyle != oldValue.menuBarStyle { updateMenuBarText(force: true) }
        }
    }

    var isPopoverOpen = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            reschedule()
            if isPopoverOpen { requestSample() }
            // An unanswered question in the popover is dropped when it closes.
            if !isPopoverOpen, confirmationHost == .popover { pendingConfirmation = nil }
        }
    }

    var isOverviewOpen = false {
        didSet {
            guard isOverviewOpen != oldValue else { return }
            reschedule()
            if isOverviewOpen { requestSample() }
        }
    }

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let cleanup = CleanupModel()
    /// Set by the SwiftUI scene so non-view code can open windows.
    @ObservationIgnored var openWindowAction: ((String) -> Void)?
    @ObservationIgnored private var swapHistory: [(date: Date, bytes: UInt64)] = []
    @ObservationIgnored private let overlay = AlertOverlay()
    @ObservationIgnored private var engine: AlertEngine
    @ObservationIgnored private var muted: [String: Date] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "macmonitor.sampling", qos: .utility)
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var currentInterval: TimeInterval = 0
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Written on `queue` by the path monitor, read on `queue` by the sampler.
    @ObservationIgnored nonisolated(unsafe) private var isOnline = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var shownCPU = -100.0
    @ObservationIgnored private var shownMemory = -100.0
    @ObservationIgnored private let log = Logger(subsystem: "com.fbrogno.macmonitor", category: "sampling")

    init(settings: MonitorSettings = SettingsStore.load()) {
        self.settings = settings
        engine = AlertEngine(reminderInterval: settings.reminderInterval)
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onKill = { [weak self] ref in self?.confirmKill(ref) }
        notifier.onMute = { [weak self] name in self?.mute(name) }
        overlay.onKill = { [weak self] ref in self?.confirmKill(ref) }
        overlay.onMute = { [weak self] name in self?.mute(name) }
        overlay.onOpen = { [weak self] in self?.openOverview() }
        notifier.onOpen = { [weak self] in self?.openOverview() }
        notifier.requestAuthorization()

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

        reschedule()
        requestSample()
    }

    private func handleWake() {
        engine.resetPending()
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
        let interval = SamplingPolicy.interval(popoverOpen: isPopoverOpen || isOverviewOpen, power: snapshot?.power ?? .unknown)
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

    private func ingest(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        cpuHistory.append(snapshot.cpuPercent)
        memoryHistory.append(snapshot.memoryFraction * 100)

        let now = snapshot.date
        muted = muted.filter { $0.value > now }
        swapHistory.append((now, snapshot.swapUsedBytes))
        swapHistory.removeAll { now.timeIntervalSince($0.date) > 600 }
        let swapLow = swapHistory.map(\.bytes).min() ?? snapshot.swapUsedBytes
        let context = Rules.Context(
            settings: settings,
            isActive: { [engine] in engine.isActive($0) },
            mutedProcesses: Set(muted.keys),
            swapGrowthBytes: snapshot.swapUsedBytes > swapLow ? snapshot.swapUsedBytes - swapLow : 0)
        let conditions = Rules.evaluate(snapshot, context)
        let newEvents = engine.process(conditions, now: now)
        let nowReported = engine.reported
        if nowReported != reported { reported = nowReported }
        updateMenuBarText(force: false)

        for event in newEvents {
            notifier.deliver(event)
        }
        if let shown = newEvents.last(where: { $0.kind != .resolved }) {
            overlay.show(shown, mode: settings.overlayMode)
        }
        if !newEvents.isEmpty {
            events = Array((newEvents.reversed() + events).prefix(30))
        }
        reschedule()
    }

    /// Redraws the menu bar only when CPU or RAM moved by at least 5 points.
    private func updateMenuBarText(force: Bool) {
        guard let s = snapshot else { return }
        let style = settings.menuBarStyle
        guard style != .icon else {
            if !menuBarText.isEmpty { menuBarText = "" }
            return
        }
        let cpu = s.cpuPercent
        let memory = s.memoryFraction * 100
        let moved = abs(cpu - shownCPU) >= 5 || (style == .iconCPUAndMemory && abs(memory - shownMemory) >= 5)
        guard force || moved else { return }
        shownCPU = cpu
        shownMemory = memory
        let cpuText = "\(Int(cpu.rounded()))%"
        menuBarText = style == .iconCPUAndMemory ? "\(cpuText) · \(Int(memory.rounded()))%" : cpuText
    }

    // MARK: - Actions

    func openOverview(section: OverviewSection = .issues) {
        overviewFocus = section
        showWindow("overview")
    }

    /// Opens a SwiftUI window and brings it to the front. A menu bar app is not allowed to
    /// activate itself from the background on recent macOS, so the window is ordered front explicitly.
    func showWindow(_ id: String) {
        openWindowAction?(id)
        NSApp.activate()
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func remedy(for condition: Condition) -> Remedy? {
        snapshot.map { Remedies.remedy(for: condition, in: $0) }
    }

    func sendTest() {
        let event = Notifier.testEvent()
        notifier.deliver(event)
        overlay.show(event, mode: settings.overlayMode)
    }

    func mute(_ processName: String, for duration: TimeInterval = 3600) {
        muted[processName] = Date().addingTimeInterval(duration)
        requestSample()
    }

    func confirmKill(_ process: ProcessRef) {
        ask(Confirmation(
            title: "„\(process.name)“ beenden?",
            message: "PID \(process.pid). Ungesicherte Daten in diesem Prozess können verloren gehen.",
            confirmTitle: "Beenden",
            alternativeTitle: "Sofort beenden",
            alternative: { [weak self] in self?.signal(process, SIGKILL) },
            action: { [weak self] in self?.signal(process, SIGTERM) }))
    }

    /// Shows a confirmation where the user is looking: inline in the open popover, otherwise as
    /// an alert in the overview window (opened if necessary).
    func ask(_ confirmation: Confirmation) {
        if isPopoverOpen && !isOverviewOpen {
            confirmationHost = .popover
        } else {
            confirmationHost = .overview
            if !isOverviewOpen { showWindow("overview") }
        }
        pendingConfirmation = confirmation
    }

    func signal(_ process: ProcessRef, _ signal: Int32) {
        kill(process.pid, signal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestSample() }
    }

    func openActivityMonitor() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}

enum OverviewSection: Hashable {
    case issues, cleanup
}

// MARK: - Previews and rendered docs

extension AppModel {
    /// A model with plausible, fixed data for screenshots. Does not sample.
    static func demo(alerts: Bool = true) -> AppModel {
        let model = AppModel(settings: MonitorSettings())
        let gb: UInt64 = 1_073_741_824
        let processes = [
            ProcessStat(pid: 4182, name: "node", cpuPercent: alerts ? 99.6 : 12.4, footprintBytes: 1_400_000_000),
            ProcessStat(pid: 812, name: "Xcode", cpuPercent: 38.2, footprintBytes: 3 * gb),
            ProcessStat(pid: 1290, name: "Google Chrome Helper (Renderer)", cpuPercent: 21.7, footprintBytes: 2_100_000_000),
            ProcessStat(pid: 640, name: "Docker", cpuPercent: 9.3, footprintBytes: 4 * gb),
            ProcessStat(pid: 1544, name: "Claude", cpuPercent: 6.1, footprintBytes: 900_000_000),
            ProcessStat(pid: 377, name: "Finder", cpuPercent: 1.2, footprintBytes: 310_000_000),
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
            processes: processes)
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
                                                 title: "Keine Internetverbindung", body: "", sustain: 30))]
        }
        return model
    }
}
