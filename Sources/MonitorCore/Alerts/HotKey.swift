import Foundation

/// What a global shortcut does.
public enum HotKeyAction: String, CaseIterable, Codable, Sendable, Hashable {
    case openPopover, openDashboard, openOverview

    public var title: String {
        switch self {
        case .openPopover: "Menüleisten-Fenster öffnen"
        case .openDashboard: "Dashboard öffnen"
        case .openOverview: "Übersicht öffnen"
        }
    }
}

/// A key combination as Carbon's `RegisterEventHotKey` takes it: a virtual key code and Carbon modifier
/// flags. Needs no accessibility permission.
public struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000
    static let known: UInt32 = command | shift | option | control

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.known
    }

    public enum Problem: Equatable, Sendable {
        case needsModifier
        case reserved(String)
        case unknownKey

        public var message: String {
            switch self {
            case .needsModifier:
                "Ein Tastenkürzel braucht mindestens eine der Tasten ⌃, ⌥ oder ⌘, sonst würde es beim Tippen auslösen."
            case .reserved(let name):
                "Das Kürzel „\(name)“ gehört macOS oder dem aktiven Programm. Wähle eine andere Kombination."
            case .unknownKey:
                "Diese Taste kann nicht als Kürzel verwendet werden."
            }
        }
    }

    /// Combinations that macOS or nearly every app uses (virtual key codes: Q 12, W 13, H 4, M 46, Tab 48, Space 49, Esc 53).
    static let reserved: [(key: UInt32, modifiers: UInt32, name: String)] = [
        (12, command, "⌘Q"), (13, command, "⌘W"), (4, command, "⌘H"), (46, command, "⌘M"),
        (48, command, "⌘⇥"), (49, command, "⌘Leertaste"), (49, control, "⌃Leertaste"),
        (49, command | option, "⌥⌘Leertaste"), (53, command | option, "⌥⌘⎋"),
        (12, command | control, "⌃⌘Q"),
    ]

    /// nil when the combination is usable.
    public func validate() -> Problem? {
        if keyCode > 127 { return .unknownKey }
        if modifiers & (Self.command | Self.option | Self.control) == 0 { return .needsModifier }
        if let hit = Self.reserved.first(where: { $0.key == keyCode && $0.modifiers == modifiers }) {
            return .reserved(hit.name)
        }
        return nil
    }

    /// "⌃⌥⇧⌘" in the order macOS shows them.
    public var modifierSymbols: String {
        (modifiers & Self.control != 0 ? "⌃" : "") + (modifiers & Self.option != 0 ? "⌥" : "")
            + (modifiers & Self.shift != 0 ? "⇧" : "") + (modifiers & Self.command != 0 ? "⌘" : "")
    }

    /// Names for keys that have no printable character; nil for letters, digits and signs
    /// (the app asks the keyboard layout for those).
    public static func specialKeyName(_ keyCode: UInt32) -> String? {
        let names: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Leertaste", 51: "⌫", 53: "⎋", 71: "⌧", 76: "⌅", 114: "Hilfe", 115: "↖", 116: "⇞",
            117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        return names[keyCode]
    }
}

/// The three shortcuts; by default none is set.
public struct HotKeySettings: Codable, Equatable, Sendable {
    public var openPopover: HotKeyBinding?
    public var openDashboard: HotKeyBinding?
    public var openOverview: HotKeyBinding?

    public init(openPopover: HotKeyBinding? = nil, openDashboard: HotKeyBinding? = nil, openOverview: HotKeyBinding? = nil) {
        self.openPopover = openPopover
        self.openDashboard = openDashboard
        self.openOverview = openOverview
    }

    public subscript(action: HotKeyAction) -> HotKeyBinding? {
        get {
            switch action {
            case .openPopover: openPopover
            case .openDashboard: openDashboard
            case .openOverview: openOverview
            }
        }
        set {
            switch action {
            case .openPopover: openPopover = newValue
            case .openDashboard: openDashboard = newValue
            case .openOverview: openOverview = newValue
            }
        }
    }

    /// The other action that already uses `binding`, if any.
    public func conflict(for binding: HotKeyBinding, excluding action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && self[$0] == binding }
    }

    public var isEmpty: Bool { HotKeyAction.allCases.allSatisfy { self[$0] == nil } }

    private enum CodingKeys: String, CodingKey { case openPopover, openDashboard, openOverview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openPopover = try? c.decodeIfPresent(HotKeyBinding.self, forKey: .openPopover)
        openDashboard = try? c.decodeIfPresent(HotKeyBinding.self, forKey: .openDashboard)
        openOverview = try? c.decodeIfPresent(HotKeyBinding.self, forKey: .openOverview)
    }
}
