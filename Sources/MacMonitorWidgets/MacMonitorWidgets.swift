import AppIntents
import MonitorCore
import SwiftUI
import WidgetKit
import WidgetViews

@main
struct MacMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        LoadWidget()
        BatteryWidget()
        StorageWidget()
        TopAppsWidget()
    }
}

// MARK: - Timeline

struct MonitorEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
}

/// Reads the file the app wrote into the shared group container. Entries are built so that the
/// "MacMonitor läuft nicht" state appears on its own once the file gets too old, without any reload.
enum MonitorTimeline {
    static func load() -> WidgetSnapshot? { WidgetStore.shared()?.read() }

    static func entries(now: Date = Date()) -> [MonitorEntry] {
        let snapshot = load()
        var result = [MonitorEntry(date: now, content: WidgetContent.resolve(snapshot, at: now))]
        if let snapshot {
            let staleAt = snapshot.date.addingTimeInterval(WidgetSnapshot.staleAfter + 1)
            if staleAt > now { result.append(MonitorEntry(date: staleAt, content: WidgetContent.resolve(snapshot, at: staleAt))) }
        }
        return result
    }

    static func placeholder() -> MonitorEntry {
        MonitorEntry(date: Date(), content: .live(WidgetSnapshot.demo(alerts: false)))
    }

    static func timeline() -> Timeline<MonitorEntry> {
        // The app reloads timelines when something visible changes; this is only the safety net.
        Timeline(entries: entries(), policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct MonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry { MonitorTimeline.placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (MonitorEntry) -> Void) {
        completion(context.isPreview ? MonitorTimeline.placeholder() : MonitorTimeline.entries()[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorEntry>) -> Void) {
        completion(MonitorTimeline.timeline())
    }
}

// MARK: - Configuration of the load widget

enum LoadExtras: String, AppEnum {
    case both, temperature, power, none

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Zusatzwerte")
    static let caseDisplayRepresentations: [LoadExtras: DisplayRepresentation] = [
        .both: "Temperatur und Leistung",
        .temperature: "Nur Temperatur",
        .power: "Nur Leistung",
        .none: "Keine",
    ]
}

struct LoadWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Auslastung"
    static let description = IntentDescription("Wähle, welche Zusatzwerte unter den Verläufen stehen.")

    @Parameter(title: "Zusatzwerte", default: .both)
    var extras: LoadExtras
}

struct LoadEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
    let extras: LoadExtras
}

struct LoadProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LoadEntry {
        LoadEntry(date: Date(), content: .live(WidgetSnapshot.demo(alerts: false)), extras: .both)
    }

    func snapshot(for configuration: LoadWidgetIntent, in context: Context) async -> LoadEntry {
        context.isPreview ? placeholder(in: context)
            : LoadEntry(date: Date(), content: MonitorTimeline.entries()[0].content, extras: configuration.extras)
    }

    func timeline(for configuration: LoadWidgetIntent, in context: Context) async -> Timeline<LoadEntry> {
        let base = MonitorTimeline.timeline()
        return Timeline(entries: base.entries.map { LoadEntry(date: $0.date, content: $0.content, extras: configuration.extras) },
                        policy: base.policy)
    }
}

// MARK: - Widgets

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacMonitor.Status", provider: MonitorProvider()) { entry in
            StatusEntryView(entry: entry)
        }
        .configurationDisplayName("Status")
        .description("Ampel, Auffälligkeiten sowie CPU und RAM auf einen Blick.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct StatusEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        StatusWidgetView(content: entry.content, size: family == .systemSmall ? .small : .medium)
            .widgetURL(URL(string: "macmonitor://overview"))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LoadWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MacMonitor.Load", intent: LoadWidgetIntent.self, provider: LoadProvider()) { entry in
            LoadWidgetView(content: entry.content,
                           showTemperature: entry.extras == .both || entry.extras == .temperature,
                           showPower: entry.extras == .both || entry.extras == .power)
                .widgetURL(URL(string: "macmonitor://dashboard/cpu"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Auslastung")
        .description("CPU, RAM und GPU mit Verlauf der letzten Stunde.")
        .supportedFamilies([.systemMedium])
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacMonitor.Battery", provider: MonitorProvider()) { entry in
            BatteryEntryView(entry: entry)
        }
        .configurationDisplayName("Akku und Energie")
        .description("Ladestand, Restlaufzeit, Leistung und Zustand des Akkus.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct BatteryEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        BatteryWidgetView(content: entry.content, size: family == .systemSmall ? .small : .medium)
            .widgetURL(URL(string: "macmonitor://dashboard/energie"))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacMonitor.Storage", provider: MonitorProvider()) { entry in
            StorageEntryView(entry: entry)
        }
        .configurationDisplayName("Speicherplatz")
        .description("Freier Platz auf dem Startvolume.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct StorageEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        StorageWidgetView(content: entry.content, size: family == .systemSmall ? .small : .medium)
            .widgetURL(URL(string: "macmonitor://dashboard/laufwerke"))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct TopAppsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacMonitor.TopApps", provider: MonitorProvider()) { entry in
            TopAppsEntryView(entry: entry)
        }
        .configurationDisplayName("Größte Verbraucher")
        .description("Die Apps mit der höchsten Last.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct TopAppsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        TopAppsWidgetView(content: entry.content, size: family == .systemLarge ? .large : .medium)
            .widgetURL(URL(string: "macmonitor://dashboard/apps"))
            .containerBackground(.fill.tertiary, for: .widget)
    }
}
