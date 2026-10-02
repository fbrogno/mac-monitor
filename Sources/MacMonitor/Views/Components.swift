import MonitorCore
import SwiftUI

enum Palette {
    static let ok = Color(red: 0.20, green: 0.78, blue: 0.47)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let critical = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let accent = Color(red: 0.24, green: 0.80, blue: 0.86)

    static func load(_ percent: Double) -> Color {
        percent >= 85 ? critical : percent >= 60 ? warn : ok
    }

    static func severity(_ severity: Severity) -> Color {
        switch severity {
        case .info: accent
        case .warning: warn
        case .critical: critical
        }
    }
}

/// Filled line chart for a 0…100 series. Pure SwiftUI so it renders in `ImageRenderer`.
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var ceiling: Double = 100

    var body: some View {
        GeometryReader { geo in
            let points = plotted(in: geo.size)
            if points.count > 1 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func plotted(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let clamped = min(max(v, 0), ceiling)
            return CGPoint(x: CGFloat(i) * step, y: size.height * (1 - clamped / ceiling))
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Two-option switch drawn in SwiftUI (AppKit-backed pickers do not render in screenshots).
struct MiniSegment: View {
    var options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i])
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(selection == i ? Color.primary : Color.secondary)
                    .background {
                        if selection == i {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = i }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct FooterButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}
