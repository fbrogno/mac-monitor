import AppKit
import CoreGraphics
import MonitorCore

/// What the Mac is doing right now, as far as it can be told without special permissions.
///
/// - Screen lock: the system's lock and unlock announcements.
/// - Presentation: a mirrored display (a projector in mirror mode). `CGDisplayIsCaptured` is no longer
///   supported by macOS, so exclusive capture is not detected. Screen sharing in Zoom or Teams and
///   full-screen slides are NOT detected either: there is no public interface for them that works
///   without extra permissions.
/// - Focus: not available. macOS only reveals the Focus state to apps with a special entitlement
///   (`com.apple.developer.focus-status`) that MacMonitor, signed with Developer ID and without a
///   provisioning profile, does not have. `focusDetectionAvailable` stays false and the setting is greyed out.
@MainActor
final class QuietState {
    static let focusDetectionAvailable = false

    private(set) var screenLocked = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false }
        })
    }

    /// Any display that is part of a mirror set.
    static func presentationDetected() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    func context(now: Date) -> QuietContext {
        QuietContext(focusActive: false, screenLocked: screenLocked, presenting: Self.presentationDetected(), date: now)
    }
}
