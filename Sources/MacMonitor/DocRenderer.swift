import AppKit
import MonitorCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `MacMonitor --render-docs <dir> [--lang de|en]` writes the app icon and README images from the
/// real views with demo data, so screenshots never drift from the code.
///
/// `--lang` starts the same binary again with that language and region, so texts and number
/// formats come out as they would for a user with that system language. Translations are only
/// loaded by the xcodebuild bundle (see `scripts/render-docs.sh`); a plain SwiftPM build always
/// shows German.
@MainActor
enum DocRenderer {
    static func render(to dir: String) {
        if relaunchIfLanguageRequested() { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        write(AppIconView(size: 1024, padded: true), scale: 1, to: url.appendingPathComponent("icon-1024.png"))
        write(AppIconView(size: 256, padded: true), scale: 1, to: url.appendingPathComponent("icon-256.png"))
        write(Banner(), scale: 2, to: url.appendingPathComponent("banner.png"))
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "popover-dark.png" : "popover-light.png"
            write(Framed(scheme: scheme) { PopoverView(model: .demo()) }, scale: 2, to: url.appendingPathComponent(name))
        }
        write(Framed(scheme: .dark) { PopoverView(model: .demo(alerts: false)) }, scale: 2,
              to: url.appendingPathComponent("popover-calm.png"))
        write(Framed(scheme: .dark) { PopoverView(model: .demo(), showApps: true) }, scale: 2,
              to: url.appendingPathComponent("popover-apps.png"))
        write(OverlayPreview(), scale: 2, to: url.appendingPathComponent("overlay.png"))
        renderWindows(to: url)
        renderWelcome(to: url)
        WidgetRender.render(to: url)
        print("Bilder geschrieben nach \(url.path)")
    }

    /// Handles `--lang`: runs this binary again with `-AppleLanguages`/`-AppleLocale` (command-line
    /// defaults, nothing is stored) and waits for it. Returns true in the parent.
    private static func relaunchIfLanguageRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--lang"), args.indices.contains(i + 1),
              ProcessInfo.processInfo.environment["MACMONITOR_RENDER_LANG"] == nil,
              let executable = Bundle.main.executablePath else { return false }
        let lang = args[i + 1]
        let region = lang == "en" ? "en_US" : lang == "de" ? "de_DE" : lang
        var forwarded = Array(args.dropFirst())
        forwarded.removeSubrange(i - 1...i)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = forwarded + ["-AppleLanguages", "(\(lang))", "-AppleLocale", region]
        process.environment = ProcessInfo.processInfo.environment.merging(["MACMONITOR_RENDER_LANG": lang]) { $1 }
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("Konnte \(executable) nicht starten: \(error)\n".utf8))
            exit(1)
        }
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    // MARK: Main window

    /// One image per area of the main window, plus light and narrow variants. The window is the real one
    /// (`MainWindowView` in an off-screen titled window, toolbar and sidebar included), captured with its title bar.
    /// `MACMONITOR_RENDER_ONLY=<name>[,<name>]` limits the output (for iterating).
    private static func renderWindows(to url: URL) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel.demo(history: true)
        model.cleanup.useDemoSizes()
        model.settings.menuBarItems = [.cpu, .memory, .temperature]
        model.settings.hotKeys.openDashboard = HotKeyBinding(keyCode: 2, modifiers: HotKeyBinding.control | HotKeyBinding.option)
        model.settings.customRules = [CustomRule.templates[0].instantiated(), CustomRule.templates[2].instantiated()]
        model.settings.quiet.quietHoursEnabled = true
        model.previewExpandedApps = ["app:/Applications/Google Chrome.app"]
        var broken = CustomRule.templates[0].instantiated()
        broken.processName = ""

        let names: [AppSection: String] = [
            .overview: "overview", .issues: "issues", .apps: "apps", .cpu: "cpu", .memory: "memory", .energy: "energy",
            .sensors: "sensors", .network: "network", .events: "events", .report: "report", .cleanup: "cleanup",
            .general: "general", .menuBar: "menubar", .rules: "rules", .customRules: "custom-rules", .quiet: "quiet",
            .ignored: "ignored", .data: "data", .about: "about",
        ]
        let only = ProcessInfo.processInfo.environment["MACMONITOR_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        let standard = CGSize(width: 1100, height: 720)
        // Tall enough that the page shows whole (the real window scrolls).
        let heights: [AppSection: CGFloat] = [
            .issues: 840, .apps: 790, .cpu: 1080, .energy: 1040, .sensors: 1000, .network: 780, .events: 880, .report: 1000,
            .cleanup: 760, .menuBar: 820, .rules: 900, .customRules: 900, .quiet: 820,
        ]
        var shots: [(AppSection, String, ColorScheme, CGSize)] = AppSection.allCases.map {
            ($0, names[$0]!, .dark, CGSize(width: 1100, height: heights[$0] ?? standard.height))
        }
        shots += [(.overview, "overview-light", .light, standard), (.issues, "issues-light", .light, standard),
                  (.rules, "rules-light", .light, standard), (.overview, "overview-narrow", .dark, CGSize(width: 860, height: 800)),
                  (.apps, "apps-narrow", .dark, CGSize(width: 860, height: 800))]
        for (section, name, scheme, size) in shots where only == nil || only!.contains(name) {
            model.section = section
            model.dashboard.range = section == .apps || section == .events ? .week : .day
            model.dashboard.reportPeriod = .week
            model.dashboard.previewHover = section == .cpu ? Date().addingTimeInterval(-5.4 * 3600) : nil
            model.previewCustomRule = section == .customRules ? broken : nil
            if section.dashboardSection != nil { model.dashboard.reloadBlocking(now: DemoHistory.referenceNow) }
            writeWindow(model: model, scheme: scheme, size: size, to: url.appendingPathComponent("window-\(name).png"))
        }
    }

    /// Hosts the main window off screen, lets SwiftUI settle and writes the window (with title bar) as a 2x PNG
    /// on a soft backdrop.
    private static func writeWindow(model: AppModel, scheme: ColorScheme, size: CGSize, to file: URL) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let controller = NSHostingController(rootView: MainWindowView(model: model, isPreview: true).toggleStyle(DocSwitchStyle(dark: scheme == .dark)))
        let window = RenderWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = appearance
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFront(nil)
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        defer { window.orderOut(nil) }
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("Konnte \(file.lastPathComponent) nicht rendern\n".utf8))
            return
        }
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        write(WindowBackdrop(image: image, scheme: scheme), scale: 2, to: file)
    }

    // MARK: Welcome

    private static func renderWelcome(to url: URL) {
        NSApplication.shared.setActivationPolicy(.accessory)
        writeHosted(WelcomeShot(model: AppModel.demo(alerts: false)), to: url.appendingPathComponent("welcome.png"))
    }

    /// Captures a SwiftUI view with real AppKit controls at 2x. Needs a window, which stays hidden.
    private static func writeHosted(_ view: some View, to file: URL) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).toggleStyle(DocSwitchStyle()))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        // Far off screen, so nobody sees the window.
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let fitted = hosting.fittingSize
        window.setContentSize(fitted)
        hosting.frame = NSRect(origin: .zero, size: fitted)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        defer { window.orderOut(nil) }
        let size = hosting.bounds.size
        guard size.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("Konnte \(file.lastPathComponent) nicht rendern\n".utf8))
            return
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    static func write(_ view: some View, scale: CGFloat, to file: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            FileHandle.standardError.write(Data("Konnte \(file.lastPathComponent) nicht rendern\n".utf8))
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// Puts a view on a window-like card with a soft backdrop.
private struct Framed<Content: View>: View {
    var scheme: ColorScheme
    @ViewBuilder var content: Content

    var body: some View {
        let dark = scheme == .dark
        content
            .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.08)))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 24, y: 10)
            .padding(36)
            .background(LinearGradient(
                colors: dark
                    ? [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.08)]
                    : [Color(red: 0.88, green: 0.93, blue: 0.97), Color(red: 0.95, green: 0.96, blue: 0.99)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, scheme)
    }
}

private struct Banner: View {
    var body: some View {
        HStack(spacing: 44) {
            AppIconView(size: 220, padded: true)
            VStack(alignment: .leading, spacing: 14) {
                Text("MacMonitor")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Native Menüleisten-App, die deinen Mac im Blick behält\nund sich nur meldet, wenn etwas wirklich auffällt.")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(4)
                HStack(spacing: 10) {
                    ForEach(["Swift", "SwiftUI", "macOS 15+", String(localized: "keine Hilfsprozesse")], id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.88))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.top, 6)
            }
        }
        .frame(width: 1280, height: 520)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.02, green: 0.03, blue: 0.07)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.18, green: 0.9, blue: 0.77).opacity(0.18), .clear],
                               center: UnitPoint(x: 0.22, y: 0.5), startRadius: 0, endRadius: 520)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The real alert panel on a desktop-like backdrop.
private struct OverlayPreview: View {
    var body: some View {
        let event = AlertEvent(date: Date(), kind: .fired, condition: Condition(
            key: "demo", rule: .runawayProcess, severity: .warning,
            title: String(localized: "\("node") hängt bei \(Format.percent(100)) CPU"),
            body: String(localized: "Seit über \(Format.duration(180)) ununterbrochen hohe Last (PID \(String(4182)))."),
            sustain: 0, process: ProcessRef(pid: 4182, name: "node")))
        AlertHUDView(event: event)
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .padding(30)
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.3), Color(red: 0.05, green: 0.08, blue: 0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)
    }
}

/// The captured window on a soft backdrop, with rounded corners and a shadow.
private struct WindowBackdrop: View {
    let image: NSImage
    let scheme: ColorScheme

    var body: some View {
        let dark = scheme == .dark
        Image(nsImage: image)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.1)))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 22, y: 10)
            .padding(36)
            .background(LinearGradient(
                colors: dark
                    ? [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.08)]
                    : [Color(red: 0.88, green: 0.93, blue: 0.97), Color(red: 0.95, green: 0.96, blue: 0.99)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// A titled window that stays where it is put (also far off screen).
private final class RenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct WelcomeShot: View {
    let model: AppModel

    var body: some View {
        WelcomeView(model: model)
            .background(Color(red: 0.13, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .padding(28)
            .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// A switch drawn in SwiftUI in the colours of an active window. The system switch is drawn grey in a
/// window that is not frontmost, which is how an off-screen capture sees it; on and off would hardly differ.
private struct DocSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    var dark = true

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color(red: 0.04, green: 0.52, blue: 1.0) : (dark ? Color.white.opacity(0.18) : Color.black.opacity(0.15)))
                Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .frame(width: 38, height: 22)
            .opacity(enabled ? 1 : 0.45)
        }
    }
}
