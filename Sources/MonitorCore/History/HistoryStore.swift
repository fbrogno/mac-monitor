import Foundation

/// Persistent history in one SQLite file (WAL): metric buckets in three tiers, the alert log and
/// per-15-minute process rankings. All times come in as parameters; nothing here reads the clock.
///
/// Writes are buffered: `record` only accumulates in memory and touches the disk when a minute
/// has completed, in one transaction. Call `flush()` before quitting or sleeping.
public actor HistoryStore {
    public static let schemaVersion = 1
    /// Number of processes kept per 15-minute bucket, separately by CPU time and by memory.
    public static let processesPerBucket = 10

    public nonisolated let path: String
    public nonisolated let retention: RetentionPolicy
    /// Where the previous file went when it was damaged or incompatible (at open or later).
    public private(set) var replacedFile: URL?
    /// Number of write transactions for buffered data so far (for diagnostics and tests).
    public private(set) var writeCount = 0
    /// Message of the last failed background write; nil after a successful one.
    public private(set) var lastWriteError: String?

    private var db: SQLiteDatabase
    private let calendar: Calendar
    private var lastNow: Date

    private struct Bucket {
        var min: Double, max: Double, sum: Double, n: Int
        init(_ v: Double) { min = v; max = v; sum = v; n = 1 }
        init(min: Double, max: Double, sum: Double, n: Int) { self.min = min; self.max = max; self.sum = sum; self.n = n }
        mutating func add(_ v: Double) { min = Swift.min(min, v); max = Swift.max(max, v); sum += v; n += 1 }
        mutating func merge(_ o: Bucket) { min = Swift.min(min, o.min); max = Swift.max(max, o.max); sum += o.sum; n += o.n }
    }
    private struct ProcessAcc { var cpuSeconds: Double; var peak: UInt64 }

    private var pendingMetrics: [MetricKey: [Int64: Bucket]] = [:]
    private var oldestPendingMinute: Int64?
    private var pendingProcesses: [Int64: [String: ProcessAcc]] = [:]

    // MARK: Open

    /// Opens or creates the database. `path` may be `":memory:"`. A damaged or incompatible file
    /// is renamed to `<path>.corrupt-<date>` and replaced by a fresh one.
    public init(path: String, retention: RetentionPolicy = .standard,
                timeZone: TimeZone = .current, now: Date) throws {
        self.path = path
        self.retention = retention
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.lastNow = now
        if path != ":memory:" {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let opened = try Self.open(path: path, now: now)
        self.db = opened.database
        self.replacedFile = opened.backup
    }

    public init(url: URL, retention: RetentionPolicy = .standard,
                timeZone: TimeZone = .current, now: Date) throws {
        try self.init(path: url.path, retention: retention, timeZone: timeZone, now: now)
    }

    private static func open(path: String, now: Date) throws -> (database: SQLiteDatabase, backup: URL?) {
        do {
            return (try prepared(path: path), nil)
        } catch let error as SQLiteError where error.needsReplacement && path != ":memory:" {
            let backup = try quarantine(path: path, now: now)
            return (try prepared(path: path), backup)
        }
    }

    private static func prepared(path: String) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: path)
        var tables = 0
        try db.prepare("SELECT COUNT(*) FROM sqlite_master").forEachRow { tables = Int($0.int(0)) }
        var version = 0
        try db.prepare("PRAGMA user_version").forEachRow { version = Int($0.int(0)) }
        if version == 0 && tables > 0 { throw SQLiteError.incompatibleSchema(version: 0) }
        if version != 0 && version != schemaVersion { throw SQLiteError.incompatibleSchema(version: version) }
        if path != ":memory:" { try db.exec("PRAGMA journal_mode=WAL") }
        try db.exec("PRAGMA synchronous=NORMAL")
        if version == 0 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE metric(
                        key TEXT NOT NULL, res INTEGER NOT NULL, ts INTEGER NOT NULL,
                        vmin REAL NOT NULL, vmax REAL NOT NULL, vsum REAL NOT NULL, n INTEGER NOT NULL,
                        PRIMARY KEY(key, res, ts)) WITHOUT ROWID;
                    CREATE INDEX metric_res_ts ON metric(res, ts);
                    CREATE TABLE event(
                        id INTEGER PRIMARY KEY, ts REAL NOT NULL, key TEXT NOT NULL, rule TEXT NOT NULL,
                        severity INTEGER NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                        body TEXT NOT NULL, process TEXT);
                    CREATE INDEX event_ts ON event(ts);
                    CREATE TABLE process(
                        ts INTEGER NOT NULL, grp TEXT NOT NULL, cpu REAL NOT NULL, mem INTEGER NOT NULL,
                        PRIMARY KEY(ts, grp)) WITHOUT ROWID;
                    CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID;
                    PRAGMA user_version = \(schemaVersion);
                    """)
            }
        }
        return db
    }

    private static func quarantine(path: String, now: Date) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        var target = URL(fileURLWithPath: path + ".corrupt-" + stamp)
        var counter = 1
        while fm.fileExists(atPath: target.path) {
            counter += 1
            target = URL(fileURLWithPath: path + ".corrupt-" + stamp + "-\(counter)")
        }
        try fm.moveItem(at: URL(fileURLWithPath: path), to: target)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.moveItem(at: URL(fileURLWithPath: path + suffix), to: URL(fileURLWithPath: target.path + suffix))
        }
        return target
    }

    /// Runs `body`; if the file turns out to be damaged, replaces it once and retries.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SQLiteError where error.needsReplacement && path != ":memory:" {
            db = try SQLiteDatabase(path: ":memory:")
            let opened = try Self.open(path: path, now: lastNow)
            db = opened.database
            replacedFile = opened.backup
            return try body()
        }
    }

    // MARK: Recording

    /// Adds raw samples taken at `date`. Touches the disk only when a minute has completed.
    public func record(_ samples: [MetricSample], at date: Date) {
        lastNow = date
        let minute = Self.floorTo(date, 60)
        for sample in samples where sample.value.isFinite {
            if pendingMetrics[sample.key, default: [:]][minute] != nil {
                pendingMetrics[sample.key]![minute]!.add(sample.value)
            } else {
                pendingMetrics[sample.key, default: [:]][minute] = Bucket(sample.value)
            }
        }
        if !samples.isEmpty { oldestPendingMinute = Swift.min(oldestPendingMinute ?? minute, minute) }
        if let oldest = oldestPendingMinute, oldest < minute { writeBackground(metricsBefore: minute) }
    }

    /// Adds one sample's process groups. `interval` is how many seconds the sample stands for
    /// (CPU time = percent / 100 × interval). Written when a 15-minute bucket has completed.
    public func recordProcesses(_ usages: [ProcessUsage], at date: Date, interval: TimeInterval) {
        lastNow = date
        let bucket = Self.floorTo(date, 900)
        for usage in usages where usage.cpuPercent.isFinite {
            let seconds = Swift.max(0, usage.cpuPercent) / 100 * interval
            if var acc = pendingProcesses[bucket]?[usage.group] {
                acc.cpuSeconds += seconds
                acc.peak = Swift.max(acc.peak, usage.footprintBytes)
                pendingProcesses[bucket]![usage.group] = acc
            } else {
                pendingProcesses[bucket, default: [:]][usage.group] = ProcessAcc(cpuSeconds: seconds, peak: usage.footprintBytes)
            }
        }
        if pendingProcesses.keys.contains(where: { $0 < bucket }) { writeBackground(processesBefore: bucket) }
    }

    /// Persists an alert event right away (events are rare).
    public func record(_ event: AlertEvent) { record(events: [event]) }

    public func record(events: [AlertEvent]) {
        guard !events.isEmpty else { return }
        do {
            try guarded { try insert(events.map(HistoryEvent.init)) }
            lastWriteError = nil
        } catch {
            lastWriteError = "\(error)"
        }
    }

    /// Writes everything buffered, including the running minute. Call on quit and before sleep.
    public func flush() throws {
        try guarded { try writeMetrics(before: nil); try writeProcesses(before: nil) }
    }

    /// Flushes and truncates the write-ahead log; the store stays usable.
    public func close() throws {
        try flush()
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func writeBackground(metricsBefore limit: Int64) {
        do {
            try guarded { try writeMetrics(before: limit) }
            lastWriteError = nil
        } catch {
            lastWriteError = "\(error)"
            // Keep memory bounded when the disk keeps failing: drop buckets older than 6 hours.
            let floor = limit - 6 * 3600
            for key in pendingMetrics.keys { pendingMetrics[key] = pendingMetrics[key]?.filter { $0.key >= floor } }
            oldestPendingMinute = pendingMetrics.values.flatMap(\.keys).min()
        }
    }

    private func writeBackground(processesBefore limit: Int64) {
        do {
            try guarded { try writeProcesses(before: limit) }
            lastWriteError = nil
        } catch {
            lastWriteError = "\(error)"
            pendingProcesses = pendingProcesses.filter { $0.key >= limit - 6 * 3600 }
        }
    }

    private func writeMetrics(before limit: Int64?) throws {
        var rows: [(MetricKey, Int64, Bucket)] = []
        for (key, buckets) in pendingMetrics {
            for (minute, bucket) in buckets where limit.map({ minute < $0 }) ?? true { rows.append((key, minute, bucket)) }
        }
        guard !rows.isEmpty else { return }
        try db.transaction {
            let upsert = try db.prepare(Self.upsertSQL)
            for (key, minute, b) in rows {
                try upsert.run([.text(key.rawValue), .int(Int64(Resolution.minute.rawValue)), .int(minute),
                                .double(b.min), .double(b.max), .double(b.sum), .int(Int64(b.n))])
            }
        }
        writeCount += 1
        for (key, minute, _) in rows {
            pendingMetrics[key]?[minute] = nil
            if pendingMetrics[key]?.isEmpty == true { pendingMetrics[key] = nil }
        }
        oldestPendingMinute = pendingMetrics.values.flatMap(\.keys).min()
    }

    private static let upsertSQL = """
        INSERT INTO metric(key, res, ts, vmin, vmax, vsum, n) VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key, res, ts) DO UPDATE SET
            vmin = MIN(vmin, excluded.vmin), vmax = MAX(vmax, excluded.vmax),
            vsum = vsum + excluded.vsum, n = n + excluded.n
        """

    private func writeProcesses(before limit: Int64?) throws {
        let ready = pendingProcesses.filter { entry in limit.map { entry.key < $0 } ?? true }
        guard !ready.isEmpty else { return }
        try db.transaction {
            let upsert = try db.prepare("""
                INSERT INTO process(ts, grp, cpu, mem) VALUES(?, ?, ?, ?)
                ON CONFLICT(ts, grp) DO UPDATE SET cpu = cpu + excluded.cpu, mem = MAX(mem, excluded.mem)
                """)
            for (bucket, groups) in ready {
                let byCPU = groups.sorted { ($0.value.cpuSeconds, $1.key) > ($1.value.cpuSeconds, $0.key) }
                let byMem = groups.sorted { ($0.value.peak, $1.key) > ($1.value.peak, $0.key) }
                var keep = Set(byCPU.prefix(Self.processesPerBucket).map(\.key))
                keep.formUnion(byMem.prefix(Self.processesPerBucket).map(\.key))
                for group in keep.sorted() {
                    let acc = groups[group]!
                    try upsert.run([.int(bucket), .text(group), .double(acc.cpuSeconds), .int(Int64(acc.peak))])
                }
            }
        }
        writeCount += 1
        for bucket in ready.keys { pendingProcesses[bucket] = nil }
    }

    private func insert(_ events: [HistoryEvent]) throws {
        try db.transaction {
            let statement = try db.prepare("""
                INSERT INTO event(ts, key, rule, severity, kind, title, body, process) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for e in events {
                try statement.run([.double(e.date.timeIntervalSince1970), .text(e.key), .text(e.rule),
                                   .int(Int64(e.severity.rawValue)), .text(e.kind.rawValue), .text(e.title),
                                   .text(e.body), e.process.map { .text($0) } ?? .null])
            }
        }
    }

    // MARK: Compaction

    /// Rolls minute buckets up into 15-minute and day buckets and deletes what is past retention.
    /// Cheap (touches only buckets since the last run); once every few minutes is enough.
    /// A bucket is dropped once it lies entirely before its tier's cutoff.
    public func compact(now: Date) throws {
        lastNow = now
        try guarded {
            try writeMetrics(before: nil)
            try writeProcesses(before: nil)
            try compactTiers(now: now)
        }
    }

    private func compactTiers(now: Date) throws {
        let nowS = Int64(now.timeIntervalSince1970.rounded(.down))
        let cutMinute = nowS - Int64(retention.minute)
        let cutQuarter = nowS - Int64(retention.quarterHour)
        let cutDay = nowS - Int64(retention.day)
        let last = try metaValue("lastCompact").flatMap { Int64($0) }.map { Swift.min($0, nowS) }
        let minute = Int64(Resolution.minute.rawValue), quarter = Int64(Resolution.quarterHour.rawValue)
        let dayRes = Int64(Resolution.day.rawValue)

        try db.transaction {
            // Minute -> 15 minutes. Windows that are still complete are recomputed (idempotent);
            // windows already cut into by retention are only filled when missing.
            let cutAligned = Self.ceilTo(cutMinute, 900)
            let lo = last.map { Self.floorTo($0, 900) - 900 } ?? 0
            let rollup = { (verb: String, condition: String, args: [SQLValue]) throws in
                try self.db.prepare("""
                    INSERT OR \(verb) INTO metric(key, res, ts, vmin, vmax, vsum, n)
                    SELECT key, \(quarter), (ts / 900) * 900, MIN(vmin), MAX(vmax), SUM(vsum), SUM(n)
                    FROM metric WHERE res = \(minute) AND \(condition) GROUP BY key, (ts / 900) * 900
                    """).run(args)
            }
            try rollup("REPLACE", "ts >= ?", [.int(Swift.max(lo, cutAligned))])
            if lo < cutAligned { try rollup("IGNORE", "ts >= ? AND ts < ?", [.int(lo), .int(cutAligned)]) }

            // 15 minutes -> day (local time zone, grouped in Swift because of daylight saving).
            let loDay = last.map { Int64(calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1,
                                to: Date(timeIntervalSince1970: TimeInterval($0))) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) } ?? 0
            try rollDays(from: loDay, cutQuarter: cutQuarter)

            try db.prepare("DELETE FROM metric WHERE res = \(minute) AND ts <= ?").run([.int(cutMinute - 60)])
            try db.prepare("DELETE FROM metric WHERE res = \(quarter) AND ts <= ?").run([.int(cutQuarter - 900)])
            try db.prepare("DELETE FROM metric WHERE res = \(dayRes) AND ts <= ?").run([.int(cutDay - 86400)])
            try db.prepare("DELETE FROM event WHERE ts < ?").run([.double(TimeInterval(nowS) - retention.events)])
            try db.prepare("DELETE FROM process WHERE ts <= ?").run([.int(nowS - Int64(retention.processes) - 900)])
            try db.prepare("INSERT OR REPLACE INTO meta(k, v) VALUES('lastCompact', ?)").run([.text(String(nowS))])
        }
    }

    /// 15 minutes -> day in the local time zone (grouped in Swift because of daylight saving).
    /// Days whose 15-minute rows are all still retained are recomputed; older ones only filled.
    private func rollDays(from loDay: Int64, cutQuarter: Int64) throws {
        var days: [String: [Int64: Bucket]] = [:]
        try db.prepare("SELECT key, ts, vmin, vmax, vsum, n FROM metric WHERE res = \(Resolution.quarterHour.rawValue) AND ts >= ?")
            .forEachRow([.int(loDay)]) { row in
                let ts = Date(timeIntervalSince1970: TimeInterval(row.int(1)))
                let day = Int64(calendar.startOfDay(for: ts).timeIntervalSince1970)
                let part = Bucket(min: row.double(2), max: row.double(3), sum: row.double(4), n: Int(row.int(5)))
                if days[row.text(0), default: [:]][day] != nil {
                    days[row.text(0)]![day]!.merge(part)
                } else {
                    days[row.text(0), default: [:]][day] = part
                }
            }
        guard !days.isEmpty else { return }
        let replace = try db.prepare("INSERT OR REPLACE INTO metric(key, res, ts, vmin, vmax, vsum, n) VALUES(?, ?, ?, ?, ?, ?, ?)")
        let ignore = try db.prepare("INSERT OR IGNORE INTO metric(key, res, ts, vmin, vmax, vsum, n) VALUES(?, ?, ?, ?, ?, ?, ?)")
        for (key, perDay) in days {
            for (day, b) in perDay {
                let statement = day >= cutQuarter ? replace : ignore
                try statement.run([.text(key), .int(Int64(Resolution.day.rawValue)), .int(day),
                                   .double(b.min), .double(b.max), .double(b.sum), .int(Int64(b.n))])
            }
        }
    }

    private func metaValue(_ key: String) throws -> String? {
        var value: String?
        try db.prepare("SELECT v FROM meta WHERE k = ?").forEachRow([.text(key)]) { value = $0.text(0) }
        return value
    }

    // MARK: Queries

    /// Buckets of one metric in `[from, to)`. The tier is chosen from the range and `maxPoints`
    /// (the finest tier with at most `maxPoints` buckets). Where that tier no longer reaches back
    /// to `from`, older parts come from coarser tiers. Gaps (Mac off, asleep) stay gaps.
    /// Buffered data of the minute tier is included.
    public func series(_ key: MetricKey, from: Date, to: Date, maxPoints: Int) throws -> [HistoryPoint] {
        guard to > from else { return [] }
        var tier = Resolution.choose(range: to.timeIntervalSince(from), maxPoints: maxPoints)
        var upper = to
        var boundary = Date.distantFuture   // start of the finer tier's data
        var result: [HistoryPoint] = []
        while true {
            var part = try points(key, tier: tier, from: from, to: upper)
            // Coarser tiers only fill what lies entirely before the finer tier's data.
            part.removeAll { $0.date.addingTimeInterval($0.span) > boundary }
            result = part + result
            guard tier != .day, let coarser = Resolution(rawValue: tier.rawValue + 1) else { break }
            let covered = try oldest(key, tier: tier) ?? upper
            if covered <= from { break }
            upper = Swift.min(upper, covered)
            boundary = covered
            tier = coarser
        }
        return result
    }

    private func oldest(_ key: MetricKey, tier: Resolution) throws -> Date? {
        var ts: Int64?
        try db.prepare("SELECT MIN(ts) FROM metric WHERE key = ? AND res = ?")
            .forEachRow([.text(key.rawValue), .int(Int64(tier.rawValue))]) { row in
                if row.optionalText(0) != nil { ts = row.int(0) }
            }
        var date = ts.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if tier == .minute, let pending = pendingMetrics[key]?.keys.min() {
            let p = Date(timeIntervalSince1970: TimeInterval(pending))
            date = date.map { Swift.min($0, p) } ?? p
        }
        return date
    }

    private func points(_ key: MetricKey, tier: Resolution, from: Date, to: Date) throws -> [HistoryPoint] {
        let lower: Int64
        switch tier {
        case .minute: lower = Self.floorTo(from, 60)
        case .quarterHour: lower = Self.floorTo(from, 900)
        case .day: lower = Int64(calendar.startOfDay(for: from).timeIntervalSince1970)
        }
        let upper = Int64(Swift.max(0, to.timeIntervalSince1970).rounded(.up))
        var buckets: [Int64: Bucket] = [:]
        try db.prepare("SELECT ts, vmin, vmax, vsum, n FROM metric WHERE key = ? AND res = ? AND ts >= ? AND ts < ?")
            .forEachRow([.text(key.rawValue), .int(Int64(tier.rawValue)), .int(lower), .int(upper)]) { row in
                buckets[row.int(0)] = Bucket(min: row.double(1), max: row.double(2), sum: row.double(3), n: Int(row.int(4)))
            }
        if tier == .minute, let pending = pendingMetrics[key] {
            for (minute, bucket) in pending where minute >= lower && minute < upper {
                buckets[minute, default: bucket] = buckets[minute].map { var m = $0; m.merge(bucket); return m } ?? bucket
            }
        }
        return buckets.keys.sorted().compactMap { ts in
            let b = buckets[ts]!
            guard b.n > 0 else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let span: TimeInterval
            if tier == .day, let next = calendar.date(byAdding: .day, value: 1, to: date) {
                span = next.timeIntervalSince(date)
            } else {
                span = tier.nominalSeconds
            }
            return HistoryPoint(date: date, min: b.min, avg: b.sum / Double(b.n), max: b.max, count: b.n,
                                resolution: tier, span: span)
        }
    }

    /// Metric keys that have data (including buffered data).
    public func metricKeys() throws -> [MetricKey] {
        var keys = Set(pendingMetrics.keys)
        try db.prepare("SELECT DISTINCT key FROM metric").forEachRow { keys.insert(MetricKey($0.text(0))) }
        return keys.sorted()
    }

    /// Stored events in `[from, to)`, oldest first, optionally for one rule.
    public func events(from: Date, to: Date, rule: RuleID? = nil) throws -> [HistoryEvent] {
        var sql = "SELECT ts, key, rule, severity, kind, title, body, process FROM event WHERE ts >= ? AND ts < ?"
        var args: [SQLValue] = [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]
        if let rule {
            sql += " AND rule = ?"
            args.append(.text(rule.rawValue))
        }
        sql += " ORDER BY ts, id"
        var out: [HistoryEvent] = []
        try db.prepare(sql).forEachRow(args) { row in
            out.append(HistoryEvent(
                date: Date(timeIntervalSince1970: row.double(0)), key: row.text(1), rule: row.text(2),
                severity: Severity(rawValue: Int(row.int(3))) ?? .info,
                kind: EventKind(rawValue: row.text(4)) ?? .fired,
                title: row.text(5), body: row.text(6), process: row.optionalText(7)))
        }
        return out
    }

    /// Incidents that overlap `[from, to)`, oldest first. Open incidents have `end == nil`.
    public func incidents(from: Date, to: Date, rule: RuleID? = nil) throws -> [Incident] {
        // All stored events: an incident that started before `from` or ends after `to` needs both ends.
        let all = try events(from: Date(timeIntervalSince1970: 0), to: .distantFuture)
        return Incident.build(from: all).filter { incident in
            (rule == nil || incident.rule == rule!.rawValue) && incident.start < to && (incident.end ?? .distantFuture) > from
        }
    }

    /// Biggest consumers in `[from, to)`: summed CPU time and highest footprint per group.
    /// Only groups that were in the top 10 of a 15-minute bucket are counted, so totals of
    /// small consumers are understated. Buffered data of the running bucket is included.
    public func topProcesses(from: Date, to: Date, limit: Int = 10) throws -> TopProcesses {
        let lower = Self.floorTo(from, 900)
        let upper = Int64(to.timeIntervalSince1970.rounded(.up))
        var totals: [String: ProcessAcc] = [:]
        try db.prepare("SELECT grp, SUM(cpu), MAX(mem) FROM process WHERE ts >= ? AND ts < ? GROUP BY grp")
            .forEachRow([.int(lower), .int(upper)]) { row in
                totals[row.text(0)] = ProcessAcc(cpuSeconds: row.double(1), peak: UInt64(Swift.max(0, row.int(2))))
            }
        for (bucket, groups) in pendingProcesses where bucket >= lower && bucket < upper {
            for (group, acc) in groups {
                var t = totals[group] ?? ProcessAcc(cpuSeconds: 0, peak: 0)
                t.cpuSeconds += acc.cpuSeconds
                t.peak = Swift.max(t.peak, acc.peak)
                totals[group] = t
            }
        }
        let all = totals.map { ProcessConsumer(group: $0.key, cpuSeconds: $0.value.cpuSeconds, peakFootprintBytes: $0.value.peak) }
        let cpu = all.filter { $0.cpuSeconds > 0 }
            .sorted { ($0.cpuSeconds, $1.group) > ($1.cpuSeconds, $0.group) }
        let mem = all.sorted { ($0.peakFootprintBytes, $1.group) > ($1.peakFootprintBytes, $0.group) }
        return TopProcesses(byCPU: Array(cpu.prefix(limit)), byMemory: Array(mem.prefix(limit)))
    }

    // MARK: Housekeeping

    /// Size of the database including its write-ahead log, in bytes. 0 for `:memory:`.
    public nonisolated func fileSizeBytes() -> Int64 {
        guard path != ":memory:" else { return 0 }
        return ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size]) as? NSNumber
            total += size?.int64Value ?? 0
        }
    }

    /// Removes all stored and buffered data (metrics, events, processes) and shrinks the file.
    public func deleteAll() throws {
        pendingMetrics = [:]
        pendingProcesses = [:]
        oldestPendingMinute = nil
        try guarded {
            try db.transaction {
                for table in ["metric", "event", "process", "meta"] { try db.exec("DELETE FROM \(table)") }
            }
            if path != ":memory:" { try db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
            try db.exec("VACUUM")
        }
    }

    // MARK: Helpers

    /// Number of stored buckets in one tier (diagnostics and tests; excludes buffered data).
    func bucketCount(_ tier: Resolution) throws -> Int {
        var count = 0
        try db.prepare("SELECT COUNT(*) FROM metric WHERE res = ?").forEachRow([.int(Int64(tier.rawValue))]) { count = Int($0.int(0)) }
        return count
    }

    private static func floorTo(_ date: Date, _ width: Int64) -> Int64 {
        floorTo(Int64(date.timeIntervalSince1970.rounded(.down)), width)
    }

    private static func floorTo(_ t: Int64, _ width: Int64) -> Int64 {
        t - ((t % width) + width) % width
    }

    private static func ceilTo(_ t: Int64, _ width: Int64) -> Int64 {
        let f = floorTo(t, width)
        return f == t ? t : f + width
    }
}
