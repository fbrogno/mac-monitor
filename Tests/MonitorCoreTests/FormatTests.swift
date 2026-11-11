import Testing
@testable import MonitorCore

@Suite struct DetailFormatTests {
    @Test func powerTemperatureAndFans() {
        #expect(Format.watts(12.34) == "12,3 W")
        #expect(Format.watts(140) == "140 W")
        #expect(Format.milliwatts(850) == "850 mW")
        #expect(Format.milliwatts(2500) == "2,5 W")
        #expect(Format.celsius(47.6) == "48 °C")
        #expect(Format.rpm(1499.6) == "1500 rpm")
    }

    @Test func terabytesFromOneTiB() {
        #expect(Format.bytes(994 * 1_073_741_824) == "994 GB")
        #expect(Format.bytes(2 * 1_099_511_627_776 + 109_951_162_778) == "2,1 TB")
    }

    @Test func batteryCapacityAndUptime() {
        #expect(Format.milliampHours(4520) == "4.520 mAh")
        #expect(Format.milliampHours(950) == "950 mAh")
        #expect(Format.milliampHours(1_234_567) == "1.234.567 mAh")
        #expect(Format.uptime(30 * 60) == "30 min")
        #expect(Format.uptime(5 * 3600 + 12 * 60) == "5 h 12 min")
        #expect(Format.uptime(86_400 + 3 * 3600) == "1 Tag 3 h")
        #expect(Format.uptime(3 * 86_400 + 4 * 3600) == "3 Tage 4 h")
    }
}
