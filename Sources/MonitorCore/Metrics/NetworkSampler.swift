import Darwin
import Foundation

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

/// Reads 64-bit interface counters via `NET_RT_IFLIST2`. Only physical `en*` interfaces count
/// (Wi-Fi, Ethernet, USB/dock adapters); tunnels such as `utun` would double-count VPN traffic.
public final class NetworkSampler {
    private var last: NetworkCounters?

    public init() {}

    public func reset() { last = nil }

    public func sample() -> NetworkRate? {
        guard let counters = Self.readCounters() else { return nil }
        defer { last = counters }
        guard let last else { return nil }
        return NetworkCounters.rate(from: last, to: counters)
    }

    static func readCounters() -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil,
                       String(cString: nameBuffer).hasPrefix("en") {
                        received &+= info.ifm_data.ifi_ibytes
                        sent &+= info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return NetworkCounters(received: received, sent: sent, time: ProcessInfo.processInfo.systemUptime)
    }
}
