import AppKit
import MonitorCore
import Network
import Observation

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

    var settings: MonitorSettings {
        didSet {
            guard settings != oldValue else { return }
            engine.reminderInterval = settings.reminderInterval
            SettingsStore.save(settings)
        }
    }

    var isPopoverOpen = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            reschedule()
            if isPopoverOpen { requestSample() }
        }
    }

    @ObservationIgnored let notifier = Notifier()
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

    init(settings: MonitorSettings = SettingsStore.load()) {
        self.settings = settings
        engine = AlertEngine(reminderInterval: settings.reminderInterval)
    }

    // MARK: - Lifecycle

    func start() {
        notifier.onKill = { [weak self] ref in self?.confirmKill(ref) }
        notifier.onMute = { [weak self] name in self?.mute(name) }
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
        let interval = SamplingPolicy.interval(popoverOpen: isPopoverOpen, power: snapshot?.power ?? .unknown)
        guard interval != currentInterval else { return }
        currentInterval = interval

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
        let context = Rules.Context(
            settings: settings,
            isActive: { [engine] in engine.isActive($0) },
            mutedProcesses: Set(muted.keys))
        let conditions = Rules.evaluate(snapshot, context)
        let newEvents = engine.process(conditions, now: now)
        reported = engine.reported

        for event in newEvents {
            notifier.deliver(event)
        }
        if !newEvents.isEmpty {
            events = Array((newEvents.reversed() + events).prefix(30))
        }
        reschedule()
    }

    // MARK: - Actions

    func mute(_ processName: String, for duration: TimeInterval = 3600) {
        muted[processName] = Date().addingTimeInterval(duration)
        requestSample()
    }

    func confirmKill(_ process: ProcessRef) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "„\(process.name)“ beenden?"
        alert.informativeText = "PID \(process.pid). Ungesicherte Daten in diesem Prozess können verloren gehen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Sofort beenden")
        switch alert.runModal() {
        case .alertFirstButtonReturn: kill(process.pid, SIGTERM)
        case .alertThirdButtonReturn: kill(process.pid, SIGKILL)
        default: return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestSample() }
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
            power: PowerState(onBattery: true, batteryPercent: 82, lowPowerMode: false),
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
