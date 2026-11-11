import Foundation

extension Array where Element == HistoryPoint {
    /// Splits a series into runs without holes, so a chart can draw gaps (Mac off, asleep, app not
    /// running) as gaps instead of connecting across them. A hole is at least one whole missing bucket.
    public func continuousSegments(gapFactor: Double = 1.5) -> [[HistoryPoint]] {
        var result: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        for point in self.sorted(by: { $0.date < $1.date }) {
            if let last = current.last, point.date.timeIntervalSince(last.date) > gapFactor * last.span {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Buckets that hold at least one raw sample.
    public var measured: [HistoryPoint] { filter { $0.count > 0 } }
}
