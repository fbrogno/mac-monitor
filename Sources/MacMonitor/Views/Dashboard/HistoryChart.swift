import Charts
import MonitorCore
import SwiftUI

/// Unit of a chart's values: decides how numbers are written on the axis and in the tooltip.
enum ChartUnit {
    case percent, bytes, bytesPerSecond, watts, celsius, rpm, load

    func format(_ value: Double) -> String {
        switch self {
        case .percent: Format.percent(value)
        case .bytes: Format.bytes(UInt64(max(0, value)))
        case .bytesPerSecond: Format.rate(value)
        case .watts: Format.watts(value)
        case .celsius: Format.celsius(value)
        case .rpm: Format.rpm(value)
        case .load: Format.decimal(value, digits: 2)
        }
    }

    /// Shorter text for axis labels.
    func axis(_ value: Double) -> String {
        switch self {
        case .percent: Format.percent(value)
        case .bytes: Format.bytes(UInt64(max(0, value)))
        case .bytesPerSecond: Format.rate(value)
        case .watts: "\(Int(value.rounded())) W"
        case .celsius: "\(Int(value.rounded())) °"
        case .rpm: "\(Int(value.rounded()))"
        case .load: Format.decimal(value, digits: 1)
        }
    }
}

/// One drawn series: the mean as a line, min…max as a band behind it.
struct ChartLine: Identifiable {
    let id: String
    let name: String
    let color: Color
    let points: [HistoryPoint]
    var showsBand = true
}

/// Swift Charts line chart over a history series: holes in the data stay holes, min/max form a band
/// around the mean, hovering shows the value and the time.
struct HistoryChart: View {
    var lines: [ChartLine]
    var unit: ChartUnit
    var from: Date
    var to: Date
    /// Fixed value axis (e.g. 0…100); nil lets the chart choose.
    var domain: ClosedRange<Double>?
    var height: CGFloat = 150
    /// Small variant for tiles: no axes, no tooltip.
    var compact = false
    var showsLegend = false
    /// Pre-set hover position, used by the offline renderer to show the tooltip.
    var previewHover: Date?

    @State private var hover: Date?

    private struct Segment: Identifiable {
        let id: String
        let line: ChartLine
        let points: [HistoryPoint]
    }

    private var segments: [Segment] {
        lines.flatMap { line in
            line.points.measured.continuousSegments().enumerated().map {
                Segment(id: "\(line.id)#\($0.offset)", line: line, points: $0.element)
            }
        }
    }

    var body: some View {
        if lines.allSatisfy({ $0.points.measured.isEmpty }) {
            Text("Noch keine Messwerte in diesem Zeitraum")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                chart.frame(height: height)
                if showsLegend && lines.count > 1 { legend }
            }
        }
    }

    private var active: Date? { hover ?? previewHover }

    private var chart: some View {
        Chart {
            ForEach(segments) { segment in
                let single = segment.points.count == 1
                ForEach(segment.points, id: \.date) { point in
                    let x = point.date.addingTimeInterval(point.span / 2)
                    if segment.line.showsBand, !single, point.max > point.min {
                        AreaMark(x: .value("Zeit", x), yStart: .value("Min", point.min), yEnd: .value("Max", point.max),
                                 series: .value("Band", segment.id))
                            .foregroundStyle(segment.line.color.opacity(0.16))
                    }
                    LineMark(x: .value("Zeit", x), y: .value("Mittel", point.avg), series: .value("Linie", segment.id))
                        .foregroundStyle(segment.line.color)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.4 : 1.8, lineJoin: .round))
                    if single {
                        PointMark(x: .value("Zeit", x), y: .value("Mittel", point.avg))
                            .foregroundStyle(segment.line.color).symbolSize(compact ? 8 : 18)
                    }
                }
            }
            if !compact, let date = active, let hit = nearest(to: date) {
                RuleMark(x: .value("Zeit", hit))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .plot))) {
                        tooltip(at: hit)
                    }
                ForEach(lines) { line in
                    if let point = point(in: line, at: hit) {
                        PointMark(x: .value("Zeit", hit), y: .value("Mittel", point.avg))
                            .foregroundStyle(line.color).symbolSize(36)
                    }
                }
            }
        }
        .chartXScale(domain: from...to.addingTimeInterval(compact ? 0 : to.timeIntervalSince(from) * 0.04))
        .chartYScale(domain: yDomain)
        .chartXAxis(compact ? .hidden : .automatic)
        .chartXAxis {
            if !compact {
                AxisMarks(values: xTicks) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: xFormat, collisionResolution: .disabled).font(.system(size: 10)).foregroundStyle(Color.secondary)
                }
            }
        }
        .chartYAxis(compact ? .hidden : .automatic)
        .chartYAxis {
            if !compact {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(unit.axis(v)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            if !compact {
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                hover = proxy.value(atX: location.x - geo[frame].origin.x, as: Date.self)
                            case .ended:
                                hover = nil
                            }
                        }
                }
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        if let domain { return domain }
        let all = lines.flatMap { $0.points.measured }
        let high = all.map { $0.max }.max() ?? 1
        return 0...(high > 0 ? high * 1.12 : 1)
    }

    private var xTicks: AxisMarkValues {
        let span = to.timeIntervalSince(from)
        if span <= 2 * 3600 { return .stride(by: .minute, count: 15) }
        if span <= 36 * 3600 { return .stride(by: .hour, count: 4) }
        return .automatic(desiredCount: 6)
    }

    private var xFormat: Date.FormatStyle {
        to.timeIntervalSince(from) <= 36 * 3600
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(lines) { line in
                HStack(spacing: 5) {
                    Circle().fill(line.color).frame(width: 7, height: 7)
                    Text(line.name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Hover lookup

    private func point(in line: ChartLine, at date: Date) -> HistoryPoint? {
        line.points.measured.first { date >= $0.date && date < $0.date.addingTimeInterval($0.span) }
    }

    /// Centre of the bucket nearest to `date` in any line, if one lies under the cursor.
    private func nearest(to date: Date) -> Date? {
        var best: (distance: TimeInterval, center: Date)?
        for line in lines {
            for p in line.points.measured {
                let center = p.date.addingTimeInterval(p.span / 2)
                let distance = abs(center.timeIntervalSince(date))
                if distance <= p.span, best == nil || distance < best!.distance { best = (distance, center) }
            }
        }
        return best?.center
    }

    private func tooltip(at center: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(center.formatted(date: to.timeIntervalSince(from) <= 36 * 3600 ? .omitted : .abbreviated, time: .shortened))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            ForEach(lines) { line in
                if let p = point(in: line, at: center) {
                    HStack(spacing: 5) {
                        Circle().fill(line.color).frame(width: 6, height: 6)
                        Text(lines.count > 1 ? line.name : "").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(unit.format(p.avg)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        if line.showsBand, p.max > p.min {
                            Text("\(unit.format(p.min)) – \(unit.format(p.max))")
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize()
    }
}
