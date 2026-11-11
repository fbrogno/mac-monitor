import Darwin
import Foundation
import SystemConfiguration

public struct NetworkRate: Sendable, Equatable {
    public let downBytesPerSecond: Double
    public let upBytesPerSecond: Double

    public init(downBytesPerSecond: Double, upBytesPerSecond: Double) {
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
    }
}

/// Cumulative byte counters at one moment.
public struct NetworkCounters: Sendable, Equatable {
    public let received: UInt64
    public let sent: UInt64
    public let time: TimeInterval

    public init(received: UInt64, sent: UInt64, time: TimeInterval) {
        self.received = received
        self.sent = sent
        self.time = time
    }

    /// Throughput between two readings. Counter resets (interface replugged) yield nil.
    public static func rate(from old: NetworkCounters, to new: NetworkCounters) -> NetworkRate? {
        let elapsed = new.time - old.time
        guard elapsed > 0, new.received >= old.received, new.sent >= old.sent else { return nil }
        return NetworkRate(downBytesPerSecond: Double(new.received - old.received) / elapsed,
                           upBytesPerSecond: Double(new.sent - old.sent) / elapsed)
    }
}

/// Reads 64-bit interface counters via `NET_RT_IFLIST2`. The headline rate counts only physical `en*`
/// interfaces (Wi-Fi, Ethernet, USB/dock adapters); tunnels such as `utun` would double-count VPN
/// traffic. `interfaceRates` lists the other interfaces separately.
public final class NetworkSampler {
    private var last: (total: NetworkCounters, perInterface: [String: NetworkCounters])?
    /// Per-interface throughput from the latest `sample()`, busiest first.
    public private(set) var interfaceRates: [InterfaceRate] = []

    public init() {}

    public func reset() {
        last = nil
        interfaceRates = []
    }

    public func sample() -> NetworkRate? {
        guard let now = Self.readInterfaces() else { return nil }
        defer { last = now }
        guard let last else { return nil }
        interfaceRates = Self.rates(from: last.perInterface, to: now.perInterface)
        return Self.headlineRate(from: last.perInterface, to: now.perInterface)
    }

    /// The headline rate: deltas of the physical `en*` interfaces that appear in both readings. An interface
    /// that is new (its counters have run for hours) or that was reset would otherwise show up as a huge jump.
    /// Nil when there were `en*` interfaces but none in both readings; zero when there are none at all.
    static func headlineRate(from old: [String: NetworkCounters], to new: [String: NetworkCounters]) -> NetworkRate? {
        let physical = rates(from: old, to: new).filter { $0.name.hasPrefix("en") }
        if physical.isEmpty {
            let anyPhysical = old.keys.contains { $0.hasPrefix("en") } || new.keys.contains { $0.hasPrefix("en") }
            let time = new.values.first?.time ?? 0
            let elapsed = time - (old.values.first?.time ?? time)
            return anyPhysical || elapsed <= 0 ? nil : NetworkRate(downBytesPerSecond: 0, upBytesPerSecond: 0)
        }
        return NetworkRate(downBytesPerSecond: physical.reduce(0) { $0 + $1.rate.downBytesPerSecond },
                           upBytesPerSecond: physical.reduce(0) { $0 + $1.rate.upBytesPerSecond })
    }

    /// Rates for interfaces present in both readings, busiest first; resets yield no entry.
    static func rates(from old: [String: NetworkCounters], to new: [String: NetworkCounters]) -> [InterfaceRate] {
        new.compactMap { name, counters in
            guard let before = old[name], let rate = NetworkCounters.rate(from: before, to: counters) else { return nil }
            return InterfaceRate(name: name, rate: rate)
        }
        .sorted {
            let a = $0.rate.downBytesPerSecond + $0.rate.upBytesPerSecond
            let b = $1.rate.downBytesPerSecond + $1.rate.upBytesPerSecond
            return a != b ? a > b : $0.name < $1.name
        }
    }

    static func readCounters() -> NetworkCounters? { readInterfaces()?.total }

    /// Interfaces worth showing next to the headline rate.
    private static func isShown(_ name: String) -> Bool {
        ["en", "utun", "bridge", "ppp", "ipsec"].contains { name.hasPrefix($0) }
    }

    static func readInterfaces() -> (total: NetworkCounters, perInterface: [String: NetworkCounters])? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        let time = ProcessInfo.processInfo.systemUptime
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var perInterface: [String: NetworkCounters] = [:]
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") {
                            received &+= info.ifm_data.ifi_ibytes
                            sent &+= info.ifm_data.ifi_obytes
                        }
                        if isShown(name) {
                            perInterface[name] = NetworkCounters(received: info.ifm_data.ifi_ibytes,
                                                                 sent: info.ifm_data.ifi_obytes, time: time)
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (NetworkCounters(received: received, sent: sent, time: time), perInterface)
    }
}

/// Finds the interface that carries the default route, its type and its IPv4 address — through
/// SystemConfiguration and `getifaddrs`, which need no permission (no SSID or location is read).
public final class ActiveInterfaceSampler {
    private let store = SCDynamicStoreCreate(nil, "MacMonitor" as CFString, nil, nil)
    private var kinds: [String: InterfaceKind]?

    public init() {}

    public func sample() -> ActiveInterface? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String else { return nil }
        return ActiveInterface(name: name, kind: kind(of: name), ipv4: Self.ipv4(of: name))
    }

    private func kind(of name: String) -> InterfaceKind {
        if kinds == nil {
            var map: [String: InterfaceKind] = [:]
            for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
                guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                      let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
                if type == kSCNetworkInterfaceTypeIEEE80211 { map[bsd] = .wifi }
                else if type == kSCNetworkInterfaceTypeEthernet { map[bsd] = .ethernet }
            }
            kinds = map
        }
        return kinds?[name] ?? .other
    }

    static func ipv4(of name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
