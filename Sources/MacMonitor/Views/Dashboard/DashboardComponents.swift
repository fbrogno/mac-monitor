import MonitorCore
import SwiftUI

/// Titled card of the history areas: one title style, secondary subtitle, current value on the right.
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            content
        }
        .padding(16)
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
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The current value in a card's header; `prominent: false` for longer texts such as two rates.
struct CardValue: View {
    var text: String
    var prominent = true

    init(_ text: String, prominent: Bool = true) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        Text(text)
            .font(prominent ? .system(size: 15, weight: .semibold, design: .rounded) : .system(size: 12, weight: .medium))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// Cards that sit side by side while there is room and stack below each other when it narrows.
struct CardGrid<Content: View>: View {
    var minimum: CGFloat = 380
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 16) {
            content
        }
    }
}

/// Left-aligned rows that wrap to the next line when the width runs out (legends, filter chips, buttons).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (view, point) in zip(subviews, result.positions) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
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
