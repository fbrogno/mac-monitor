import MonitorCore
import SwiftUI

/// Small secondary line under a setting.
struct SettingsNote: View {
    let text: LocalizedStringKey
    var tint: Color = .secondary

    init(_ text: LocalizedStringKey, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Error text next to the field it is about.
struct FieldError: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(messages, id: \.self) { message in
                    Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.critical)
                }
            }
        }
    }
}

/// A number with a unit and up/down buttons, e.g. "Ab CPU  90 %".
struct ValueStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(text).monospacedDigit().foregroundStyle(.secondary)
            Stepper(value: $value, in: range, step: step) { EmptyView() }
                .labelsHidden()
        }
    }

    private var text: String {
        let number = value == value.rounded() ? "\(Int(value))" : Format.decimal(value, digits: 1)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

/// A duration chosen from a list; the current value is always part of the list.
struct DurationPicker: View {
    let title: LocalizedStringKey
    @Binding var value: TimeInterval
    var options: [TimeInterval] = DurationPicker.standard

    static let standard: [TimeInterval] = [30, 60, 120, 180, 300, 600, 900, 1800, 3600]

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(Array(Set(options + [value])).sorted(), id: \.self) { Text(Self.text($0)).tag($0) }
        }
    }

    static func text(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return String(localized: "sofort") }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return String(localized: "\(Int(seconds / 86_400)) Tage") }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            return seconds == 3600 ? String(localized: "1 Stunde") : String(localized: "\(Int(seconds / 3600)) Stunden")
        }
        return Format.duration(seconds)
    }
}

/// A pane's page: a grouped form that fills the detail area.
struct PaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

extension Severity {
    var germanTitle: String {
        switch self {
        case .info: String(localized: "Hinweis")
        case .warning: String(localized: "Warnung")
        case .critical: String(localized: "Kritisch")
        }
    }
}

extension CustomMetric.Unit {
    /// Short unit for a threshold field.
    var symbol: String {
        switch self {
        case .percent: "%"
        case .gigabytes: "GB"
        case .celsius: "°C"
        case .watts: "W"
        case .megabytesPerSecond: "MB/s"
        }
    }
}
