import MonitorCore
import SwiftUI

/// System power with its split, and everything about the battery.
struct EnergyPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            powerCard
            batteryCard
        }
    }

    private var powerCard: some View {
        let d = data
        let power = model.snapshot?.powerDraw
        return DashCard(String(localized: "Systemleistung"), trailing: {
            if let watts = power?.systemWatts {
                Text(Format.watts(watts)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }, content: {
            if power == nil && !d.hasSeries(.powerSystem, .powerCPU) {
                UnavailableNote()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HistoryChart(lines: powerLines, unit: .watts, from: d.from, to: d.to, domain: nil, height: 180,
                                 showsLegend: true)
                    if let power { split(power) }
                }
            }
        })
    }

    private var powerLines: [ChartLine] {
        let d = data
        var l = [ChartLine]()
        if d.hasSeries(.powerSystem) { l.append(d.line(.powerSystem, String(localized: "System"), Palette.accent)) }
        if d.hasSeries(.powerCPU) { l.append(d.line(.powerCPU, "CPU", Palette.warn, band: false)) }
        if d.hasSeries(.powerGPU) { l.append(d.line(.powerGPU, "GPU", Palette.ok, band: false)) }
        return l
    }

    @ViewBuilder private func split(_ power: SystemPowerDraw) -> some View {
        let parts: [(String, Double?, Color)] = [
            ("CPU", power.cpuWatts, Palette.warn), ("GPU", power.gpuWatts, Palette.ok),
            (String(localized: "Neural Engine"), power.aneWatts, Palette.accent),
            (String(localized: "Arbeitsspeicher"), power.dramWatts, Color.purple),
        ]
        let shown = parts.compactMap { part in part.1.map { (part.0, $0, part.2) } }
        if !shown.isEmpty {
            let top = max(shown.map(\.1).max() ?? 1, 0.1)
            VStack(alignment: .leading, spacing: 7) {
                Text("Aufteilung im letzten Messintervall").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(shown, id: \.0) { name, watts, tint in
                    MeterBar(label: name, value: Format.watts(watts), fraction: watts / top, tint: tint)
                }
                if let adapter = power.adapterInputWatts {
                    FactRow(String(localized: "Aufnahme am Netzteil"), Format.watts(adapter))
                }
            }
        }
    }

    // MARK: Battery

    @ViewBuilder private var batteryCard: some View {
        let s = model.snapshot
        if s?.power.batteryPercent == nil && s?.batteryDetail == nil && !data.hasSeries(.batteryPercent) {
            DashCard(String(localized: "Akku")) { UnavailableNote(text: String(localized: "Dieser Mac hat keinen Akku")) }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                DashCard(String(localized: "Ladestand"), trailing: {
                    if let percent = s?.power.batteryPercent {
                        Text("\(percent) %").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }, content: {
                    HistoryChart(lines: [data.line(.batteryPercent, String(localized: "Akku"), Palette.ok)], unit: .percent,
                                 from: data.from, to: data.to, domain: 0...100, height: 150)
                })
                if let s { batteryFacts(s) }
            }
        }
    }

    private func batteryFacts(_ s: SystemSnapshot) -> some View {
        let detail = s.batteryDetail
        let health = s.power.health
        return DashCard(String(localized: "Akkuzustand")) {
            VStack(spacing: 7) {
                if let detail {
                    let percent = detail.designCapacityMah > 0 ? Int((Double(detail.maxCapacityMah) / Double(detail.designCapacityMah) * 100).rounded()) : 0
                    FactRow(String(localized: "Kapazität"),
                            String(localized: "\(Format.milliampHours(detail.maxCapacityMah)) von \(Format.milliampHours(detail.designCapacityMah)) (\(percent) %)"))
                    if let current = detail.currentCapacityMah {
                        FactRow(String(localized: "Aktuell geladen"), Format.milliampHours(current))
                    }
                } else if let health {
                    FactRow(String(localized: "Kapazität"), String(localized: "\(health.capacityPercent) % der ursprünglichen"))
                }
                if let health { FactRow(String(localized: "Ladezyklen"), "\(health.cycleCount)") }
                if let detail {
                    FactRow(String(localized: "Zustand"), detail.condition.rawValue,
                            tint: detail.condition == .normal ? Palette.ok : Palette.warn)
                    if let temperature = detail.temperatureCelsius { FactRow(String(localized: "Temperatur"), Format.celsius(temperature)) }
                    if let adapter = detail.adapterWatts, !s.power.onBattery { FactRow(String(localized: "Netzteil"), "\(adapter) W") }
                    if let charge = detail.chargeWatts { FactRow(String(localized: "Ladeleistung"), Format.watts(charge)) }
                    if let discharge = detail.dischargeWatts { FactRow(String(localized: "Entladeleistung"), Format.watts(discharge)) }
                    if !s.power.onBattery, let toFull = detail.minutesToFull {
                        FactRow(String(localized: "Bis voll"), Format.hoursMinutes(toFull))
                    }
                }
                if s.power.onBattery, let remaining = s.power.minutesRemaining {
                    FactRow(String(localized: "Bis leer"), Format.hoursMinutes(remaining))
                }
            }
        }
    }
}

/// Temperatures, fans and SSD health.
struct SensorsPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            temperatureCard
            fanCard
            ssdCard
        }
    }

    private var temperatureCard: some View {
        let d = data
        let thermals = model.snapshot?.thermals
        return DashCard(String(localized: "Temperaturen"), trailing: {
            if let avg = thermals?.cpuAverageCelsius {
                Text(Format.celsius(avg)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }, content: {
            if thermals == nil && !d.hasSeries(.cpuTempAvg) {
                UnavailableNote()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HistoryChart(lines: tempLines, unit: .celsius, from: d.from, to: d.to, domain: nil, height: 170,
                                 showsLegend: true)
                    if let thermals, !thermals.sensors.isEmpty { sensorList(thermals.sensors) }
                }
            }
        })
    }

    private var tempLines: [ChartLine] {
        let d = data
        var l = [d.line(.cpuTempAvg, String(localized: "CPU Mittel"), Palette.warn)]
        if d.hasSeries(.cpuTempMax) { l.append(d.line(.cpuTempMax, String(localized: "CPU Spitze"), Palette.critical, band: false)) }
        if d.hasSeries(.batteryTemp) { l.append(d.line(.batteryTemp, String(localized: "Akku"), Palette.ok, band: false)) }
        return l
    }

    private func sensorList(_ sensors: [TemperatureReading]) -> some View {
        let sorted = sensors.sorted { $0.celsius > $1.celsius }
        let shown = Array(sorted.prefix(12))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Einzelne Sensoren, heißeste zuerst").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 5) {
                ForEach(shown, id: \.name) { reading in
                    FactRow(reading.name, Format.celsius(reading.celsius),
                            tint: reading.celsius >= 90 ? Palette.critical : reading.celsius >= 75 ? Palette.warn : .primary)
                }
            }
            if sorted.count > shown.count {
                Text("und \(sorted.count - shown.count) weitere").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var fanCard: some View {
        let fans = model.snapshot?.fans ?? []
        return DashCard(String(localized: "Lüfter")) {
            if fans.isEmpty && !data.hasSeries(.fanMax) {
                UnavailableNote(text: String(localized: "Keine Lüfter gemeldet (lüfterlose Macs haben keine)"))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(fans, id: \.index) { fan in FanBar(fan: fan) }
                    if data.hasSeries(.fanMax) {
                        HistoryChart(lines: [data.line(.fanMax, String(localized: "Schnellster Lüfter"), Palette.accent)], unit: .rpm,
                                     from: data.from, to: data.to, domain: nil, height: 110)
                    }
                }
            }
        }
    }

    private var ssdCard: some View {
        DashCard(String(localized: "SSD-Zustand"), subtitle: "SMART") {
            if let ssd = model.snapshot?.ssdHealth {
                VStack(spacing: 7) {
                    FactRow(String(localized: "Zustand"), ssd.isVerified ? String(localized: "In Ordnung") : String(localized: "Warnung"),
                            tint: ssd.isVerified ? Palette.ok : Palette.critical)
                    MeterBar(label: String(localized: "Verschleiß"), value: "\(ssd.percentageUsed) %",
                             fraction: Double(ssd.percentageUsed) / 100,
                             tint: ssd.percentageUsed >= 80 ? Palette.critical : ssd.percentageUsed >= 50 ? Palette.warn : Palette.ok)
                    MeterBar(label: String(localized: "Reserve"), value: "\(ssd.availableSparePercent) %",
                             fraction: Double(ssd.availableSparePercent) / 100,
                             tint: ssd.availableSparePercent <= 10 ? Palette.critical : Palette.ok)
                    if let hours = ssd.powerOnHours {
                        FactRow(String(localized: "Betriebsstunden"), String(localized: "\(hours) h (\(Format.uptime(Double(hours) * 3600)))"))
                    }
                    if let written = ssd.bytesWritten { FactRow(String(localized: "Insgesamt geschrieben"), Format.bytes(written)) }
                    if let temperature = ssd.temperatureCelsius { FactRow(String(localized: "Temperatur"), Format.celsius(temperature)) }
                }
            } else {
                UnavailableNote()
            }
        }
    }
}

/// Fan speed as a bar up to the maximum, with a tick at the minimum.
struct FanBar: View {
    let fan: FanStat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Lüfter \(fan.index + 1)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.rpm(fan.rpm)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Palette.accent).frame(width: max(3, geo.size.width * fan.fraction))
                    if fan.maxRpm > 0 {
                        Rectangle().fill(Color.primary.opacity(0.45)).frame(width: 1.5, height: 10)
                            .offset(x: geo.size.width * min(1, fan.minRpm / fan.maxRpm))
                    }
                }
            }
            .frame(height: 8)
            Text("Minimum \(Format.rpm(fan.minRpm)) · Maximum \(Format.rpm(fan.maxRpm))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
