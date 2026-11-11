import MonitorCore
import SwiftUI

/// Tools: clean up the SSD. Sizes are measured on demand (the button top right).
struct CleanupPane: View {
    let model: AppModel

    var body: some View {
        let cleanup = model.cleanup
        let disk = model.snapshot?.disk
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                intro(disk)
                Spacer(minLength: 8)
                if cleanup.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Messe …").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ActionButton(title: cleanup.sizes.isEmpty ? String(localized: "Größen messen") : String(localized: "Neu messen")) {
                        cleanup.scan()
                    }
                }
            }
            table(cleanup)
            summary(cleanup)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            // Measure automatically only when space is actually short; walking caches costs CPU.
            if cleanup.sizes.isEmpty, (disk?.freeFraction ?? 1) < 0.1 { cleanup.scan() }
        }
    }

    @ViewBuilder private func intro(_ disk: DiskStat?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let disk {
                Text("\(Format.bytes(disk.availableBytes)) von \(Format.bytes(disk.totalBytes)) frei")
                    .font(.headline).monospacedDigit()
            } else {
                UnavailableNote(text: String(localized: "Freier Speicher nicht verfügbar"))
            }
            Text("Alles hier baut sich bei Bedarf von selbst neu auf – deine Dateien bleiben unberührt.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func table(_ cleanup: CleanupModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(cleanup.targets.enumerated()), id: \.element.id) { index, target in
                if index > 0 { Divider().opacity(0.5) }
                row(target, cleanup)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func row(_ target: CleanupTarget, _ cleanup: CleanupModel) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(target.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(cleanup.sizes[target.id].map(Format.bytes) ?? "–")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle((cleanup.sizes[target.id] ?? 0) > 2 * 1_073_741_824 ? Palette.warn : .secondary)
                .frame(width: 80, alignment: .trailing)
            Group {
                if cleanup.busyTarget == target.id {
                    ProgressView().controlSize(.small)
                } else {
                    ActionButton(title: target.isRevealOnly ? String(localized: "Öffnen") : String(localized: "Aufräumen"),
                                 tint: target.isRevealOnly ? .primary : Palette.accent) {
                        cleanup.clean(target, ask: model.ask)
                    }
                    .disabled(cleanup.busyTarget != nil)
                }
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
    }

    private func summary(_ cleanup: CleanupModel) -> some View {
        HStack(spacing: 10) {
            if cleanup.reclaimableBytes > 0 {
                Text("Zusammen \(Format.bytes(cleanup.reclaimableBytes)) frei machbar.")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            } else if cleanup.sizes.isEmpty && !cleanup.isScanning {
                Text("Noch nicht gemessen").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let freed = cleanup.lastFreed {
                Text("\(freed.title): \(Format.bytes(freed.bytes)) freigegeben.")
                    .font(.system(size: 12)).foregroundStyle(Palette.ok)
            }
            Spacer(minLength: 8)
            ActionButton(title: String(localized: "Speicherverwaltung von macOS")) { model.perform(.openStorageSettings) }
        }
    }
}
