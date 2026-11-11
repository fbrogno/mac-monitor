import AppKit
import Carbon.HIToolbox
import MonitorCore
import Observation

/// Global shortcuts through Carbon's `RegisterEventHotKey`. It needs no permission (no accessibility
/// access), and a shortcut that another app already holds is refused by the system, which we report.
@MainActor @Observable
final class HotKeyManager {
    /// Why a shortcut could not be registered, by action; empty when everything works.
    private(set) var failures: [HotKeyAction: String] = [:]
    @ObservationIgnored var onAction: ((HotKeyAction) -> Void)?
    @ObservationIgnored private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?

    private static let signature: OSType = 0x4D4D4B59 // "MMKY"
    nonisolated(unsafe) private static weak var current: HotKeyManager?

    private static func id(for action: HotKeyAction) -> UInt32 {
        UInt32(HotKeyAction.allCases.firstIndex(of: action)! + 1)
    }

    /// Replaces all registered shortcuts with those in `settings`.
    func apply(_ settings: HotKeySettings) {
        installHandlerIfNeeded()
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs = [:]
        failures = [:]
        for action in HotKeyAction.allCases {
            guard let binding = settings[action] else { continue }
            if let problem = binding.validate() { failures[action] = problem.message; continue }
            switch Self.register(binding, id: Self.id(for: action)) {
            case .success(let ref): refs[action] = ref
            case .failure(let message): failures[action] = message
            }
        }
    }

    /// Whether the system would accept `binding` for `action` right now (registers it for a moment).
    /// Returns a message for the user when it would not. `previous` is what the action has now.
    func conflictMessage(for binding: HotKeyBinding, action: HotKeyAction, previous: HotKeyBinding?) -> String? {
        if let problem = binding.validate() { return problem.message }
        if binding == previous { return nil }
        switch Self.register(binding, id: 99) {
        case .success(let ref): UnregisterEventHotKey(ref); return nil
        case .failure(let message): return message
        }
    }

    private enum Registration { case success(EventHotKeyRef), failure(String) }

    private static func register(_ binding: HotKeyBinding, id: UInt32) -> Registration {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { return .success(ref) }
        if status == OSStatus(eventHotKeyExistsErr) {
            return .failure(String(localized: "Dieses Kürzel ist schon von einem anderen Programm belegt. Wähle eine andere Kombination."))
        }
        return .failure(String(localized: "Das Kürzel konnte nicht eingerichtet werden (Fehler \(status))."))
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == HotKeyManager.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let action = HotKeyAction.allCases.first(where: { HotKeyManager.id(for: $0) == hotKey.id }) else { return }
                    HotKeyManager.current?.onAction?(action)
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Human-readable form of a shortcut, e.g. "⌃⌥D", using the keyboard layout in use.
enum HotKeyLabel {
    static func text(_ binding: HotKeyBinding) -> String {
        binding.modifierSymbols + keyName(binding.keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let special = HotKeyBinding.specialKeyName(keyCode) { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Taste \(keyCode)" }
        let layout = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layout) else { return "Taste \(keyCode)" }
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Taste \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Carbon modifier flags for the modifiers of a key event.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        (flags.contains(.command) ? HotKeyBinding.command : 0) | (flags.contains(.shift) ? HotKeyBinding.shift : 0)
            | (flags.contains(.option) ? HotKeyBinding.option : 0) | (flags.contains(.control) ? HotKeyBinding.control : 0)
    }
}
