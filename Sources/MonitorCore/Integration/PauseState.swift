import Foundation

/// Global "mute until" time for notifications, set by the Shortcuts intents.
/// The notification path asks `isPaused()` before it delivers something (hooked up separately).
public struct PauseState: Sendable {
    public static let defaultsKey = "pause.until"

    private let defaults: UserDefaultsBox

    public init(defaults: UserDefaults = .standard) {
        self.defaults = UserDefaultsBox(defaults)
    }

    /// The moment the pause ends; nil when none was set.
    public var until: Date? {
        let seconds = defaults.value.double(forKey: Self.defaultsKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public func isPaused(at now: Date = Date()) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// Mutes until `now + duration` and returns the end time. A non-positive duration lifts the pause.
    @discardableResult
    public func pause(for duration: TimeInterval, from now: Date = Date()) -> Date? {
        guard duration > 0 else { resume(); return nil }
        let end = now.addingTimeInterval(duration)
        defaults.value.set(end.timeIntervalSince1970, forKey: Self.defaultsKey)
        return end
    }

    public func resume() {
        defaults.value.removeObject(forKey: Self.defaultsKey)
    }
}

/// `UserDefaults` is thread-safe but not declared `Sendable`.
private struct UserDefaultsBox: @unchecked Sendable {
    let value: UserDefaults
    init(_ value: UserDefaults) { self.value = value }
}
