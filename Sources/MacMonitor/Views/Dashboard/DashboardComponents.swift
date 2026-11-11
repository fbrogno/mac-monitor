import MonitorCore
import SwiftUI

/// Titled card in the dashboard's look (same family as `Card`, a little roomier).
struct DashCard<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

extension DashCard where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// Shown instead of a value the Mac does not report. Never a 0.
struct UnavailableNote: View {
    var text: String = String(localized: "Auf diesem Mac nicht verfügbar")

    var body: some View {
        Label(text, systemImage: "minus.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

/// A single number with a caption, for the large values of a card.
struct BigValue: View {
    var value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Label on the left, value on the right.
struct FactRow: View {
    var label: String
    var value: String
    var tint: Color = .primary

    init(_ label: String, _ value: String, tint: Color = .primary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Horizontal bar with a label above; `fraction` is 0…1.
struct MeterBar: View {
    var label: String
    var value: String
    var fraction: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Overview tile: live value, a small history underneath.
struct MetricTile: View {
    var title: String
    var symbol: String
    var value: String
    var detail: String?
    var tint: Color
    var lines: [ChartLine]
    var from: Date
    var to: Date
    var domain: ClosedRange<Double>?
    var unit: ChartUnit = .percent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail ?? " ").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if lines.contains(where: { !$0.points.measured.isEmpty }) {
                HistoryChart(lines: lines, unit: unit, from: from, to: to, domain: domain, height: 36, compact: true)
            } else {
                Color.clear.frame(height: 36)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Page header of one section: title, subtitle and the time range switch.
struct DashboardHeader: View {
    var title: String
    var subtitle: String
    var symbol: String
    var trailing: AnyView

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct RangeSwitch: View {
    @Binding var range: DashboardRange

    var body: some View {
        let selection = Binding<Int>(
            get: { DashboardRange.allCases.firstIndex(of: range) ?? 1 },
            set: { range = DashboardRange.allCases[$0] })
        MiniSegment(options: DashboardRange.allCases.map(\.title), selection: selection)
    }
}

func loadColor(_ percent: Double) -> Color { Palette.load(percent) }

/// "dd.MM. HH:mm" style time stamp for lists.
func shortStamp(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.twoDigits).hour().minute())
}

func durationText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return Format.duration(seconds) }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    return hours < 48 ? "\(hours) h \(minutes % 60) min" : String(localized: "\(hours / 24) Tage") + " \(hours % 24) h"
}
