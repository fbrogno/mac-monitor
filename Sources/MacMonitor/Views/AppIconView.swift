import SwiftUI

/// The app icon, drawn in code so the .icns, the README art and the in-app header stay identical.
/// `padded` applies the macOS icon grid (824 pt body on a 1024 pt canvas, with drop shadow).
struct AppIconView: View {
    var size: CGFloat
    var padded = false

    static let pulse: [CGPoint] = [
        (0.12, 0.57), (0.32, 0.57), (0.38, 0.49), (0.44, 0.57), (0.50, 0.57),
        (0.555, 0.20), (0.615, 0.80), (0.665, 0.50), (0.70, 0.57), (0.76, 0.57),
        (0.80, 0.51), (0.84, 0.57), (0.88, 0.57),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    var body: some View {
        let body = padded ? size * 824 / 1024 : size
        let radius = body * 0.2237

        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.13, green: 0.18, blue: 0.32), Color(red: 0.03, green: 0.05, blue: 0.11)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RadialGradient(colors: [Color(red: 0.18, green: 0.9, blue: 0.77).opacity(0.38), .clear],
                                   center: UnitPoint(x: 0.55, y: 0.62), startRadius: 0, endRadius: body * 0.62)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .overlay { grid(body).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(1, body * 0.006))
                }

            pulseLayer(body)
        }
        .frame(width: body, height: body)
        .shadow(color: .black.opacity(padded ? 0.35 : 0), radius: size * 0.025, y: size * 0.012)
        .frame(width: size, height: size)
    }

    private func grid(_ s: CGFloat) -> some View {
        Path { path in
            for i in 1..<8 {
                let y = s * CGFloat(i) / 8
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: s, y: y))
            }
        }
        .stroke(Color.white.opacity(0.05), lineWidth: max(0.5, s * 0.003))
    }

    private func pulseLayer(_ s: CGFloat) -> some View {
        let points = Self.pulse.map { CGPoint(x: $0.x * s, y: $0.y * s) }
        let line = Path { path in
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        let stroke = StrokeStyle(lineWidth: s * 0.05, lineCap: .round, lineJoin: .round)
        let gradient = LinearGradient(
            colors: [Color(red: 0.24, green: 0.95, blue: 0.78), Color(red: 0.31, green: 0.76, blue: 1.0)],
            startPoint: .leading, endPoint: .trailing)
        let end = points[points.count - 1]

        return ZStack {
            line.stroke(gradient, style: stroke)
                .blur(radius: s * 0.035)
                .opacity(0.9)
            line.stroke(gradient, style: stroke)
            Circle()
                .fill(Color.white)
                .frame(width: s * 0.075, height: s * 0.075)
                .shadow(color: Color(red: 0.31, green: 0.76, blue: 1.0), radius: s * 0.03)
                .position(end)
        }
        .frame(width: s, height: s)
    }
}
