import Foundation

/// CSV and JSON export of a period. Pure functions over query results.
/// CSV: UTF-8, `\n` line ends, decimal point always `.`, times ISO-8601 UTC.
public enum HistoryExport {
    public static let csvHeader = "record,time,key,resolution_s,min,avg,max,count,rule,severity,kind,title,body,process"

    /// One long-format table: `metric` rows (key, resolution, min/avg/max/count) and `event` rows
    /// (rule, severity, kind, title, body, process). Series are ordered by key, then time.
    public static func csv(series: [MetricKey: [HistoryPoint]], events: [HistoryEvent]) -> Data {
        var lines = [csvHeader]
        let iso = formatter()
        for key in series.keys.sorted() {
            for p in series[key] ?? [] {
                lines.append([
                    "metric", iso.string(from: p.date), field(key.rawValue), String(Int(p.span.rounded())),
                    number(p.min), number(p.avg), number(p.max), String(p.count), "", "", "", "", "", "",
                ].joined(separator: ","))
            }
        }
        for e in events.sorted(by: { $0.date < $1.date }) {
            lines.append([
                "event", iso.string(from: e.date), field(e.key), "", "", "", "", "", field(e.rule),
                String(e.severity.rawValue), e.kind.rawValue, field(e.title), field(e.body), field(e.process ?? ""),
            ].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// `{"from", "to", "metrics": {key: [point]}, "events": [event]}` with sorted keys and
    /// ISO-8601 UTC times.
    public static func json(from: Date, to: Date, series: [MetricKey: [HistoryPoint]],
                            events: [HistoryEvent]) throws -> Data {
        struct Document: Encodable {
            let from: Date
            let to: Date
            let metrics: [String: [HistoryPoint]]
            let events: [HistoryEvent]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let metrics = Dictionary(uniqueKeysWithValues: series.map { ($0.key.rawValue, $0.value) })
        return try encoder.encode(Document(from: from, to: to, metrics: metrics,
                                           events: events.sorted { $0.date < $1.date }))
    }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    /// Locale-independent, at most 4 decimals, no trailing zeros.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text = String(format: "%.4f", locale: nil, value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// RFC 4180 quoting, plus a leading apostrophe against spreadsheet formula injection.
    static func field(_ raw: String) -> String {
        var text = raw
        if let first = text.first, "=+-@\t\r".contains(first) { text = "'" + text }
        guard text.contains(where: { ",\"\n\r".contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension HistoryStore {
    /// CSV for `[from, to)`: the given metrics (default: all with data) and all events.
    public func exportCSV(from: Date, to: Date, keys: [MetricKey]? = nil, maxPoints: Int = 5000) throws -> Data {
        HistoryExport.csv(series: try exportSeries(from: from, to: to, keys: keys, maxPoints: maxPoints),
                          events: try events(from: from, to: to))
    }

    public func exportJSON(from: Date, to: Date, keys: [MetricKey]? = nil, maxPoints: Int = 5000) throws -> Data {
        try HistoryExport.json(from: from, to: to,
                               series: try exportSeries(from: from, to: to, keys: keys, maxPoints: maxPoints),
                               events: try events(from: from, to: to))
    }

    private func exportSeries(from: Date, to: Date, keys: [MetricKey]?, maxPoints: Int) throws -> [MetricKey: [HistoryPoint]] {
        var out: [MetricKey: [HistoryPoint]] = [:]
        for key in try keys ?? metricKeys() {
            let points = try series(key, from: from, to: to, maxPoints: maxPoints)
            if !points.isEmpty { out[key] = points }
        }
        return out
    }
}
