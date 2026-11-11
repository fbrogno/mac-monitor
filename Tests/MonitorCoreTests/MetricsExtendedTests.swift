import Foundation
import Testing
@testable import MonitorCore

@Suite struct SMCDecodeTests {
    @Test func floatIsLittleEndian() {
        // 1350.0 = 0x44A8C000
        #expect(SMCDecode.double(type: "flt", bytes: [0x00, 0xC0, 0xA8, 0x44]) == 1350)
        #expect(SMCDecode.double(type: "flt", bytes: [0x00, 0x00, 0xC0, 0x7F]) == nil) // NaN
        #expect(SMCDecode.double(type: "flt", bytes: [0, 0, 0]) == nil)
    }

    @Test func integersAreBigEndian() {
        #expect(SMCDecode.double(type: "ui8", bytes: [2]) == 2)
        #expect(SMCDecode.double(type: "ui16", bytes: [0x01, 0x02]) == 258)
        #expect(SMCDecode.double(type: "ui32", bytes: [0, 0, 0x0C, 0xE4]) == 3300)
        #expect(SMCDecode.double(type: "si8", bytes: [0xFF]) == -1)
        #expect(SMCDecode.double(type: "si16", bytes: [0xFF, 0xFE]) == -2)
        #expect(SMCDecode.double(type: "si32", bytes: [0xFF, 0xFF, 0xFF, 0xFE]) == -2)
        #expect(SMCDecode.double(type: "ui16", bytes: [1]) == nil)
    }

    @Test func fixedPoint() {
        // fpe2: unsigned 14.2 — 0x1AF8 = 6904 / 4 = 1726 rpm
        #expect(SMCDecode.double(type: "fpe2", bytes: [0x1A, 0xF8]) == 1726)
        // sp78: signed 7.8 — 0x1E80 = 30.5 °C, 0xFF00 = -1
        #expect(SMCDecode.double(type: "sp78", bytes: [0x1E, 0x80]) == 30.5)
        #expect(SMCDecode.double(type: "sp78", bytes: [0xFF, 0x00]) == -1)
        #expect(SMCDecode.double(type: "sp78", bytes: [0x1E]) == nil)
        #expect(SMCDecode.double(type: "hex_", bytes: [0]) == nil)
    }
}

@Suite struct CoreLoadTests {
    @Test func classMeans() {
        let load = CPUCoreLoad(perCore: [80, 60, 10, 20, 30], efficiencyCoreCount: 2, performanceCoreCount: 3)
        #expect(load.efficiencyPercent == 70)
        #expect(load.performancePercent == 20)
        #expect(Array(load.performanceCores) == [10, 20, 30])
    }

    @Test func intelHasNoEfficiencyClass() {
        let load = CPUCoreLoad(perCore: [10, 30], efficiencyCoreCount: 0, performanceCoreCount: 2)
        #expect(load.efficiencyPercent == nil)
        #expect(load.performancePercent == 20)
    }
}

@Suite struct ProcessRateTests {
    private func reading(pid: Int32 = 7, start: UInt64 = 1, cpu: UInt64, energy: UInt64 = 0,
                         read: UInt64 = 0, written: UInt64 = 0) -> ProcessReading {
        ProcessReading(pid: pid, startTime: start, cpuTimeNs: cpu, footprintBytes: 0,
                       energyNj: energy, diskReadBytes: read, diskWriteBytes: written, threads: 3)
    }

    @Test func energyAndDiskRates() {
        var tracker = ProcessCPUTracker()
        _ = tracker.updateRates([reading(cpu: 0)], nowNs: 1_000_000_000)
        // 2 s later: 1 s CPU, 3 J = 1.5 W, 20 MB read, 10 MB written
        let rates = tracker.updateRates([reading(cpu: 1_000_000_000, energy: 3_000_000_000,
                                                 read: 20_000_000, written: 10_000_000)], nowNs: 3_000_000_000)
        let rate = rates[7]
        #expect(rate?.cpuPercent == 50)
        #expect(rate?.energyMilliwatts == 1500)
        #expect(rate?.diskReadBytesPerSecond == 10_000_000)
        #expect(rate?.diskWriteBytesPerSecond == 5_000_000)
    }

    @Test func backwardsCountersAndReusedPidsYieldZeroOrNothing() {
        var tracker = ProcessCPUTracker()
        _ = tracker.updateRates([reading(cpu: 10, energy: 5_000, read: 100)], nowNs: 1_000_000_000)
        let lower = tracker.updateRates([reading(cpu: 20, energy: 1_000, read: 50)], nowNs: 2_000_000_000)
        #expect(lower[7]?.energyMilliwatts == 0)
        #expect(lower[7]?.diskReadBytesPerSecond == 0)
        let reused = tracker.updateRates([reading(start: 2, cpu: 20)], nowNs: 3_000_000_000)
        #expect(reused[7] == nil)
    }

    @Test func cpuUpdateStillMatchesRates() {
        var tracker = ProcessCPUTracker()
        _ = tracker.update([reading(cpu: 0)], nowNs: 1_000_000_000)
        #expect(tracker.update([reading(cpu: 500_000_000)], nowNs: 2_000_000_000)[7] == 50)
    }
}

@Suite struct EnergyDeltaTests {
    @Test func unitsConvertToJoules() {
        #expect(EnergyDelta.joulesPerUnit("mJ") == 1e-3)
        #expect(EnergyDelta.joulesPerUnit("uJ") == 1e-6)
        #expect(EnergyDelta.joulesPerUnit("nJ") == 1e-9)
        #expect(EnergyDelta.joulesPerUnit("J") == 1)
        #expect(EnergyDelta.joulesPerUnit("W") == nil)
    }

    @Test func onlyAggregateChannelsCount() {
        var energy = EnergyDelta()
        energy.add(channel: "CPU Energy", value: 492, unit: "mJ")
        energy.add(channel: "PACC0_CPU0", value: 999, unit: "mJ") // per core: would double-count
        energy.add(channel: "GPU Energy", value: 100_000_000, unit: "nJ")
        energy.add(channel: "GPU", value: 102, unit: "mJ")        // duplicate of GPU Energy
        energy.add(channel: "ANE", value: 50, unit: "mJ")
        energy.add(channel: "DRAM", value: 262, unit: "mJ")
        energy.add(channel: "DRAM", value: -5, unit: "mJ")        // invalid value is ignored
        energy.add(channel: "DIE_1_CPU Energy", value: 8, unit: "mJ")
        #expect(abs(energy.cpu - 0.5) < 1e-9)
        #expect(abs(energy.gpu - 0.1) < 1e-9)
        #expect(abs(energy.ane - 0.05) < 1e-9)
        #expect(abs(energy.dram - 0.262) < 1e-9)
    }

    @Test func wattsDivideByInterval() {
        var energy = EnergyDelta()
        energy.cpu = 10
        energy.gpu = 2
        let draw = energy.watts(over: 5)
        #expect(draw?.cpuWatts == 2)
        #expect(draw?.gpuWatts == 0.4)
        #expect(energy.watts(over: 0) == nil)
    }
}

@Suite struct ThermalSummaryTests {
    @Test func summarizesDieSensors() {
        let raw: [(name: String, celsius: Double)] = [
            ("PMU tdie1", 40), ("PMU tdie2", 50), ("PMU tdev1", -9201), ("PMU tcal", 51.8),
            ("NAND CH0 temp", 27), ("gas gauge battery", 26), ("broken", 400),
        ]
        let result = ThermalSampler.summarize(raw, batteryCelsius: nil)
        #expect(result.cpuAverageCelsius == 45)
        #expect(result.cpuMaxCelsius == 50)
        #expect(result.batteryCelsius == 26)
        #expect(result.sensors.map(\.name) == ["gas gauge battery", "NAND CH0 temp", "PMU tdie1", "PMU tdie2"])
    }

    @Test func batteryArgumentWinsAndDuplicatesAreAveraged() {
        let raw: [(name: String, celsius: Double)] = [("PMU tdie1", 40), ("PMU tdie1", 42), ("gas gauge battery", 26)]
        let result = ThermalSampler.summarize(raw, batteryCelsius: 30)
        #expect(result.batteryCelsius == 30)
        #expect(result.sensors.first { $0.name == "PMU tdie1" }?.celsius == 41)
    }

    @Test func noSensorsMeansNoStatistics() {
        let result = ThermalSampler.summarize([], batteryCelsius: nil)
        #expect(result.cpuAverageCelsius == nil)
        #expect(result.cpuMaxCelsius == nil)
        #expect(result.sensors.isEmpty)
    }
}

@Suite struct BatteryDetailTests {
    private let base: [String: Any] = [
        "BatteryInstalled": true, "DesignCapacity": 8579, "NominalChargeCapacity": 8622,
        "AppleRawMaxCapacity": 8378, "AppleRawCurrentCapacity": 7876, "Temperature": 3003,
        "Voltage": 13133, "InstantAmperage": 2276, "IsCharging": true, "AvgTimeToFull": 24,
        "PermanentFailureStatus": 0, "AdapterDetails": ["Watts": 96, "IsWireless": false] as [String: Any],
    ]

    @Test func parsesChargingBattery() throws {
        let detail = try #require(PowerSampler.parseBatteryDetail(base))
        #expect(detail.designCapacityMah == 8579)
        #expect(detail.maxCapacityMah == 8622)
        #expect(detail.currentCapacityMah == 7876)
        #expect(detail.temperatureCelsius == 30.03)
        #expect(detail.condition == .normal)
        #expect(detail.minutesToFull == 24)
        #expect(detail.adapterWatts == 96)
        #expect(abs((detail.chargeWatts ?? 0) - 29.89) < 0.01)
        #expect(detail.dischargeWatts == nil)
    }

    @Test func dischargingCurrentArrivesAsUnsignedWrap() throws {
        var p = base
        p["IsCharging"] = false
        p["AvgTimeToFull"] = 65_535
        p["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -1500))
        let detail = try #require(PowerSampler.parseBatteryDetail(p))
        #expect(detail.amperageMilliamps == -1500)
        #expect(detail.minutesToFull == nil)
        #expect(detail.chargeWatts == nil)
        #expect(abs((detail.dischargeWatts ?? 0) - 19.6995) < 0.001)
    }

    @Test func wornOrFailedBatteryNeedsService() throws {
        var worn = base
        worn["NominalChargeCapacity"] = 6000
        #expect(try #require(PowerSampler.parseBatteryDetail(worn)).condition == .serviceRecommended)
        var failed = base
        failed["PermanentFailureStatus"] = 1
        #expect(try #require(PowerSampler.parseBatteryDetail(failed)).condition == .serviceRecommended)
    }

    @Test func missingCapacityMeansNoBattery() {
        #expect(PowerSampler.parseBatteryDetail([:]) == nil)
        #expect(PowerSampler.parseBatteryDetail(["BatteryInstalled": false, "DesignCapacity": 1000]) == nil)
    }
}

@Suite struct DeviceParserTests {
    @Test func gpuStatistics() throws {
        let stats: [String: Any] = ["Device Utilization %": 24, "In use system memory": 1_292_189_696,
                                    "Alloc system memory": 4_382_949_376]
        let gpu = try #require(GPUSampler.parse(stats))
        #expect(gpu.utilizationPercent == 24)
        #expect(gpu.memoryUsedBytes == 1_292_189_696)
        #expect(gpu.memoryAllocatedBytes == 4_382_949_376)
        #expect(GPUSampler.parse(["Tiler Utilization %": 3]) == nil)
        #expect(GPUSampler.parse(["Device Utilization %": 140])?.utilizationPercent == 100)
    }

    @Test func nvmeSmartPage() throws {
        var page = [UInt8](repeating: 0, count: 512)
        page[0] = 0                       // no critical warning
        page[1] = 0x2D; page[2] = 0x01    // 301 K
        page[3] = 100; page[4] = 99; page[5] = 7
        page[48] = 0x01; page[49] = 0x02  // 513 units written
        page[128] = 0x04; page[129] = 0x03 // 772 hours
        let health = try #require(SSDHealthSampler.parse(page))
        #expect(health.isVerified)
        #expect(health.percentageUsed == 7)
        #expect(health.availableSparePercent == 100)
        #expect(abs((health.temperatureCelsius ?? 0) - 27.85) < 0.001)
        #expect(health.bytesWritten == 513 * 512_000)
        #expect(health.powerOnHours == 772)
        page[0] = 0x04
        #expect(SSDHealthSampler.parse(page)?.isVerified == false)
        #expect(SSDHealthSampler.parse([0, 1]) == nil)
    }

    @Test func diskThroughput() {
        let old = DiskCounters(read: 1_000, written: 2_000, time: 10)
        let new = DiskCounters(read: 5_000, written: 2_500, time: 12)
        #expect(DiskCounters.throughput(from: old, to: new) == DiskThroughput(readBytesPerSecond: 2_000, writeBytesPerSecond: 250))
        #expect(DiskCounters.throughput(from: new, to: old) == nil)
    }

    @Test func interfaceRatesSkipResetsAndSortBusiestFirst() {
        let old = ["en0": NetworkCounters(received: 0, sent: 0, time: 0), "utun4": NetworkCounters(received: 100, sent: 0, time: 0),
                   "en1": NetworkCounters(received: 500, sent: 0, time: 0)]
        let new = ["en0": NetworkCounters(received: 1_000, sent: 200, time: 1), "utun4": NetworkCounters(received: 5_000, sent: 0, time: 1),
                   "en1": NetworkCounters(received: 10, sent: 0, time: 1), "bridge0": NetworkCounters(received: 0, sent: 0, time: 1)]
        let rates = NetworkSampler.rates(from: old, to: new)
        #expect(rates.map(\.name) == ["utun4", "en0"])
        #expect(rates.first?.rate.downBytesPerSecond == 4_900)
    }
}

@Suite struct AppGroupingTests {
    private func id(_ pid: Int32, parent: Int32 = 1, responsible: Int32? = nil, _ name: String, _ path: String? = nil)
        -> ProcessIdentity {
        ProcessIdentity(pid: pid, parentPid: parent, responsiblePid: responsible, name: name, path: path)
    }

    @Test func bundleRootIsOutermostApp() {
        #expect(AppGrouping.bundleRoot(of: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(AppGrouping.bundleRoot(of: "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
                == "/Applications/Google Chrome.app")
        #expect(AppGrouping.bundleRoot(of: "/usr/bin/ssh") == nil)
        #expect(AppGrouping.bundleRoot(of: "/opt/.app/tool") == nil)
        #expect(AppGrouping.bundleRoot(of: nil) == nil)
        #expect(AppGrouping.bundleName("/Applications/Google Chrome.app") == "Google Chrome")
    }

    @Test func helpersJoinTheirAppByBundle() {
        let groups = AppGrouping.assign([
            id(10, "Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            id(11, parent: 10, "Google Chrome Helper", "/Applications/Google Chrome.app/Contents/Frameworks/X/Helper.app/Contents/MacOS/Helper"),
            id(20, "Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail"),
        ])
        #expect(groups[10] == groups[11])
        #expect(groups[10]?.name == "Google Chrome")
        #expect(groups[10]?.key == "app:/Applications/Google Chrome.app")
        #expect(groups[20]?.name == "Mail")
        #expect(groups[10] != groups[20])
    }

    @Test func responsibleProcessWinsOverPath() {
        // A system XPC service (no bundle) works on behalf of Safari.
        let groups = AppGrouping.assign([
            id(30, "Safari", "/Applications/Safari.app/Contents/MacOS/Safari"),
            id(31, responsible: 30, "com.apple.WebKit.WebContent", "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent.xpc/Contents/MacOS/WebContent"),
            id(32, responsible: 31, "nested", "/usr/libexec/nested"),
        ])
        #expect(groups[31]?.key == "app:/Applications/Safari.app")
        #expect(groups[32]?.key == "app:/Applications/Safari.app")
    }

    @Test func ancestorBundleIsTheFallback() {
        let groups = AppGrouping.assign([
            id(40, "Xcode", "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            id(41, parent: 40, "build", "/usr/bin/build"),
            id(42, parent: 41, "child", "/usr/bin/child"),
        ])
        #expect(groups[41]?.name == "Xcode")
        #expect(groups[42]?.name == "Xcode")
    }

    @Test func standaloneAndCyclesAreSafe() {
        let groups = AppGrouping.assign([
            id(50, "launchd-job", "/usr/sbin/job"),
            id(60, parent: 61, responsible: 61, "a", "/usr/bin/a"),
            id(61, parent: 60, responsible: 60, "b", "/usr/bin/b"),
            id(70, responsible: 99, "orphan", "/usr/bin/orphan"), // responsible process is gone
        ])
        #expect(groups[50] == AppGrouping.Group(key: "proc:50", name: "launchd-job"))
        #expect(groups[60] != nil && groups[61] != nil)
        #expect(groups[70]?.key == "proc:70")
    }

    @Test func aggregateSumsPerAppAndSorts() {
        let chrome = AppGrouping.Group(key: "app:/Applications/Chrome.app", name: "Chrome")
        let processes = [
            ProcessStat(pid: 1, name: "helper", cpuPercent: 10, footprintBytes: 100, energyMilliwatts: 50, threads: 4,
                        diskReadBytesPerSecond: 10, diskWriteBytesPerSecond: 1, appKey: chrome.key, appName: chrome.name),
            ProcessStat(pid: 2, name: "Chrome", cpuPercent: 5, footprintBytes: 200, energyMilliwatts: 25, threads: 6,
                        diskReadBytesPerSecond: 20, diskWriteBytesPerSecond: 2, appKey: chrome.key, appName: chrome.name),
            ProcessStat(pid: 3, name: "tool", cpuPercent: 40, footprintBytes: 50),
        ]
        let apps = AppGrouping.aggregate(processes)
        #expect(apps.map(\.name) == ["tool", "Chrome"])
        let sum = apps[1]
        #expect(sum.pids == [1, 2])
        #expect(sum.cpuPercent == 15)
        #expect(sum.footprintBytes == 300)
        #expect(sum.energyMilliwatts == 75)
        #expect(sum.threads == 10)
        #expect(sum.diskReadBytesPerSecond == 30)
    }
}

@Suite struct SnapshotExtensionTests {
    @Test func newFieldsDefaultToEmptyAndSurviveRemoving() {
        let plain = SystemSnapshot(date: .now, cpuPercent: 1, memoryUsedBytes: 1, memoryTotalBytes: 2,
                                   memoryPressure: .normal, swapUsedBytes: 0, thermal: .nominal, disk: nil,
                                   isOnline: true, power: .unknown, processes: [])
        #expect(plain.cpuCores == nil && plain.gpu == nil && plain.thermals == nil && plain.fans.isEmpty)
        #expect(plain.volumes.isEmpty && plain.runtime == nil && plain.ssdHealth == nil)

        let rich = SystemSnapshot(date: .now, cpuPercent: 1, memoryUsedBytes: 1, memoryTotalBytes: 2,
                                  memoryPressure: .normal, swapUsedBytes: 0, thermal: .nominal, disk: nil,
                                  isOnline: true, power: .unknown,
                                  processes: [ProcessStat(pid: 9, name: "x", cpuPercent: 1, footprintBytes: 1)],
                                  gpu: GPUStat(utilizationPercent: 12),
                                  fans: [FanStat(index: 0, rpm: 2000, minRpm: 1000, maxRpm: 4000)],
                                  runtime: RuntimeStat(uptimeSeconds: 10, loadAverage: nil, processCount: 1, threadCount: 1))
        let trimmed = rich.removing(pid: 9)
        #expect(trimmed.processes.isEmpty)
        #expect(trimmed.gpu?.utilizationPercent == 12)
        #expect(trimmed.fans.first?.fraction == 0.5)
        #expect(trimmed.runtime?.processCount == 1)
    }

    @Test func fanFractionIsClamped() {
        #expect(FanStat(index: 0, rpm: 9000, minRpm: 0, maxRpm: 4500).fraction == 1)
        #expect(FanStat(index: 0, rpm: 100, minRpm: 0, maxRpm: 0).fraction == 0)
    }
}

@Suite struct ExtendedLiveTests {
    /// Sensors differ per Mac and CI runs on virtual machines, so a missing value (nil / empty) is fine;
    /// a value that is present must be plausible.
    @Test func liveExtendedSamplersReturnPlausibleValues() async throws {
        let cores = CPUCoreSampler()
        _ = cores.sample()
        try await Task.sleep(for: .milliseconds(200))
        if let load = cores.sample() {
            #expect(!load.perCore.isEmpty)
            #expect(load.perCore.allSatisfy { (0...100).contains($0) })
            #expect(load.efficiencyCoreCount + load.performanceCoreCount == load.perCore.count)
        }

        if let gpu = GPUSampler.sample() {
            #expect((0...100).contains(gpu.utilizationPercent))
        }

        let smc = SMCSampler()
        for fan in smc.fans() {
            #expect(fan.rpm >= 0 && fan.rpm < 20_000)
            #expect(fan.maxRpm >= fan.minRpm)
        }
        let board = smc.boardPower()
        if let system = board.system { #expect(system > 0 && system < 500) }

        if let thermals = ThermalSampler(smc: smc).sample() {
            if let average = thermals.cpuAverageCelsius, let max = thermals.cpuMaxCelsius {
                #expect(average > 0 && average < 150)
                #expect(max >= average)
            }
            #expect(thermals.sensors.allSatisfy { $0.celsius > 0 && $0.celsius < 150 })
        }

        if let energy = EnergySampler() {
            try await Task.sleep(for: .milliseconds(600))
            if let draw = energy.sample() {
                #expect((draw.cpuWatts ?? 0) >= 0 && (draw.cpuWatts ?? 0) < 500)
            }
        }

        if let battery = PowerSampler.batteryDetail() {
            #expect(battery.designCapacityMah > 0 && battery.maxCapacityMah > 0)
            if let t = battery.temperatureCelsius { #expect(t > -20 && t < 100) }
        }

        for volume in VolumeSampler.sample() {
            #expect(volume.totalBytes > 0 && volume.availableBytes <= volume.totalBytes)
        }
        if let health = SSDHealthSampler.sample() {
            #expect(health.percentageUsed >= 0 && health.availableSparePercent <= 100)
        }

        let disk = DiskIOSampler()
        _ = disk.sample()
        try await Task.sleep(for: .milliseconds(100))
        if let rate = disk.sample() { #expect(rate.readBytesPerSecond >= 0 && rate.writeBytesPerSecond >= 0) }

        let net = NetworkSampler()
        _ = net.sample()
        try await Task.sleep(for: .milliseconds(100))
        _ = net.sample()
        #expect(net.interfaceRates.allSatisfy { $0.rate.downBytesPerSecond >= 0 })
        if let active = ActiveInterfaceSampler().sample() { #expect(!active.name.isEmpty) }

        let uptime = try #require(RuntimeSampler.uptimeSeconds())
        #expect(uptime > 0)
        if let load = RuntimeSampler.loadAverage() { #expect(load.one >= 0) }
    }

    @Test func processSamplerReportsThreadsAndGroups() {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let me = sampler.sample().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect((me?.threads ?? 0) >= 1)
        #expect(!(me?.appKey.isEmpty ?? true))
        #expect(sampler.systemProcessCount >= sampler.sample().count)
    }
}
