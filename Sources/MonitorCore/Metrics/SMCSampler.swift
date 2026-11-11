import Foundation
import IOKit

/// Converts raw SMC bytes to numbers. SMC integers and fixed-point values are big-endian;
/// `flt` is a little-endian IEEE float on every Mac (the SMC shares the host's byte order).
public enum SMCDecode {
    public static func double(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "ui8": return bytes.count == 1 ? Double(bytes[0]) : nil
        case "si8": return bytes.count == 1 ? Double(Int8(bitPattern: bytes[0])) : nil
        case "ui16": return bytes.count == 2 ? Double(big(bytes)) : nil
        case "si16": return bytes.count == 2 ? Double(Int16(truncatingIfNeeded: big(bytes))) : nil
        case "ui32": return bytes.count == 4 ? Double(big(bytes)) : nil
        case "si32": return bytes.count == 4 ? Double(Int32(truncatingIfNeeded: big(bytes))) : nil
        default:
            // Fixed point: "fp" = unsigned, "sp" = signed; the last digit is the number of fraction bits
            // (fpe2 = 14.2 unsigned, sp78 = 7.8 signed).
            guard type.count == 4, bytes.count == 2,
                  type.hasPrefix("fp") || type.hasPrefix("sp"),
                  let fractionBits = Int(String(type.last!), radix: 16) else { return nil }
            let raw = big(bytes)
            let value = type.hasPrefix("sp") ? Double(Int16(truncatingIfNeeded: raw)) : Double(raw)
            return value / Double(1 << fractionBits)
        }
    }

    private static func big(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Read-only connection to the `AppleSMC` user client. Opening needs no root. Every read returns
/// nil when the key does not exist on this Mac.
final class SMCConnection {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    // Layout of the kernel's 80-byte `SMCKeyData_t`.
    private enum Offset {
        static let key = 0, keySize = 28, keyType = 32, result = 40, command = 42, index = 44, bytes = 48
    }
    private static let structSize = 80
    private static let handleEvent: UInt32 = 2
    private static let readBytes: UInt8 = 5, readKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    /// Value of a key as a number, or nil if missing or of an unknown type.
    func double(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        return SMCDecode.double(type: type, bytes: bytes)
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        let code = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        guard let info = keyInfo(code) else { return nil }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: code, toByteOffset: Offset.key, as: UInt32.self)
            $0.storeBytes(of: info.size, toByteOffset: Offset.keySize, as: UInt32.self)
            $0.storeBytes(of: Self.readBytes, toByteOffset: Offset.command, as: UInt8.self)
        }
        guard let output = call(input), info.size <= 32 else { return nil }
        return (Self.text(info.type), Array(output[Offset.bytes..<(Offset.bytes + Int(info.size))]))
    }

    private func keyInfo(_ code: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[code] { return cached }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: code, toByteOffset: Offset.key, as: UInt32.self)
            $0.storeBytes(of: Self.readKeyInfo, toByteOffset: Offset.command, as: UInt8.self)
        }
        guard let output = call(input) else { return nil }
        let info = output.withUnsafeBytes {
            (size: $0.load(fromByteOffset: Offset.keySize, as: UInt32.self),
             type: $0.load(fromByteOffset: Offset.keyType, as: UInt32.self))
        }
        infoCache[code] = info
        return info
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = IOConnectCallStructMethod(connection, Self.handleEvent, &input, Self.structSize,
                                               &output, &outputSize)
        return result == KERN_SUCCESS && output[Offset.result] == 0 ? output : nil
    }

    private static func text(_ code: UInt32) -> String {
        // Type codes are space padded ("ui8 ", "flt ").
        String(decoding: [UInt8(code >> 24), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)],
               as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Fans and board power from the SMC. Create once and reuse; the connection stays open.
public final class SMCSampler {
    private let smc: SMCConnection?

    public init() { smc = SMCConnection() }

    public var isAvailable: Bool { smc != nil }

    /// One entry per fan; empty on fanless Macs or when the SMC is unreachable.
    public func fans() -> [FanStat] {
        guard let smc, let count = smc.double("FNum"), count >= 1 else { return [] }
        return (0..<min(Int(count), 8)).compactMap { index in
            guard let rpm = smc.double("F\(index)Ac"), rpm >= 0, rpm < 20_000 else { return nil }
            return FanStat(index: index, rpm: rpm, minRpm: smc.double("F\(index)Mn") ?? 0,
                           maxRpm: smc.double("F\(index)Mx") ?? 0)
        }
    }

    /// `PSTR` (system total) and `PDTR` (adapter input) in watts, nil where absent or implausible.
    public func boardPower() -> (system: Double?, adapterInput: Double?) {
        guard let smc else { return (nil, nil) }
        func watts(_ key: String) -> Double? {
            guard let value = smc.double(key), value >= 0, value < 500 else { return nil }
            return value
        }
        return (watts("PSTR"), watts("PDTR"))
    }

    /// CPU temperature on Macs without HID thermal sensors (Intel): first plausible of the
    /// classic CPU keys.
    public func legacyCPUTemperature() -> Double? {
        guard let smc else { return nil }
        for key in ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H"] {
            if let value = smc.double(key), value > 0, value < 150 { return value }
        }
        return nil
    }
}
