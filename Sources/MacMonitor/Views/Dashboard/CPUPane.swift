import MonitorCore
import SwiftUI

/// CPU and GPU: history, bars per core, GPU memory, load average.
struct CPUPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            cpuCard
            if let cores = model.snapshot?.cpuCores { coresCard(cores) }
            CardGrid {
                gpuCard
                if data.hasSeries(.load1) { loadCard }
            }
        }
    }

    private var cpuCard: some View {
        let d = data
        var lines = [d.line(.cpuTotal, String(localized: "Gesamt"), Palette.accent)]
        if d.hasSeries(.cpuEfficiency) { lines.append(d.line(.cpuEfficiency, String(localized: "Effizienz-Kerne"), Palette.ok, band: false)) }
        if d.hasSeries(.cpuPerformance) { lines.append(d.line(.cpuPerformance, String(localized: "Performance-Kerne"), Palette.warn, band: false)) }
        return DashCard(String(localized: "CPU-Auslastung"), trailing: {
            if let s = model.snapshot { CardValue(Format.percent(s.cpuPercent)) }
        }, content: {
            HistoryChart(lines: lines, unit: .percent, from: d.from, to: d.to, domain: 0...100, height: 190,
                         showsLegend: true, previewHover: previewHover)
        })
    }

    /// Set by the offline renderer so the tooltip shows in README images.
    var previewHover: Date? { model.dashboard.previewHover }

    private func coresCard(_ cores: CPUCoreLoad) -> some View {
        DashCard(String(localized: "Kerne"), subtitle: String(localized: "\(cores.perCore.count) Kerne")) {
            let efficiency = Array(cores.efficiencyCores)
            let performance = Array(cores.performanceCores)
            let columns = Group {
                if !efficiency.isEmpty {
                    coreColumn(String(localized: "Effizienz-Kerne"), efficiency, offset: 0).frame(minWidth: 220)
                }
                coreColumn(efficiency.isEmpty ? nil : String(localized: "Performance-Kerne"),
                           performance, offset: efficiency.count).frame(minWidth: 220)
            }
            ColumnsLayout(minimum: 240, spacing: 32) { columns }
        }
    }

    private func coreColumn(_ title: String?, _ loads: [Double], offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            ForEach(loads.indices, id: \.self) { i in
                MeterBar(label: String(localized: "Kern \(offset + i + 1)"), value: Format.percent(loads[i]),
                         fraction: loads[i] / 100, tint: Palette.load(loads[i]))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gpuCard: some View {
        let d = data
        return DashCard(String(localized: "GPU"), trailing: {
            if let gpu = model.snapshot?.gpu { CardValue(Format.percent(gpu.utilizationPercent)) }
        }, content: {
            if model.snapshot?.gpu == nil && !d.hasSeries(.gpuPercent) {
                UnavailableNote()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HistoryChart(lines: [d.line(.gpuPercent, "GPU", Palette.accent)], unit: .percent,
                                 from: d.from, to: d.to, domain: 0...100, height: 140)
                    gpuMemory
                }
            }
        })
    }

    @ViewBuilder private var gpuMemory: some View {
        let d = data
        if let gpu = model.snapshot?.gpu, let used = gpu.memoryUsedBytes {
            let total = model.snapshot?.memoryTotalBytes ?? 0
            MeterBar(label: String(localized: "GPU-Speicher"),
                     value: gpu.memoryAllocatedBytes.map { String(localized: "\(Format.bytes(used)) benutzt · \(Format.bytes($0)) reserviert") } ?? Format.bytes(used),
                     fraction: total > 0 ? Double(used) / Double(total) : 0, tint: Palette.accent)
            if d.hasSeries(.gpuMemory) {
                HistoryChart(lines: [d.line(.gpuMemory, String(localized: "GPU-Speicher"), Palette.accent)], unit: .bytes,
                             from: d.from, to: d.to, domain: nil, height: 100)
            }
        } else {
            UnavailableNote(text: String(localized: "GPU-Speicher: auf diesem Mac nicht verfügbar"))
        }
    }

    private var loadCard: some View {
        let d = data
        return DashCard(String(localized: "Systemlast"), subtitle: String(localized: "Mittel über 1 Minute")) {
            HistoryChart(lines: [d.line(.load1, String(localized: "Last"), Palette.warn)], unit: .load,
                         from: d.from, to: d.to, domain: nil, height: 110)
        }
    }
}

/// Memory: used, pressure and swap over time.
struct MemoryPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        let d = data
        VStack(alignment: .leading, spacing: 16) {
            DashCard(String(localized: "Belegter Speicher"), trailing: {
                if let s = model.snapshot {
                    CardValue(String(localized: "\(Format.bytes(s.memoryUsedBytes)) von \(Format.bytes(s.memoryTotalBytes))"), prominent: false)
                }
            }, content: {
                HistoryChart(lines: [d.line(.memoryPercent, "RAM", Palette.accent)], unit: .percent,
                             from: d.from, to: d.to, domain: 0...100, height: 180)
                if let s = model.snapshot {
                    HStack(spacing: 8) {
                        Circle().fill(pressureColor(s.memoryPressure)).frame(width: 8, height: 8)
                        Text(pressureLabel(s.memoryPressure)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            })
            CardGrid {
            DashCard(String(localized: "Zeit unter Speicherdruck"), trailing: {
                if let seconds = pressureSeconds { CardValue(durationText(seconds)) }
            }, content: {
                if d.hasSeries(.memoryUnderPressure) {
                    HistoryChart(lines: [ChartLine(id: "pressure", name: String(localized: "unter Druck"),
                                                   color: Palette.warn, points: scaled(d.points(.memoryUnderPressure), by: 100),
                                                   showsBand: false)],
                                 unit: .percent, from: d.from, to: d.to, domain: 0...100, height: 100)
                    Text("Anteil der Zeit mit erhöhtem oder kritischem Druck, je Zeitabschnitt.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Noch keine Messwerte in diesem Zeitraum").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            })
            DashCard(String(localized: "Swap"), trailing: {
                if let s = model.snapshot { CardValue(Format.bytes(s.swapUsedBytes)) }
            }, content: {
                HistoryChart(lines: [d.line(.swapUsed, "Swap", Palette.warn)], unit: .bytes,
                             from: d.from, to: d.to, domain: nil, height: 120)
            })
            }
        }
    }

    /// Time under pressure in the range: share of time (mean of the 0/1 series) × bucket width.
    private var pressureSeconds: TimeInterval? {
        let points = data.points(.memoryUnderPressure).measured
        guard !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.avg * $1.span }
    }
}
