import Foundation

/// Number formatting with fixed precision. Decimal and grouping separators follow the user's
/// locale (`Format.locale`); units stay as they are.
public enum Format {
    /// Locale used by all functions here. The current locale unless a caller (tests, renderer)
    /// puts another one in place with `Format.$locale.withValue(_:operation:)`.
    @TaskLocal public static var locale: Locale = .autoupdatingCurrent

    public static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1024 { return decimal(gb / 1024, digits: 1) + " TB" }
        if gb >= 1 { return decimal(gb, digits: gb >= 100 ? 0 : 1) + " GB" }
        return decimal(Double(value) / 1_048_576, digits: 0) + " MB"
    }

    /// Throughput, e.g. "1,2 MB/s" or "84 KB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_048_576
        if mb >= 1 { return decimal(mb, digits: mb >= 100 ? 0 : 1) + " MB/s" }
        return decimal(bytesPerSecond / 1024, digits: 0) + " KB/s"
    }

    /// "3:05 h" for 185 minutes.
    public static func hoursMinutes(_ minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60) + " h"
    }

    /// "85 %" in German, "85%" in English (the catalog decides). The number goes in as text so it is
    /// never grouped ("1.020 %").
    public static func percent(_ value: Double) -> String {
        L("\(String(Int(value.rounded()))) %")
    }

    /// Fixed number of fraction digits, no grouping, the locale's decimal separator.
    public static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s / 60) min \(s % 60) s"
    }

    /// Power, e.g. "12,3 W"; below 10 W one decimal, above none.
    public static func watts(_ value: Double) -> String {
        decimal(value, digits: abs(value) >= 100 ? 0 : 1) + " W"
    }

    /// Whole-minute power in milliwatts for small consumers: "850 mW" below 1 W, else watts.
    public static func milliwatts(_ value: Double) -> String {
        abs(value) < 1000 ? "\(Int(value.rounded())) mW" : watts(value / 1000)
    }

    public static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded())) °C"
    }

    public static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded())) rpm"
    }

    /// Battery capacity, e.g. "4.520 mAh" (the locale's thousands separator).
    public static func milliampHours(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(locale)) + " mAh"
    }

    /// Uptime like "3 Tage 4 h" or "5 h 12 min".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        if days > 0 { return L("\(days) Tage") + " \(hours) h" }
        if hours > 0 { return "\(hours) h \(mins) min" }
        return "\(mins) min"
    }
}
