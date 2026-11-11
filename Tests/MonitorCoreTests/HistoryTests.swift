import Foundation
import SQLite3
import Testing
@testable import MonitorCore

// MARK: Helpers

private let utc = TimeZone(identifier: "UTC")!
private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0,
                  in zone: TimeZone = utc) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mm-history-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func withTempStore<T>(retention: RetentionPolicy = .standard, timeZone: TimeZone = utc, now: Date,
                              _ body: (HistoryStore, URL) async throws -> T) async throws -> T {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let store = try HistoryStore(url: url, retention: retention, timeZone: timeZone, now: now)
    return try await body(store, url)
}

private func cpu(_ value: Double) -> [MetricSample] { [MetricSample(.cpuTotal, value)] }

private func point(_ t: Date, avg: Double, min: Double? = nil, max: Double? = nil, count: Int = 1,
                   span: TimeInterval = 60) -> HistoryPoint {
    HistoryPoint(date: t, min: min ?? avg, avg: avg, max: max ?? avg, count: count, resolution: .minute, span: span)
}

private func event(_ t: Date, _ kind: EventKind, key: String = "cpu.high", rule: RuleID = .cpuHigh,
                   severity: Severity = .warning, title: String = "CPU hoch", process: String? = nil) -> HistoryEvent {
    HistoryEvent(date: t, key: key, rule: rule.rawValue, severity: severity, kind: kind, title: title,
                 body: "", process: process)
}

private let gb: UInt64 = 1_073_741_824

// MARK: Compaction and retention

@Suite struct HistoryCompactionTests {
    let t0 = date(2026, 3, 10, 12, 0)

    @Test func rollUpWeightsByCountNotMeanOfMeans() async throws {
        try await withTempStore(now: t0) { store, _ in
            // Minute 0 holds three samples, minute 1 one sample, both in the 12:00 window.
            for (offset, value) in [(0.0, 10.0), (10, 20), (20, 30), (60, 50)] {
                await store.record(cpu(value), at: t0.addingTimeInterval(offset))
            }
            try await store.compact(now: t0.addingTimeInterval(3600))

            let minutes = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(120), maxPoints: 10)
            #expect(minutes.map(\.resolution) == [.minute, .minute])
            #expect(minutes.map(\.avg) == [20, 50])
            #expect(minutes.map(\.count) == [3, 1])

            let quarter = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(3600), maxPoints: 4)
            #expect(quarter.count == 1)
            #expect(quarter[0].resolution == .quarterHour)
            #expect(quarter[0].min == 10)
            #expect(quarter[0].max == 50)
            #expect(quarter[0].count == 4)
            #expect(quarter[0].avg == 27.5)   // not (20 + 50) / 2

            let day = try await store.series(.cpuTotal, from: t0.addingTimeInterval(-43_200),
                                             to: t0.addingTimeInterval(43_200), maxPoints: 1)
            #expect(day.count == 1)
            #expect(day[0].resolution == .day)
            #expect(day[0].date == date(2026, 3, 10))
            #expect(day[0].avg == 27.5)
            #expect(day[0].count == 4)
        }
    }

    @Test func compactIsIdempotentAndIncremental() async throws {
        try await withTempStore(now: t0) { store, _ in
            await store.record(cpu(10), at: t0)
            try await store.compact(now: t0.addingTimeInterval(600))
            await store.record(cpu(30), at: t0.addingTimeInterval(700))
            try await store.compact(now: t0.addingTimeInterval(800))
            try await store.compact(now: t0.addingTimeInterval(800))
            let quarter = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(900), maxPoints: 1)
            #expect(quarter.count == 1)
            #expect(quarter[0].count == 2)
            #expect(quarter[0].avg == 20)
        }
    }

    @Test func oldBucketsAreDroppedCondensedOnesStay() async throws {
        let now = date(2026, 3, 10, 12, 0)
        try await withTempStore(now: now) { store, _ in
            let old = now.addingTimeInterval(-50 * 3600)
            let recent = now.addingTimeInterval(-3600)
            await store.record(cpu(40), at: old)
            await store.record(cpu(60), at: recent)
            try await store.compact(now: now)

            #expect(try await store.bucketCount(.minute) == 1)          // only the recent minute
            #expect(try await store.bucketCount(.quarterHour) == 2)     // both condensed

            // The old minute is gone; the query falls back to the 15-minute bucket.
            let oldSeries = try await store.series(.cpuTotal, from: old.addingTimeInterval(-300),
                                                   to: old.addingTimeInterval(300), maxPoints: 100)
            #expect(oldSeries.count == 1)
            #expect(oldSeries[0].resolution == .quarterHour)
            #expect(oldSeries[0].avg == 40)
            let recentSeries = try await store.series(.cpuTotal, from: recent.addingTimeInterval(-300),
                                                      to: recent.addingTimeInterval(300), maxPoints: 100)
            #expect(recentSeries.map(\.resolution) == [.minute])
        }
    }

    @Test func quarterAndDayTiersHaveTheirOwnRetention() async throws {
        let now = date(2026, 3, 10, 12, 0)
        try await withTempStore(now: now) { store, _ in
            await store.record(cpu(1), at: now.addingTimeInterval(-800 * 86_400))   // beyond 2 years
            await store.record(cpu(2), at: now.addingTimeInterval(-40 * 86_400))    // beyond 30 days
            await store.record(cpu(3), at: now.addingTimeInterval(-10 * 86_400))
            try await store.compact(now: now)
            #expect(try await store.bucketCount(.minute) == 0)
            #expect(try await store.bucketCount(.quarterHour) == 1)   // only the 10-day-old one
            #expect(try await store.bucketCount(.day) == 2)           // 800 days is gone
            let days = try await store.series(.cpuTotal, from: now.addingTimeInterval(-45 * 86_400), to: now, maxPoints: 50)
            #expect(days.map(\.avg) == [2, 3])
        }
    }

    @Test func bucketOnTheCutoffEdgeIsKeptUntilItIsEntirelyOld() async throws {
        let now = date(2026, 3, 10, 12, 0)
        let cut = now.addingTimeInterval(-48 * 3600)
        try await withTempStore(now: now) { store, _ in
            await store.record(cpu(1), at: cut.addingTimeInterval(-60))   // ends exactly at the cutoff
            await store.record(cpu(2), at: cut)                           // starts at the cutoff
            try await store.compact(now: now)
            #expect(try await store.bucketCount(.minute) == 1)

            // Cutoff 30 s later: the bucket starting at `cut` still overlaps retention.
            try await store.compact(now: now.addingTimeInterval(30))
            #expect(try await store.bucketCount(.minute) == 1)
            // 61 s later it lies entirely before the cutoff.
            try await store.compact(now: now.addingTimeInterval(61))
            #expect(try await store.bucketCount(.minute) == 0)
            #expect(try await store.bucketCount(.quarterHour) >= 1)
        }
    }

    @Test func dayBucketsFollowLocalTimeAcrossSpringForward() async throws {
        // Europe/Berlin switches to summer time on 2026-03-29: that day has 23 hours.
        let now = date(2026, 3, 31, 12, 0, in: berlin)
        try await withTempStore(timeZone: berlin, now: now) { store, _ in
            await store.record(cpu(10), at: date(2026, 3, 28, 23, 30, in: berlin))   // still the 28th
            await store.record(cpu(20), at: date(2026, 3, 29, 0, 30, in: berlin))
            await store.record(cpu(40), at: date(2026, 3, 29, 23, 30, in: berlin))
            await store.record(cpu(80), at: date(2026, 3, 30, 0, 10, in: berlin))    // next day
            try await store.compact(now: now)

            let days = try await store.series(.cpuTotal, from: date(2026, 3, 28, in: berlin),
                                              to: date(2026, 3, 31, in: berlin), maxPoints: 3)
            #expect(days.map(\.resolution) == [.day, .day, .day])
            #expect(days.map(\.date) == [date(2026, 3, 28, in: berlin), date(2026, 3, 29, in: berlin), date(2026, 3, 30, in: berlin)])
            #expect(days.map(\.avg) == [10, 30, 80])
            #expect(days.map(\.count) == [1, 2, 1])
            #expect(days[1].span == 23 * 3600)
            #expect(days[0].span == 24 * 3600)
        }
    }

    @Test func timeZoneChangeLeavesNoOverlappingDayBuckets() async throws {
        let now = date(2026, 3, 10, 12, 0, in: berlin)
        let samples: [(Date, Double)] = [(date(2026, 3, 8, 12, 0), 10), (date(2026, 3, 9, 12, 0), 20),
                                         (date(2026, 3, 10, 2, 0), 30)]   // UTC times
        try await withTempStore(timeZone: berlin, now: now) { store, url in
            for (time, value) in samples { await store.record(cpu(value), at: time) }
            try await store.compact(now: now)
            try await store.close()

            // The Mac moves to UTC: day rows are now cut at UTC midnight, the old ones at Berlin midnight.
            let moved = try HistoryStore(url: url, timeZone: utc, now: now.addingTimeInterval(7200))
            try await moved.compact(now: now.addingTimeInterval(7200))

            let days = try await moved.series(.cpuTotal, from: date(2026, 3, 1), to: date(2026, 3, 11), maxPoints: 20)
            #expect(days.allSatisfy { $0.resolution == .day })
            // Every sample is in exactly one day bucket, and no two buckets overlap.
            #expect(days.reduce(0) { $0 + $1.count } == 3)
            let ordered = days.sorted { $0.date < $1.date }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                #expect(a.date.addingTimeInterval(a.span) <= b.date, "\(a.date) und \(b.date) überlappen")
            }
            // The recomputed days are cut at UTC midnight.
            #expect(days.map(\.date).contains(date(2026, 3, 9)))
            #expect(days.map(\.date).contains(date(2026, 3, 10)))
        }
    }

    @Test func dayBucketsFollowLocalTimeAcrossFallBack() async throws {
        // Clocks go back on 2026-10-25: 25 hours.
        let now = date(2026, 10, 27, 12, 0, in: berlin)
        try await withTempStore(timeZone: berlin, now: now) { store, _ in
            await store.record(cpu(10), at: date(2026, 10, 25, 0, 30, in: berlin))
            await store.record(cpu(30), at: date(2026, 10, 25, 23, 30, in: berlin))
            await store.record(cpu(50), at: date(2026, 10, 26, 0, 30, in: berlin))
            try await store.compact(now: now)
            let days = try await store.series(.cpuTotal, from: date(2026, 10, 25, in: berlin),
                                              to: date(2026, 10, 27, in: berlin), maxPoints: 2)
            #expect(days.map(\.avg) == [20, 50])
            #expect(days[0].span == 25 * 3600)
        }
    }
}

// MARK: Queries

@Suite struct HistoryQueryTests {
    let t0 = date(2026, 3, 10, 12, 0)

    @Test func tierFollowsRangeAndMaxPoints() {
        #expect(Resolution.choose(range: 3600, maxPoints: 100) == .minute)
        #expect(Resolution.choose(range: 48 * 3600, maxPoints: 3000) == .minute)
        #expect(Resolution.choose(range: 48 * 3600, maxPoints: 400) == .quarterHour)
        #expect(Resolution.choose(range: 7 * 86_400, maxPoints: 700) == .quarterHour)
        #expect(Resolution.choose(range: 7 * 86_400, maxPoints: 100) == .day)
        #expect(Resolution.choose(range: 365 * 86_400, maxPoints: 10) == .day)   // nothing fits: coarsest
        #expect(Resolution.choose(range: 100, maxPoints: 0) == .quarterHour)   // maxPoints is at least 1
        #expect(Resolution.choose(range: 3 * 86_400, maxPoints: 0) == .day)
    }

    @Test func gapsStayGaps() async throws {
        try await withTempStore(now: t0) { store, _ in
            for minute in [0, 1, 2, 20, 21] {
                await store.record(cpu(Double(minute)), at: t0.addingTimeInterval(Double(minute) * 60))
            }
            try await store.flush()
            let points = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(1800), maxPoints: 100)
            #expect(points.map { Int($0.date.timeIntervalSince(t0) / 60) } == [0, 1, 2, 20, 21])
        }
    }

    @Test func rangeIsHalfOpenAndEmptyRangesAreEmpty() async throws {
        try await withTempStore(now: t0) { store, _ in
            await store.record(cpu(1), at: t0)
            await store.record(cpu(2), at: t0.addingTimeInterval(60))
            try await store.flush()
            let first = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(60), maxPoints: 10)
            #expect(first.map(\.avg) == [1])
            #expect(try await store.series(.cpuTotal, from: t0, to: t0, maxPoints: 10).isEmpty)
            #expect(try await store.series(.netUp, from: t0, to: t0.addingTimeInterval(600), maxPoints: 10).isEmpty)
        }
    }

    @Test func bufferedDataIsVisibleBeforeFlush() async throws {
        try await withTempStore(now: t0) { store, _ in
            await store.record(cpu(7), at: t0.addingTimeInterval(5))
            let points = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(60), maxPoints: 10)
            #expect(points.map(\.avg) == [7])
            #expect(try await store.metricKeys() == [.cpuTotal])
        }
    }
}

// MARK: Buffering, files, recovery

@Suite struct HistoryStorageTests {
    let t0 = date(2026, 3, 10, 12, 0)

    @Test func openingAnInvalidPathThrowsWithoutDoubleClose() {
        // The failed init closes the handle itself and `deinit` must not close it again.
        let missing = tempDirectory().appendingPathComponent("gibt-es-nicht/history.sqlite").path
        for _ in 0..<50 {
            #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(path: missing) }
        }
        // A directory is not a database either.
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: SQLiteError.self) { _ = try SQLiteDatabase(path: directory.path) }
        // And a valid path still opens.
        let ok = directory.appendingPathComponent("ok.sqlite").path
        #expect(throws: Never.self) { _ = try SQLiteDatabase(path: ok) }
    }

    @Test func writesOncePerMinuteAndFlushWritesTheRest() async throws {
        try await withTempStore(now: t0) { store, url in
            for step in 0..<6 {   // six samples inside one minute
                await store.record(cpu(Double(step)), at: t0.addingTimeInterval(Double(step) * 10))
            }
            #expect(await store.writeCount == 0)
            #expect(try await store.bucketCount(.minute) == 0)

            await store.record(cpu(100), at: t0.addingTimeInterval(65))   // new minute: previous one goes out
            #expect(await store.writeCount == 1)
            #expect(try await store.bucketCount(.minute) == 1)

            await store.record(cpu(101), at: t0.addingTimeInterval(80))   // same minute: no write
            #expect(await store.writeCount == 1)

            try await store.flush()
            #expect(await store.writeCount == 2)
            try await store.flush()                                      // nothing left
            #expect(await store.writeCount == 2)

            // A second flush of the same minute merges instead of overwriting.
            await store.record(cpu(102), at: t0.addingTimeInterval(90))
            try await store.flush()
            try await store.close()

            let reopened = try HistoryStore(url: url, now: t0)
            let points = try await reopened.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(180), maxPoints: 10)
            #expect(points.map(\.count) == [6, 3])
            #expect(points[0].avg == 2.5)
            #expect(points[1].min == 100)
            #expect(points[1].max == 102)
        }
    }

    @Test func dataSurvivesReopeningWithoutClose() async throws {
        try await withTempStore(now: t0) { store, url in
            await store.record(cpu(5), at: t0)
            try await store.flush()
            let second = try HistoryStore(url: url, now: t0)   // WAL file still present
            let points = try await second.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(60), maxPoints: 5)
            #expect(points.map(\.avg) == [5])
            #expect(await second.replacedFile == nil)
        }
    }

    @Test func damagedFileIsReplacedNotFatal() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        try Data("this is definitely not a sqlite database, just some text".utf8).write(to: url)

        let store = try HistoryStore(url: url, now: t0)
        let backup = try #require(await store.replacedFile)
        #expect(backup.lastPathComponent.hasPrefix("history.sqlite.corrupt-2026-03-10T12-00-00Z"))
        #expect(FileManager.default.fileExists(atPath: backup.path))

        await store.record(cpu(3), at: t0)
        try await store.flush()
        let points = try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(60), maxPoints: 5)
        #expect(points.map(\.avg) == [3])
    }

    @Test func incompatibleSchemaVersionIsReplaced() async throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TABLE metric(x); PRAGMA user_version = 99;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let store = try HistoryStore(url: url, now: t0)
        #expect(await store.replacedFile != nil)
        await store.record(cpu(1), at: t0)
        try await store.flush()
        #expect(try await store.metricKeys() == [.cpuTotal])
    }

    @Test func memoryDatabaseWorks() async throws {
        let store = try HistoryStore(path: ":memory:", now: t0)
        await store.record(cpu(4), at: t0)
        try await store.flush()
        try await store.compact(now: t0)
        #expect(try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(60), maxPoints: 5).count == 1)
        #expect(store.fileSizeBytes() == 0)
    }

    @Test func sizeAndDeleteAll() async throws {
        try await withTempStore(now: t0) { store, _ in
            for minute in 0..<200 {
                await store.record(cpu(Double(minute)), at: t0.addingTimeInterval(Double(minute) * 60))
            }
            await store.record(AlertEvent(date: t0, kind: .fired, condition: condition("a")))
            try await store.flush()
            #expect(store.fileSizeBytes() > 0)

            try await store.deleteAll()
            #expect(try await store.metricKeys().isEmpty)
            #expect(try await store.events(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(1)).isEmpty)
            #expect(try await store.series(.cpuTotal, from: t0, to: t0.addingTimeInterval(86_400), maxPoints: 5000).isEmpty)
            // Still usable afterwards.
            await store.record(cpu(1), at: t0)
            #expect(try await store.metricKeys() == [.cpuTotal])
        }
    }
}

private func condition(_ key: String, rule: RuleID = .cpuHigh, severity: Severity = .warning,
                       process: ProcessRef? = nil) -> Condition {
    Condition(key: key, rule: rule, severity: severity, title: "Titel \(key)", body: "Text, mit \"Komma\"",
              sustain: 0, process: process)
}

// MARK: Events, incidents

@Suite struct HistoryEventTests {
    let t0 = date(2026, 3, 10, 12, 0)

    @Test func eventsArePersistedAndFilterable() async throws {
        try await withTempStore(now: t0) { store, url in
            await store.record(events: [
                AlertEvent(date: t0, kind: .fired, condition: condition("cpu.Xcode", process: ProcessRef(pid: 5, name: "Xcode"))),
                AlertEvent(date: t0.addingTimeInterval(60), kind: .fired, condition: condition("swap", rule: .swap, severity: .critical)),
                AlertEvent(date: t0.addingTimeInterval(120), kind: .resolved, condition: condition("cpu.Xcode")),
            ])
            let reopened = try HistoryStore(url: url, now: t0)
            let all = try await reopened.events(from: t0, to: t0.addingTimeInterval(3600))
            #expect(all.map(\.kind) == [.fired, .fired, .resolved])
            #expect(all[0].process == "Xcode")
            #expect(all[0].ruleID == .cpuHigh)
            #expect(all[1].severity == .critical)
            #expect(all[0].body == "Text, mit \"Komma\"")

            let swapOnly = try await reopened.events(from: t0, to: t0.addingTimeInterval(3600), rule: .swap)
            #expect(swapOnly.map(\.key) == ["swap"])
            let window = try await reopened.events(from: t0.addingTimeInterval(60), to: t0.addingTimeInterval(120))
            #expect(window.map(\.key) == ["swap"])
        }
    }

    @Test func eventsExpireAfterRetention() async throws {
        try await withTempStore(now: t0) { store, _ in
            await store.record(AlertEvent(date: t0.addingTimeInterval(-91 * 86_400), kind: .fired, condition: condition("old")))
            await store.record(AlertEvent(date: t0.addingTimeInterval(-89 * 86_400), kind: .fired, condition: condition("new")))
            try await store.compact(now: t0)
            let kept = try await store.events(from: t0.addingTimeInterval(-200 * 86_400), to: t0)
            #expect(kept.map(\.key) == ["new"])
        }
    }

    @Test func incidentsPairFiredWithResolved() {
        let t = date(2026, 3, 10, 12, 0)
        let events = [
            event(t.addingTimeInterval(600), .resolved, key: "a"),
            event(t, .fired, key: "a", severity: .warning),
            event(t.addingTimeInterval(120), .escalated, key: "a", severity: .critical),
            event(t.addingTimeInterval(60), .fired, key: "b", rule: .swap),
            event(t.addingTimeInterval(90), .fired, key: "b", rule: .swap),             // repeated fired: ignored
            event(t.addingTimeInterval(700), .fired, key: "a"),                          // new incident, still open
            event(t.addingTimeInterval(50), .resolved, key: "orphan"),                   // no fired: ignored
            event(t.addingTimeInterval(55), .reminder, key: "orphan2"),
        ]
        let incidents = Incident.build(from: events)
        #expect(incidents.map(\.key) == ["a", "b", "a"])
        #expect(incidents[0].severity == .critical)
        #expect(incidents[0].end == t.addingTimeInterval(600))
        #expect(incidents[0].duration(asOf: t.addingTimeInterval(9999)) == 600)
        #expect(incidents[1].end == nil)
        #expect(incidents[1].duration(asOf: t.addingTimeInterval(360)) == 300)
        #expect(incidents[2].end == nil)
        #expect(incidents[2].duration(asOf: t.addingTimeInterval(1000)) == 300)
    }

    @Test func storeIncidentsIncludeOnesStartedBeforeTheWindow() async throws {
        try await withTempStore(now: t0) { store, _ in
            await store.record(events: [
                AlertEvent(date: t0, kind: .fired, condition: condition("a")),
                AlertEvent(date: t0.addingTimeInterval(7200), kind: .resolved, condition: condition("a")),
            ])
            let incidents = try await store.incidents(from: t0.addingTimeInterval(3600), to: t0.addingTimeInterval(4000))
            #expect(incidents.count == 1)
            #expect(incidents[0].duration(asOf: t0) == 7200)
            let none = try await store.incidents(from: t0.addingTimeInterval(8000), to: t0.addingTimeInterval(9000))
            #expect(none.isEmpty)
        }
    }
}

// MARK: Process ranking

@Suite struct HistoryProcessTests {
    let t0 = date(2026, 3, 10, 12, 0)

    @Test func rankingSumsCPUTimeAndKeepsPeakMemory() async throws {
        try await withTempStore(now: t0) { store, url in
            // Two 15-minute buckets, samples standing for 10 s each.
            await store.recordProcesses([ProcessUsage(group: "Xcode", cpuPercent: 200, footprintBytes: 2 * gb),
                                         ProcessUsage(group: "Safari", cpuPercent: 50, footprintBytes: 4 * gb)],
                                        at: t0, interval: 10)
            await store.recordProcesses([ProcessUsage(group: "Xcode", cpuPercent: 100, footprintBytes: 3 * gb),
                                         ProcessUsage(group: "Safari", cpuPercent: 0, footprintBytes: 1 * gb)],
                                        at: t0.addingTimeInterval(10), interval: 10)
            await store.recordProcesses([ProcessUsage(group: "Xcode", cpuPercent: 100, footprintBytes: 1 * gb)],
                                        at: t0.addingTimeInterval(900), interval: 10)
            // Not yet written (running bucket) but already visible.
            let live = try await store.topProcesses(from: t0, to: t0.addingTimeInterval(1800))
            #expect(live.byCPU.map(\.group) == ["Xcode", "Safari"])
            #expect(live.byCPU[0].cpuSeconds == 40)     // 20 + 10 + 10
            #expect(live.byCPU[1].cpuSeconds == 5)
            #expect(live.byMemory.map(\.group) == ["Safari", "Xcode"])
            #expect(live.byMemory[0].peakFootprintBytes == 4 * gb)
            #expect(live.byMemory[1].peakFootprintBytes == 3 * gb)

            try await store.flush()
            let reopened = try HistoryStore(url: url, now: t0)
            let stored = try await reopened.topProcesses(from: t0, to: t0.addingTimeInterval(1800))
            #expect(stored == live)

            let firstBucketOnly = try await reopened.topProcesses(from: t0, to: t0.addingTimeInterval(900), limit: 1)
            #expect(firstBucketOnly.byCPU.map(\.group) == ["Xcode"])
            #expect(firstBucketOnly.byCPU[0].cpuSeconds == 30)
        }
    }

    @Test func onlyTopTenPerBucketAreKept() async throws {
        try await withTempStore(now: t0) { store, _ in
            // 12 groups: CPU ascending with index, memory descending with index.
            let usages = (0..<12).map { ProcessUsage(group: "p\($0)", cpuPercent: Double($0 + 1) * 10,
                                                      footprintBytes: UInt64(12 - $0) * gb) }
            await store.recordProcesses(usages, at: t0, interval: 10)
            try await store.flush()
            let top = try await store.topProcesses(from: t0, to: t0.addingTimeInterval(900), limit: 100)
            // Top 10 by CPU: p2…p11; top 10 by memory: p0…p9; union = all 12 groups.
            #expect(top.byMemory.count == 12)
            // With 20 distinct groups, 10 high CPU ones and 10 high memory ones survive.
            let many = (0..<20).map { ProcessUsage(group: "q\($0)", cpuPercent: $0 < 10 ? 100 : 1,
                                                    footprintBytes: $0 < 10 ? 1 : 9 * gb) }
            await store.recordProcesses(many, at: t0.addingTimeInterval(900), interval: 10)
            try await store.flush()
            let second = try await store.topProcesses(from: t0.addingTimeInterval(900), to: t0.addingTimeInterval(1800), limit: 100)
            #expect(second.byMemory.count == 20)
            let capped = (0..<30).map { ProcessUsage(group: "r\($0)", cpuPercent: Double($0), footprintBytes: UInt64($0) * gb) }
            await store.recordProcesses(capped, at: t0.addingTimeInterval(1800), interval: 10)
            try await store.flush()
            let third = try await store.topProcesses(from: t0.addingTimeInterval(1800), to: t0.addingTimeInterval(2700), limit: 100)
            #expect(third.byMemory.count == 10)   // CPU and memory rankings coincide: 10 groups
            #expect(Set(third.byCPU.map(\.group)) == Set((20..<30).map { "r\($0)" }))
        }
    }

    @Test func rankingExpiresAfterThirtyDays() async throws {
        let now = date(2026, 4, 20, 12, 0)
        try await withTempStore(now: now) { store, _ in
            await store.recordProcesses([ProcessUsage(group: "old", cpuPercent: 100, footprintBytes: gb)],
                                        at: now.addingTimeInterval(-31 * 86_400), interval: 10)
            await store.recordProcesses([ProcessUsage(group: "new", cpuPercent: 100, footprintBytes: gb)],
                                        at: now.addingTimeInterval(-86_400), interval: 10)
            try await store.compact(now: now)
            let top = try await store.topProcesses(from: now.addingTimeInterval(-100 * 86_400), to: now)
            #expect(top.byCPU.map(\.group) == ["new"])
        }
    }

    @Test func usagesGroupBySuppliedKey() {
        let snapshot = SystemSnapshot(
            date: .now, cpuPercent: 0, memoryUsedBytes: 0, memoryTotalBytes: gb, memoryPressure: .normal,
            swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, power: .unknown,
            processes: [ProcessStat(pid: 1, name: "Chrome Helper", cpuPercent: 30, footprintBytes: gb),
                        ProcessStat(pid: 2, name: "Chrome Helper", cpuPercent: 20, footprintBytes: 2 * gb),
                        ProcessStat(pid: 3, name: "Mail", cpuPercent: 1, footprintBytes: gb)])
        let byName = ProcessUsage.usages(from: snapshot).sorted { $0.group < $1.group }
        #expect(byName == [ProcessUsage(group: "Chrome Helper", cpuPercent: 50, footprintBytes: 3 * gb),
                           ProcessUsage(group: "Mail", cpuPercent: 1, footprintBytes: gb)])
        let byApp = ProcessUsage.usages(from: snapshot) { $0.name.hasPrefix("Chrome") ? "Chrome" : $0.name }
        #expect(byApp.contains(ProcessUsage(group: "Chrome", cpuPercent: 50, footprintBytes: 3 * gb)))
    }
}

// MARK: Adapter

@Suite struct HistoryAdapterTests {
    @Test func snapshotMapsToMetrics() {
        let snapshot = SystemSnapshot(
            date: .now, cpuPercent: 42, memoryUsedBytes: 8 * gb, memoryTotalBytes: 16 * gb,
            memoryPressure: .warning, swapUsedBytes: 3 * gb, thermal: .fair,
            disk: DiskStat(availableBytes: 100 * gb, totalBytes: 500 * gb), isOnline: true,
            network: NetworkRate(downBytesPerSecond: 1000, upBytesPerSecond: 200),
            power: PowerState(onBattery: true, batteryPercent: 77, lowPowerMode: false), processes: [])
        let values = Dictionary(uniqueKeysWithValues: MetricSample.samples(from: snapshot).map { ($0.key.rawValue, $0.value) })
        #expect(values["cpu.total"] == 42)
        #expect(values["memory.used"] == Double(8 * gb))
        #expect(values["memory.percent"] == 50)
        #expect(values["memory.pressure"] == 1)
        #expect(values["memory.underPressure"] == 1)
        #expect(values["swap.used"] == Double(3 * gb))
        #expect(values["thermal.level"] == 1)
        #expect(values["disk.free"] == Double(100 * gb))
        #expect(values["net.down"] == 1000)
        #expect(values["net.up"] == 200)
        #expect(values["battery.percent"] == 77)
    }

    @Test func missingOptionalFieldsAreSkipped() {
        let snapshot = SystemSnapshot(
            date: .now, cpuPercent: 1, memoryUsedBytes: 0, memoryTotalBytes: 0, memoryPressure: .normal,
            swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, power: .unknown, processes: [])
        let keys = Set(MetricSample.samples(from: snapshot).map(\.key.rawValue))
        #expect(!keys.contains("disk.free") && !keys.contains("net.down") && !keys.contains("battery.percent"))
        #expect(MetricSample.samples(from: snapshot).first { $0.key == .memoryPercent }?.value == 0)   // no 0/0
    }
}

extension HistoryAdapterTests {
    private func base() -> SystemSnapshot {
        SystemSnapshot(
            date: .now, cpuPercent: 10, memoryUsedBytes: gb, memoryTotalBytes: 8 * gb, memoryPressure: .normal,
            swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, power: .unknown, processes: [])
    }

    @Test func extendedFieldsMapToMetrics() {
        let snapshot = SystemSnapshot(
            date: .now, cpuPercent: 10, memoryUsedBytes: gb, memoryTotalBytes: 8 * gb, memoryPressure: .normal,
            swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, power: .unknown, processes: [],
            cpuCores: CPUCoreLoad(perCore: [10, 30, 50, 70, 90], efficiencyCoreCount: 2, performanceCoreCount: 3),
            gpu: GPUStat(utilizationPercent: 35, memoryUsedBytes: 2 * gb),
            thermals: ThermalSensors(cpuAverageCelsius: 48, cpuMaxCelsius: 61, batteryCelsius: 31, sensors: []),
            fans: [FanStat(index: 0, rpm: 1500, minRpm: 1200, maxRpm: 5800), FanStat(index: 1, rpm: 2100, minRpm: 1200, maxRpm: 5800)],
            powerDraw: SystemPowerDraw(systemWatts: 17.5, cpuWatts: 6.5, gpuWatts: 2.25),
            diskThroughput: DiskThroughput(readBytesPerSecond: 4000, writeBytesPerSecond: 9000),
            runtime: RuntimeStat(uptimeSeconds: 100, loadAverage: LoadAverage(one: 2.5, five: 2, fifteen: 1), processCount: 1, threadCount: 1))
        let v = Dictionary(uniqueKeysWithValues: MetricSample.samples(from: snapshot).map { ($0.key.rawValue, $0.value) })
        #expect(v["gpu.percent"] == 35)
        #expect(v["gpu.memory"] == Double(2 * gb))
        #expect(v["cpu.efficiency"] == 20)
        #expect(v["cpu.performance"] == 70)
        #expect(v["temp.cpu.avg"] == 48)
        #expect(v["temp.cpu.max"] == 61)
        #expect(v["temp.battery"] == 31)
        #expect(v["power.system"] == 17.5)
        #expect(v["power.cpu"] == 6.5)
        #expect(v["power.gpu"] == 2.25)
        #expect(v["fan.max"] == 2100)
        #expect(v["disk.read"] == 4000)
        #expect(v["disk.write"] == 9000)
        #expect(v["load.1m"] == 2.5)
    }

    @Test func missingExtendedFieldsWriteNoRows() {
        // Nothing reported on this Mac: no row at all, never a stand-in 0.
        let keys = Set(MetricSample.samples(from: base()).map(\.key.rawValue))
        let extended: Set = ["gpu.percent", "gpu.memory", "cpu.efficiency", "cpu.performance", "temp.cpu.avg", "temp.cpu.max",
                             "temp.battery", "power.system", "power.cpu", "power.gpu", "fan.max", "disk.read", "disk.write", "load.1m"]
        #expect(keys.isDisjoint(with: extended))
    }

    @Test func partialExtendedFieldsOnlyWriteWhatExists() {
        // Intel-style core layout (no efficiency cores), no CPU power, no fans.
        let snapshot = SystemSnapshot(
            date: .now, cpuPercent: 10, memoryUsedBytes: gb, memoryTotalBytes: 8 * gb, memoryPressure: .normal,
            swapUsedBytes: 0, thermal: .nominal, disk: nil, isOnline: true, power: .unknown, processes: [],
            cpuCores: CPUCoreLoad(perCore: [20, 40], efficiencyCoreCount: 0, performanceCoreCount: 2),
            gpu: GPUStat(utilizationPercent: 0),
            thermals: ThermalSensors(cpuAverageCelsius: nil, cpuMaxCelsius: nil, batteryCelsius: 30, sensors: []),
            powerDraw: SystemPowerDraw(systemWatts: 9))
        let v = Dictionary(uniqueKeysWithValues: MetricSample.samples(from: snapshot).map { ($0.key.rawValue, $0.value) })
        #expect(v["cpu.efficiency"] == nil)
        #expect(v["cpu.performance"] == 30)
        #expect(v["gpu.percent"] == 0)          // a real measured 0 is kept
        #expect(v["gpu.memory"] == nil)
        #expect(v["temp.cpu.avg"] == nil && v["temp.battery"] == 30)
        #expect(v["power.system"] == 9 && v["power.cpu"] == nil)
        #expect(v["fan.max"] == nil)
    }
}

// MARK: Summary

@Suite struct HistorySummaryTests {
    let start = date(2026, 3, 10)
    var interval: DateInterval { DateInterval(start: start, duration: 86_400) }

    private func summary(cpu: [HistoryPoint], memory: [HistoryPoint] = [], pressure: [HistoryPoint] = [],
                         incidents: [Incident] = [], interval: DateInterval? = nil) -> HistorySummary {
        HistorySummary.make(interval: interval ?? self.interval, cpu: cpu, memory: memory, pressure: pressure,
                            incidents: incidents, topProcesses: .empty, now: start.addingTimeInterval(86_400))
    }

    @Test func weightedAverageAndPeak() {
        let s = summary(cpu: [point(start, avg: 10, min: 5, max: 20, count: 3),
                              point(start.addingTimeInterval(60), avg: 50, min: 40, max: 90, count: 1)])
        #expect(s.cpu == HistorySummary.Stat(avg: 20, peak: 90))
        #expect(s.memory == nil)
        #expect(s.pressureSeconds == nil)
        #expect(s.comparison == .noComparisonData)
    }

    @Test func pressureTimeIsShareTimesSpan() {
        let s = summary(cpu: [], pressure: [point(start, avg: 0.5, span: 900), point(start.addingTimeInterval(900), avg: 1, span: 900),
                                            point(start.addingTimeInterval(1800), avg: 0, span: 900)])
        #expect(s.pressureSeconds == 1350)
    }

    @Test func pressureTimeIsClippedToThePeriod() {
        // A quarter-hour bucket that starts 10 minutes before the day and one that ends 5 minutes after it:
        // only the parts inside count.
        let before = point(start.addingTimeInterval(-600), avg: 1, count: 90, span: 900)       // 300 s inside
        let inside = point(start.addingTimeInterval(900), avg: 0.5, count: 90, span: 900)      // 450 s
        let after = point(start.addingTimeInterval(86_400 - 300), avg: 1, count: 90, span: 900) // 300 s inside
        let s = summary(cpu: [], pressure: [before, inside, after])
        #expect(abs((s.pressureSeconds ?? -1) - 1050) < 1e-6)
        // A bucket entirely outside adds nothing, but the series still counts as measured.
        let outside = point(start.addingTimeInterval(-7200), avg: 1, count: 90, span: 900)
        #expect(summary(cpu: [], pressure: [outside]).pressureSeconds == 0)
    }

    @Test func pressureTimeCountsOnlyWhatWasMeasured() {
        // Usual: 6 samples per minute (10 s). One minute has only 3 samples (the Mac went to sleep): 30 s measured.
        let full = (0..<9).map { point(start.addingTimeInterval(Double($0) * 60), avg: 1, count: 6, span: 60) }
        let partial = point(start.addingTimeInterval(9 * 60), avg: 1, count: 3, span: 60)
        let s = summary(cpu: [], pressure: full + [partial])
        #expect(abs((s.pressureSeconds ?? -1) - 570) < 1e-6)
    }

    @Test func incidentsAreCountedPerRuleAndClippedToThePeriod() {
        let t = start
        let incidents = [
            Incident(key: "a", rule: "cpuHigh", severity: .warning, title: "", process: nil,
                     start: t.addingTimeInterval(-3600), end: t.addingTimeInterval(600)),         // 600 s inside
            Incident(key: "b", rule: "cpuHigh", severity: .warning, title: "", process: nil,
                     start: t.addingTimeInterval(1000), end: t.addingTimeInterval(1300)),         // 300 s
            Incident(key: "c", rule: "swap", severity: .critical, title: "", process: nil,
                     start: t.addingTimeInterval(86_000), end: nil),                              // open: until now
            Incident(key: "d", rule: "swap", severity: .critical, title: "", process: nil,
                     start: t.addingTimeInterval(-9000), end: t.addingTimeInterval(-8000)),       // outside
        ]
        let s = summary(cpu: [], incidents: incidents)
        #expect(s.incidentCount == 3)
        #expect(s.incidentSeconds == 600 + 300 + 400)
        #expect(s.incidentsByRule.map(\.rule) == ["cpuHigh", "swap"])
        #expect(s.incidentsByRule.map(\.count) == [2, 1])
        #expect(s.incidentsByRule.map(\.totalSeconds) == [900, 400])
    }

    @Test func comparisonUsesAbsoluteDifferences() {
        let previousInterval = DateInterval(start: start.addingTimeInterval(-86_400), duration: 86_400)
        let previous = summary(cpu: [point(start, avg: 0, max: 0)], memory: [point(start, avg: 40, max: 60)],
                               interval: previousInterval)
        let current = summary(cpu: [point(start, avg: 25, max: 80)], memory: [point(start, avg: 45, max: 55)],
                              incidents: [Incident(key: "a", rule: "cpuHigh", severity: .info, title: "", process: nil,
                                                   start: start, end: start.addingTimeInterval(100))])
        guard case .delta(let delta) = current.comparing(to: previous).comparison else {
            Issue.record("expected a delta")
            return
        }
        #expect(delta.cpuAvg == 25)         // previous average was 0: still fine, no division
        #expect(delta.cpuPeak == 80)
        #expect(delta.memoryAvg == 5)
        #expect(delta.memoryPeak == -5)
        #expect(delta.pressureSeconds == nil)
        #expect(delta.incidentCount == 1)
        #expect(delta.incidentSeconds == 100)
    }

    @Test func missingOrEmptyPreviousMeansNoComparisonData() {
        let current = summary(cpu: [point(start, avg: 25)])
        #expect(current.comparing(to: nil).comparison == .noComparisonData)
        let empty = summary(cpu: [], interval: DateInterval(start: start.addingTimeInterval(-86_400), duration: 86_400))
        #expect(current.comparing(to: empty).comparison == .noComparisonData)
    }

    @Test func storeReportComparesWithThePeriodBefore() async throws {
        try await withTempStore(now: start) { store, _ in
            await store.record(cpu(20) + [MetricSample(.memoryPercent, 50), MetricSample(.memoryUnderPressure, 0)],
                               at: start.addingTimeInterval(-3600))
            await store.record(cpu(60) + [MetricSample(.memoryPercent, 70), MetricSample(.memoryUnderPressure, 1)],
                               at: start.addingTimeInterval(3600))
            await store.recordProcesses([ProcessUsage(group: "Xcode", cpuPercent: 100, footprintBytes: gb)],
                                        at: start.addingTimeInterval(3600), interval: 10)
            let report = try await store.report(for: interval, now: start.addingTimeInterval(86_400))
            #expect(report.cpu == HistorySummary.Stat(avg: 60, peak: 60))
            #expect(report.pressureSeconds == 60)
            #expect(report.topProcesses.byCPU.map(\.group) == ["Xcode"])
            guard case .delta(let delta) = report.comparison else {
                Issue.record("expected a delta")
                return
            }
            #expect(delta.cpuAvg == 40)
            #expect(delta.memoryAvg == 20)
        }
    }
}

// MARK: Export

@Suite struct HistoryExportTests {
    let t = date(2026, 3, 10, 12, 0)

    @Test func csvHasFixedLayoutPointDecimalsAndUTCTimes() throws {
        let series: [MetricKey: [HistoryPoint]] = [
            .memoryPercent: [HistoryPoint(date: t, min: 1.5, avg: 2.25, max: 3, count: 4, resolution: .minute, span: 60)],
            .cpuTotal: [HistoryPoint(date: t, min: 0, avg: 12.3456789, max: 100, count: 6, resolution: .quarterHour, span: 900)],
        ]
        let events = [HistoryEvent(date: t.addingTimeInterval(30), key: "cpu.Xcode", rule: "cpuHigh", severity: .warning,
                                   kind: .fired, title: "CPU, hoch", body: "Sagt \"hallo\"", process: "=Evil")]
        let csv = String(decoding: HistoryExport.csv(series: series, events: events), as: UTF8.self)
        let expected = #"""
            record,time,key,resolution_s,min,avg,max,count,rule,severity,kind,title,body,process
            metric,2026-03-10T12:00:00Z,cpu.total,900,0,12.3457,100,6,,,,,,
            metric,2026-03-10T12:00:00Z,memory.percent,60,1.5,2.25,3,4,,,,,,
            event,2026-03-10T12:00:30Z,cpu.Xcode,,,,,,cpuHigh,1,fired,"CPU, hoch","Sagt ""hallo""",'=Evil

            """#
        #expect(csv == expected)
    }

    @Test func jsonContainsMetricsAndEvents() throws {
        let series: [MetricKey: [HistoryPoint]] = [
            .cpuTotal: [HistoryPoint(date: t, min: 1, avg: 2.5, max: 4, count: 3, resolution: .minute, span: 60)],
        ]
        let events = [event(t, .fired, process: "Xcode")]
        let data = try HistoryExport.json(from: t, to: t.addingTimeInterval(3600), series: series, events: events)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["from"] as? String == "2026-03-10T12:00:00Z")
        #expect(object["to"] as? String == "2026-03-10T13:00:00Z")
        let metrics = try #require(object["metrics"] as? [String: [[String: Any]]])
        #expect(metrics["cpu.total"]?.first?["avg"] as? Double == 2.5)
        #expect(metrics["cpu.total"]?.first?["time"] == nil)
        #expect(metrics["cpu.total"]?.first?["date"] as? String == "2026-03-10T12:00:00Z")
        let exported = try #require(object["events"] as? [[String: Any]])
        #expect(exported.first?["kind"] as? String == "fired")
        #expect(exported.first?["process"] as? String == "Xcode")
        // Stable output for identical input.
        #expect(data == (try HistoryExport.json(from: t, to: t.addingTimeInterval(3600), series: series, events: events)))
    }

    @Test func storeExportsAPeriod() async throws {
        try await withTempStore(now: t) { store, _ in
            await store.record(cpu(10), at: t)
            await store.record(AlertEvent(date: t, kind: .fired, condition: condition("a")))
            let csv = String(decoding: try await store.exportCSV(from: t, to: t.addingTimeInterval(3600)), as: UTF8.self)
            let lines = csv.split(separator: "\n")
            #expect(lines.count == 3)
            #expect(lines[1] == "metric,2026-03-10T12:00:00Z,cpu.total,60,10,10,10,1,,,,,,")
            #expect(lines[2].hasPrefix("event,2026-03-10T12:00:00Z,a,"))
            let json = try await store.exportJSON(from: t, to: t.addingTimeInterval(3600))
            #expect(!json.isEmpty)
        }
    }

    @Test func numberFormattingIgnoresLocale() {
        #expect(HistoryExport.number(1234567.5) == "1234567.5")
        #expect(HistoryExport.number(0.00001) == "0")
        #expect(HistoryExport.number(-0.00001) == "0")
        #expect(HistoryExport.number(.nan) == "")
    }
}

// MARK: Load probe

@Suite(.serialized) struct HistoryLoadTests {
    /// 30 days of operation, one snapshot every 10 s, in simulated time (no waiting).
    @Test func thirtyDaysOfOperation() async throws {
        let start = date(2026, 1, 1)
        let step: TimeInterval = 10
        let total = 30 * 86_400 / Int(step)
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(url: url, now: start)

        let names = (0..<150).map { "proc\($0)" }
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }

        let clock = ContinuousClock()
        var recordTime = Duration.zero
        var processTime = Duration.zero
        var compactTime = Duration.zero
        var compactMax = Duration.zero
        var compactions = 0

        for i in 0..<total {
            let t = start.addingTimeInterval(Double(i) * step)
            let samples = [
                MetricSample(.cpuTotal, random() * 100), MetricSample(.memoryUsed, random() * 16e9),
                MetricSample(.memoryPercent, random() * 100), MetricSample(.memoryPressure, random() < 0.05 ? 1 : 0),
                MetricSample(.memoryUnderPressure, random() < 0.05 ? 1 : 0), MetricSample(.swapUsed, random() * 4e9),
                MetricSample(.diskFree, 1e11 - Double(i)), MetricSample(.netDown, random() * 1e6),
                MetricSample(.netUp, random() * 1e5), MetricSample(.batteryPercent, 50 + random() * 50),
                MetricSample(.thermalLevel, 0),
            ]
            let usages = (0..<60).map { n in
                ProcessUsage(group: names[(i + n * 7) % names.count], cpuPercent: random() * 50,
                             footprintBytes: UInt64(random() * 2e9))
            }
            let a = clock.now
            await store.record(samples, at: t)
            let b = clock.now
            await store.recordProcesses(usages, at: t, interval: step)
            let c = clock.now
            recordTime += b - a
            processTime += c - b

            if i % 180 == 179 {   // every 30 simulated minutes
                let d = clock.now
                try await store.compact(now: t)
                let e = clock.now
                compactTime += e - d
                compactMax = max(compactMax, e - d)
                compactions += 1
            }
        }
        let end = start.addingTimeInterval(Double(total) * step)
        try await store.compact(now: end)
        try await store.flush()

        let q0 = clock.now
        let week = try await store.series(.cpuTotal, from: end.addingTimeInterval(-7 * 86_400), to: end, maxPoints: 1000)
        let q1 = clock.now
        let top = try await store.topProcesses(from: end.addingTimeInterval(-7 * 86_400), to: end)
        let q2 = clock.now

        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let meanRecord = ms(recordTime) / Double(total)
        let meanProcess = ms(processTime) / Double(total)
        let size = Double(store.fileSizeBytes()) / 1_048_576
        print("""
            HISTORY LOAD PROBE (30 days, \(total) snapshots)
              file size: \(String(format: "%.2f", size)) MB
              record: mean \(String(format: "%.4f", meanRecord)) ms
              recordProcesses (60 groups): mean \(String(format: "%.4f", meanProcess)) ms
              compact: \(compactions) runs, mean \(String(format: "%.2f", ms(compactTime) / Double(compactions))) ms, max \(String(format: "%.2f", ms(compactMax))) ms
              series 7 days: \(week.count) points (\(week.first?.resolution.rawValue ?? -1)) in \(String(format: "%.2f", ms(q1 - q0))) ms
              topProcesses 7 days: \(String(format: "%.2f", ms(q2 - q1))) ms
            """)

        // Shared CI runners are several times slower than a developer Mac; keep the order of magnitude.
        let slack = ProcessInfo.processInfo.environment["CI"] != nil ? 10.0 : 1.0
        #expect(size < 30)
        #expect(meanRecord < 0.1 * slack)
        #expect(ms(q1 - q0) < 20 * slack)
        #expect(week.count > 600)
        #expect(!top.byCPU.isEmpty)
        // Retention held: no minute buckets older than 48 h remain.
        #expect(try await store.bucketCount(.minute) <= 11 * 2 * 60 * 24 + 11 * 2)
    }
}

// MARK: Chart segments

@Suite struct HistorySegmentTests {
    private func point(_ minute: Int, span: TimeInterval = 60) -> HistoryPoint {
        HistoryPoint(date: Date(timeIntervalSince1970: Double(minute) * 60), min: 1, avg: 2, max: 3, count: 1,
                     resolution: .minute, span: span)
    }

    @Test func missingBucketsSplitTheSeries() {
        let segments = [point(0), point(1), point(2), point(10), point(11), point(40)].continuousSegments()
        #expect(segments.map(\.count) == [3, 2, 1])
    }

    @Test func contiguousSeriesStaysOneSegment() {
        #expect([point(0), point(1), point(2)].continuousSegments().count == 1)
        #expect([HistoryPoint]().continuousSegments().isEmpty)
    }

    @Test func unsortedInputIsOrderedFirst() {
        let segments = [point(2), point(0), point(1)].continuousSegments()
        #expect(segments.count == 1 && segments[0].map(\.date) == segments[0].map(\.date).sorted())
    }

    @Test func gapAfterAWholeBucketOfQuarterHours() {
        // 15-minute buckets: one missing bucket (30 min between starts) is a gap, adjacent ones are not.
        func q(_ i: Int) -> HistoryPoint {
            HistoryPoint(date: Date(timeIntervalSince1970: Double(i) * 900), min: 0, avg: 0, max: 0, count: 3,
                         resolution: .quarterHour, span: 900)
        }
        #expect([q(0), q(1), q(3)].continuousSegments().map(\.count) == [2, 1])
    }
}
