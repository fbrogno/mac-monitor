import MonitorCore
import SwiftUI
import WidgetViews

/// Renders every widget view with demo data to `widget-*.png`, at the point sizes macOS uses
/// (small 158 x 158, medium 338 x 158, large 338 x 354) with the 16 pt content inset.
@MainActor
enum WidgetRender {
    static func render(to url: URL) {
        let now = Date()
        let calm = WidgetContent.live(.demo(alerts: false, now: now))
        let busy = WidgetContent.live(.demo(alerts: true, now: now))
        let stale = WidgetContent.stale(lastSeen: now.addingTimeInterval(-47 * 60), snapshot: .demo(alerts: false, now: now))

        func shot(_ name: String, _ size: CGSize, dark: Bool = true, @ViewBuilder _ content: () -> some View) {
            DocRenderer.write(Tile(size: size, dark: dark, content: content), scale: 2,
                              to: url.appendingPathComponent("widget-\(name).png"))
        }
        let small = CGSize(width: 158, height: 158), medium = CGSize(width: 338, height: 158), large = CGSize(width: 338, height: 354)

        shot("status-small", small) { StatusWidgetView(content: calm, size: .small) }
        shot("status-small-alert", small) { StatusWidgetView(content: busy, size: .small) }
        shot("status-medium", medium) { StatusWidgetView(content: calm, size: .medium) }
        shot("status-medium-alert", medium) { StatusWidgetView(content: busy, size: .medium) }
        shot("status-medium-light", medium, dark: false) { StatusWidgetView(content: busy, size: .medium) }
        shot("load-medium", medium) { LoadWidgetView(content: busy) }
        shot("load-medium-light", medium, dark: false) { LoadWidgetView(content: calm, showPower: false) }
        shot("battery-small", small) { BatteryWidgetView(content: calm, size: .small) }
        shot("battery-medium", medium) { BatteryWidgetView(content: calm, size: .medium) }
        shot("storage-small", small) { StorageWidgetView(content: calm, size: .small) }
        shot("storage-medium", medium) { StorageWidgetView(content: calm, size: .medium) }
        shot("topapps-medium", medium) { TopAppsWidgetView(content: busy, size: .medium) }
        shot("topapps-large", large) { TopAppsWidgetView(content: busy, size: .large) }
        shot("topapps-large-light", large, dark: false) { TopAppsWidgetView(content: calm, size: .large) }
        shot("stale-small", small) { StatusWidgetView(content: stale, size: .small) }
        shot("stale-medium", medium) { LoadWidgetView(content: stale) }
        shot("nodata-medium", medium) { StatusWidgetView(content: .noData, size: .medium) }
    }
}

/// A widget-like tile: rounded, system-ish background, 16 pt inset, on a neutral backdrop.
private struct Tile<Content: View>: View {
    let size: CGSize
    let dark: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.97, green: 0.97, blue: 0.98),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.12 : 0.08)))
            .padding(20)
            .background(dark ? Color(red: 0.07, green: 0.09, blue: 0.16) : Color(red: 0.84, green: 0.89, blue: 0.95))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
