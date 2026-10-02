import AppKit
import MonitorCore
import Observation

/// State of the "SSD aufräumen" section. Sizes are measured on demand only, never in the
/// background, because walking large cache folders is expensive.
@MainActor @Observable
final class CleanupModel {
    let targets = CleanupTarget.all()
    private(set) var sizes: [String: UInt64] = [:]
    private(set) var isScanning = false
    private(set) var busyTarget: String?
    private(set) var lastFreed: (title: String, bytes: UInt64)?

    var reclaimableBytes: UInt64 {
        targets.filter { !$0.isRevealOnly }.compactMap { sizes[$0.id] }.reduce(0, +)
    }

    /// Fixed sizes for rendered screenshots.
    func useDemoSizes() {
        sizes = ["caches": 14_100_000_000, "derived": 5_400_000_000, "npm": 8_200_000_000, "uv": 6_900_000_000,
                 "gradle": 2_500_000_000, "simulators": 12_000_000_000, "docker": 9_400_000_000, "downloads": 11_000_000_000]
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let targets = targets
        Task.detached(priority: .utility) {
            let result = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, CleanupRunner.size(of: $0)) })
            await MainActor.run {
                self.sizes = result
                self.isScanning = false
            }
        }
    }

    func clean(_ target: CleanupTarget, confirm: (String, String, String) -> Bool) {
        if case .revealOnly(let path) = target.method {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let size = sizes[target.id].map { " (\(Format.bytes($0)))" } ?? ""
        guard confirm("\(target.title) aufräumen\(size)?", target.consequence, "Aufräumen") else { return }
        busyTarget = target.id
        Task.detached(priority: .utility) {
            let before = CleanupRunner.size(of: target)
            CleanupRunner.run(target)
            let after = CleanupRunner.size(of: target)
            await MainActor.run {
                self.sizes[target.id] = after
                self.busyTarget = nil
                self.lastFreed = (target.title, before > after ? before - after : 0)
            }
        }
    }
}
