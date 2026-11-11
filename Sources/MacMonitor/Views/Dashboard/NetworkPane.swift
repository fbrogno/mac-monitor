import MonitorCore
import SwiftUI

/// Network throughput and interfaces, volumes and disk throughput.
struct NetworkPane: View {
    let model: AppModel
    let data: DashboardData

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            throughputCard
            interfaceCard
            volumesCard
            diskCard
        }
    }

    private var throughputCard: some View {
        let d = data
        return DashCard(String(localized: "Netzwerk-Durchsatz"), trailing: {
            if let n = model.snapshot?.network {
                Text("↓ \(Format.rate(n.downBytesPerSecond))  ↑ \(Format.rate(n.upBytesPerSecond))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }, content: {
            HistoryChart(lines: [d.line(.netDown, String(localized: "Empfangen ↓"), Palette.accent),
                                 d.line(.netUp, String(localized: "Gesendet ↑"), Palette.warn)],
                         unit: .bytesPerSecond, from: d.from, to: d.to, domain: nil, height: 180, showsLegend: true)
        })
    }

    private var interfaceCard: some View {
        let detail = model.snapshot?.networkDetail
        return DashCard(String(localized: "Verbindung")) {
            VStack(alignment: .leading, spacing: 8) {
                if let primary = detail?.primary {
                    FactRow(String(localized: "Aktive Schnittstelle"), "\(primary.name) · \(kindName(primary.kind))")
                    FactRow(String(localized: "Lokale IP-Adresse"), primary.ipv4 ?? "–")
                } else if model.snapshot?.isOnline == false {
                    Label("Keine Internetverbindung", systemImage: "wifi.slash").font(.system(size: 12)).foregroundStyle(Palette.critical)
                } else {
                    UnavailableNote(text: String(localized: "Keine aktive Schnittstelle erkannt"))
                }
                let busy = (detail?.interfaces ?? []).filter { $0.rate.downBytesPerSecond + $0.rate.upBytesPerSecond > 0 || $0.name == detail?.primary?.name }
                if !busy.isEmpty {
                    Divider().opacity(0.5)
                    Text("Je Schnittstelle").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(busy.prefix(6), id: \.name) { item in
                        FactRow(item.name, "↓ \(Format.rate(item.rate.downBytesPerSecond))  ↑ \(Format.rate(item.rate.upBytesPerSecond))")
                    }
                }
            }
        }
    }

    private func kindName(_ kind: InterfaceKind) -> String {
        switch kind {
        case .wifi: String(localized: "WLAN")
        case .ethernet: String(localized: "Ethernet")
        case .other: String(localized: "Sonstige")
        }
    }

    private var volumesCard: some View {
        let volumes = model.snapshot?.volumes ?? []
        return DashCard(String(localized: "Laufwerke")) {
            if volumes.isEmpty {
                UnavailableNote(text: String(localized: "Keine Laufwerke gemeldet"))
            } else {
                VStack(spacing: 10) {
                    ForEach(volumes) { volume in
                        MeterBar(label: volume.isInternal ? volume.name : String(localized: "\(volume.name) (extern)"),
                                 value: volume.isReadOnly
                                    ? String(localized: "schreibgeschützt")
                                    : String(localized: "\(Format.bytes(volume.availableBytes)) frei von \(Format.bytes(volume.totalBytes))"),
                                 fraction: 1 - volume.freeFraction,
                                 tint: volume.isReadOnly ? Palette.accent
                                    : volume.freeFraction < 0.1 ? Palette.critical : volume.freeFraction < 0.2 ? Palette.warn : Palette.accent)
                    }
                }
            }
        }
    }

    private var diskCard: some View {
        let d = data
        return DashCard(String(localized: "Lese- und Schreibrate"), trailing: {
            if let io = model.snapshot?.diskThroughput {
                Text("Lesen \(Format.rate(io.readBytesPerSecond))  Schreiben \(Format.rate(io.writeBytesPerSecond))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }, content: {
            if model.snapshot?.diskThroughput == nil && !d.hasSeries(.diskRead, .diskWrite) {
                UnavailableNote()
            } else {
                HistoryChart(lines: [d.line(.diskRead, String(localized: "Lesen"), Palette.accent),
                                     d.line(.diskWrite, String(localized: "Schreiben"), Palette.warn)],
                             unit: .bytesPerSecond, from: d.from, to: d.to, domain: nil, height: 150, showsLegend: true)
            }
        })
    }
}
