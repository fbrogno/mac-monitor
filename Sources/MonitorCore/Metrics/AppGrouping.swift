import Foundation

/// Static facts about one process that decide which app it belongs to.
public struct ProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32
    /// The process the system holds accountable for this one (`responsibility_get_pid_responsible_for_pid`);
    /// nil when unknown.
    public let responsiblePid: Int32?
    public let name: String
    public let path: String?
    /// Outermost app bundle of `path`, worked out once because grouping runs on every sample.
    public let bundle: String?

    public init(pid: Int32, parentPid: Int32, responsiblePid: Int32? = nil, name: String, path: String? = nil) {
        self.pid = pid
        self.parentPid = parentPid
        self.responsiblePid = responsiblePid
        self.name = name
        self.path = path
        self.bundle = AppGrouping.bundleRoot(of: path)
    }
}

/// One app with all its helper processes, summed up.
public struct AppUsage: Sendable, Equatable, Identifiable {
    public let key: String
    public let name: String
    public let pids: [Int32]
    public let cpuPercent: Double
    public let footprintBytes: UInt64
    public let energyMilliwatts: Double
    public let threads: Int
    public let diskReadBytesPerSecond: Double
    public let diskWriteBytesPerSecond: Double

    public var id: String { key }
}

/// Groups helper processes with their app. Pure: it only looks at the identities it is given.
public enum AppGrouping {
    public struct Group: Sendable, Equatable {
        /// Stable key: `app:<bundle path>` for bundles, `proc:<pid>` for everything else.
        public let key: String
        public let name: String
    }

    /// The outermost `*.app` directory in a path, e.g. the Safari bundle for a WebKit helper nested inside it.
    public static func bundleRoot(of path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + parts[...index].joined(separator: "/")
    }

    /// Display name of a bundle: its folder name without ".app".
    public static func bundleName(_ bundle: String) -> String {
        let last = (bundle as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Assigns every process to a group. Order of evidence: the responsible process (followed
    /// transitively), then the app bundle in the executable path, then the nearest ancestor that
    /// lives in a bundle; otherwise the process stands alone.
    public static func assign(_ processes: [ProcessIdentity]) -> [Int32: Group] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var ancestorBundles: [Int32: String?] = [:]
        var groups: [String: Group] = [:]

        func leader(of process: ProcessIdentity) -> ProcessIdentity {
            var current = process
            var seen: Set<Int32> = [process.pid]
            while let next = current.responsiblePid, next > 1, let candidate = byPid[next], seen.insert(next).inserted {
                current = candidate
            }
            return current
        }

        /// The process's own bundle, else the nearest ancestor's (memoized per process).
        func bundle(of process: ProcessIdentity) -> String? {
            if let own = process.bundle { return own }
            if let known = ancestorBundles[process.pid] { return known }
            var found: String?
            var current = process
            var seen: Set<Int32> = [process.pid]
            while current.parentPid > 1, let parent = byPid[current.parentPid], seen.insert(parent.pid).inserted {
                if let own = parent.bundle { found = own; break }
                current = parent
            }
            ancestorBundles[process.pid] = .some(found)
            return found
        }

        var result: [Int32: Group] = [:]
        result.reserveCapacity(processes.count)
        for process in processes {
            let head = leader(of: process)
            if let root = bundle(of: head) ?? bundle(of: process) {
                let group = groups[root] ?? Group(key: "app:\(root)", name: bundleName(root))
                groups[root] = group
                result[process.pid] = group
            } else {
                result[process.pid] = Group(key: "proc:\(head.pid)", name: head.name)
            }
        }
        return result
    }

    /// Sums processes per app, busiest first (CPU, then energy).
    public static func aggregate(_ processes: [ProcessStat]) -> [AppUsage] {
        var order: [String] = []
        var buckets: [String: [ProcessStat]] = [:]
        for process in processes {
            let key = process.appKey.isEmpty ? "proc:\(process.pid)" : process.appKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(process)
        }
        return order.map { key in
            let members = buckets[key] ?? []
            return AppUsage(
                key: key,
                name: members.first.map { $0.appName.isEmpty ? $0.name : $0.appName } ?? key,
                pids: members.map(\.pid),
                cpuPercent: members.reduce(0) { $0 + $1.cpuPercent },
                footprintBytes: members.reduce(0) { $0 + $1.footprintBytes },
                energyMilliwatts: members.reduce(0) { $0 + $1.energyMilliwatts },
                threads: members.reduce(0) { $0 + $1.threads },
                diskReadBytesPerSecond: members.reduce(0) { $0 + $1.diskReadBytesPerSecond },
                diskWriteBytesPerSecond: members.reduce(0) { $0 + $1.diskWriteBytesPerSecond })
        }
        .sorted { ($0.cpuPercent, $0.energyMilliwatts) > ($1.cpuPercent, $1.energyMilliwatts) }
    }
}
