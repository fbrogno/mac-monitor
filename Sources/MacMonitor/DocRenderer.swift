import AppKit
import MonitorCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `MacMonitor --render-docs <dir>` writes the app icon and README images from the real views
/// with demo data, so screenshots never drift from the code.
@MainActor
enum DocRenderer {
    static func render(to dir: String) {
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
        let overview = AppModel.demo()
        overview.cleanup.useDemoSizes()
        write(Framed(scheme: .dark) { OverviewContent(model: overview).frame(width: 760) }, scale: 2,
              to: url.appendingPathComponent("overview.png"))
        renderDashboard(to: url)
        print("Bilder geschrieben nach \(url.path)")
    }

    /// Dashboard images from the real panes with demo data and a synthetic 30-day history.
    /// `MACMONITOR_RENDER_ALL=1` also writes the sections not shown in the README.
    private static func renderDashboard(to url: URL) {
        let model = AppModel.demo(history: true)
        let all = ProcessInfo.processInfo.environment["MACMONITOR_RENDER_ALL"] == "1"
        let shots: [(DashboardSection, DashboardRange, String, Bool)] = [
            (.overview, .day, "dashboard-overview", true), (.cpu, .day, "dashboard-cpu", true),
            (.energy, .day, "dashboard-energy", true), (.apps, .week, "dashboard-apps", true),
            (.report, .day, "dashboard-report", true),
            (.memory, .day, "dashboard-memory", false), (.sensors, .day, "dashboard-sensors", false),
            (.network, .day, "dashboard-network", false), (.events, .week, "dashboard-events", false),
        ]
        for (section, range, name, readme) in shots where readme || all {
            model.dashboard.section = section
            model.dashboard.range = range
            model.dashboard.reportPeriod = .week
            model.dashboard.previewHover = section == .cpu ? Date().addingTimeInterval(-5.4 * 3600) : nil
            model.dashboard.reloadBlocking()
            let expanded: Set<String> = section == .apps ? ["app:/Applications/Google Chrome.app"] : []
            write(DashboardShot(model: model, expanded: expanded), scale: 2, to: url.appendingPathComponent("\(name).png"))
        }
    }

    private static func write(_ view: some View, scale: CGFloat, to file: URL) {
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
                    ForEach(["Swift", "SwiftUI", "macOS 15+", "keine Hilfsprozesse"], id: \.self) { tag in
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
            title: "node hängt bei 100 % CPU",
            body: "Seit über 3 min ununterbrochen hohe Last (PID 4182).",
            sustain: 0, process: ProcessRef(pid: 4182, name: "node")))
        AlertHUDView(event: event)
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .padding(30)
            .background(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.3), Color(red: 0.05, green: 0.08, blue: 0.14)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)
    }
}

/// The dashboard window as an image: sidebar and detail drawn in SwiftUI (the AppKit-backed split
/// view does not render offline), the panes are the real ones.
private struct DashboardShot: View {
    let model: AppModel
    var expanded: Set<String> = []

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                }
                .padding(.bottom, 18)
                ForEach(DashboardSection.allCases) { section in
                    let selected = section == model.dashboard.section
                    Label { Text(section.title) } icon: { Image(systemName: section.symbol).frame(width: 20) }
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 14)
            .frame(width: 236)
            .background(Color.primary.opacity(0.04))
            Divider()
            DashboardDetail(model: model, expandedApps: expanded)
                .padding(24)
                .frame(width: 900, alignment: .topLeading)
        }
        .frame(width: 1137)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }
}
