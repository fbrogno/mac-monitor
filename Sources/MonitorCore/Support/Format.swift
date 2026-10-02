import Foundation

/// German number formatting with fixed precision, independent of the user's locale.
public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return decimal(gb, digits: gb >= 100 ? 0 : 1) + " GB" }
        return decimal(Double(value) / 1_048_576, digits: 0) + " MB"
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    public static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s % 60 == 0 { return "\(s / 60) min" }
        return "\(s / 60) min \(s % 60) s"
    }
}
