import Foundation

/// User settings for when MacMonitor should stay quiet. Decoding tolerates missing keys.
public struct QuietSettings: Codable, Equatable, Sendable {
    public var respectFocus: Bool = true
    public var respectScreenLock: Bool = true
    public var respectPresentation: Bool = true
    public var quietHoursEnabled: Bool = false
    /// Minutes since midnight. Start after end means the period runs past midnight.
    public var quietHoursStart: Int = 22 * 60
    public var quietHoursEnd: Int = 7 * 60
    /// Critical alerts ignore focus, presentation and quiet hours.
    public var criticalBreaksThrough: Bool = true
    public var soundEnabled: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case respectFocus, respectScreenLock, respectPresentation, quietHoursEnabled
        case quietHoursStart, quietHoursEnd, criticalBreaksThrough, soundEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QuietSettings()
        respectFocus = (try? c.decodeIfPresent(Bool.self, forKey: .respectFocus)) ?? d.respectFocus
        respectScreenLock = (try? c.decodeIfPresent(Bool.self, forKey: .respectScreenLock)) ?? d.respectScreenLock
        respectPresentation = (try? c.decodeIfPresent(Bool.self, forKey: .respectPresentation)) ?? d.respectPresentation
        quietHoursEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled)) ?? d.quietHoursEnabled
        quietHoursStart = (try? c.decodeIfPresent(Int.self, forKey: .quietHoursStart)) ?? d.quietHoursStart
        quietHoursEnd = (try? c.decodeIfPresent(Int.self, forKey: .quietHoursEnd)) ?? d.quietHoursEnd
        criticalBreaksThrough = (try? c.decodeIfPresent(Bool.self, forKey: .criticalBreaksThrough)) ?? d.criticalBreaksThrough
        soundEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .soundEnabled)) ?? d.soundEnabled
    }
}

/// What is going on right now, handed in by the app.
public struct QuietContext: Sendable, Equatable {
    public var focusActive: Bool
    public var screenLocked: Bool
    public var presenting: Bool
    /// Minutes since midnight in the user's time zone.
    public var minuteOfDay: Int

    public init(focusActive: Bool = false, screenLocked: Bool = false, presenting: Bool = false, minuteOfDay: Int) {
        self.focusActive = focusActive
        self.screenLocked = screenLocked
        self.presenting = presenting
        self.minuteOfDay = minuteOfDay
    }

    public init(focusActive: Bool = false, screenLocked: Bool = false, presenting: Bool = false,
                date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(focusActive: focusActive, screenLocked: screenLocked, presenting: presenting,
                  minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

/// What may be shown for one event.
public struct QuietDecision: Sendable, Equatable {
    /// System notification banner (delivered silently into Notification Center when `sound` is false).
    public let banner: Bool
    /// MacMonitor's own alert panel.
    public let overlay: Bool
    public let sound: Bool

    public init(banner: Bool, overlay: Bool, sound: Bool) {
        self.banner = banner
        self.overlay = overlay
        self.sound = sound
    }

    public static let silent = QuietDecision(banner: false, overlay: false, sound: false)
}

/// Pure decision about banner, panel and sound.
///
/// - Critical alerts always get through when `criticalBreaksThrough` is on (the panel is skipped
///   while the screen is locked, nobody could see it).
/// - Info is dropped entirely during focus, presentation, screen lock and quiet hours.
/// - Warnings (and critical alerts without break-through) still reach Notification Center during
///   those times, but without panel and sound.
/// - Sound only for `fired` and `escalated`, never for reminders or `resolved`, never for info.
public enum QuietPolicy {
    public static func decide(severity: Severity, kind: AlertEvent.Kind, settings: QuietSettings,
                              context: QuietContext) -> QuietDecision {
        let quietState = (context.focusActive && settings.respectFocus)
            || (context.screenLocked && settings.respectScreenLock)
            || (context.presenting && settings.respectPresentation)
        let quiet = quietState || isInQuietHours(settings: settings, minuteOfDay: context.minuteOfDay)

        let soundKind = kind == .fired || kind == .escalated
        let soundAllowed = settings.soundEnabled && soundKind && severity >= .warning

        var decision: QuietDecision
        if severity == .critical && settings.criticalBreaksThrough {
            decision = QuietDecision(banner: true, overlay: true, sound: soundAllowed)
        } else if !quiet {
            decision = QuietDecision(banner: true, overlay: true, sound: soundAllowed)
        } else if severity == .info {
            decision = .silent
        } else {
            decision = QuietDecision(banner: true, overlay: false, sound: false)
        }
        if context.screenLocked { decision = QuietDecision(banner: decision.banner, overlay: false, sound: decision.sound) }
        return decision
    }

    /// Whether `minuteOfDay` lies in the quiet hours; start equal to end means no quiet hours.
    public static func isInQuietHours(settings: QuietSettings, minuteOfDay: Int) -> Bool {
        guard settings.quietHoursEnabled else { return false }
        let start = settings.quietHoursStart, end = settings.quietHoursEnd
        if start == end { return false }
        return start < end
            ? minuteOfDay >= start && minuteOfDay < end
            : minuteOfDay >= start || minuteOfDay < end
    }
}
