import AppKit
import MonitorCore
import SwiftUI

struct MenuBarPane: View {
    @Bindable var model: AppModel

    var body: some View {
        PaneForm {
            Section {
                ForEach(MenuBarItem.allCases, id: \.self) { item in
                    Toggle(item.title, isOn: binding(for: item))
                        .disabled(!isOn(item) && model.settings.menuBarItems.count >= MenuBarDisplay.maxItems)
                }
                LabeledContent("Vorschau") {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                        Text(previewText).font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Label {
                    Text("Zahlen in der Menüleiste kosten etwas Strom: Jede Änderung des Textes lässt macOS die Menüleiste auf jedem Bildschirm neu zeichnen. MacMonitor ändert den Text deshalb nur bei spürbaren Änderungen und höchstens alle 10 Sekunden.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "bolt.fill") }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Anzeige neben dem Symbol")
            } footer: {
                Text("Wähle bis zu drei Werte. Ohne Auswahl zeigt die Menüleiste nur das Symbol.")
            }

            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) {
                            ShortcutField(binding: shortcut(action), action: action, model: model)
                        }
                        if let failure = model.hotKeys.failures[action] { FieldError(messages: [failure]) }
                    }
                }
                SettingsNote("Die Kürzel gelten in jedem Programm und brauchen keine zusätzliche Berechtigung. Standardmäßig ist keines belegt.")
            } header: {
                Text("Tastenkürzel")
            }
        }
    }

    private func isOn(_ item: MenuBarItem) -> Bool { model.settings.menuBarItems.contains(item) }

    /// Keeps the fixed order of the list, whichever value is switched on first.
    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { isOn(item) },
            set: { on in
                var chosen = Set(model.settings.menuBarItems)
                if on { chosen.insert(item) } else { chosen.remove(item) }
                model.settings.menuBarItems = MenuBarItem.normalized(MenuBarItem.allCases.filter(chosen.contains))
            })
    }

    private func shortcut(_ action: HotKeyAction) -> Binding<HotKeyBinding?> {
        Binding(get: { model.settings.hotKeys[action] }, set: { model.settings.hotKeys[action] = $0 })
    }

    private var previewText: String {
        let values = model.snapshot.map(MenuBarValues.init)
            ?? MenuBarValues(cpuPercent: 18, memoryPercent: 64, gpuPercent: 9, temperatureCelsius: 52, watts: 11,
                             downBytesPerSecond: 1_900_000, batteryPercent: 82)
        let text = MenuBarDisplay.build(items: model.settings.menuBarItems, values: values)
        return text.isEmpty ? String(localized: "nur Symbol") : text
    }
}

/// A field that records a key combination: click it, press the shortcut. Escape cancels, delete clears.
struct ShortcutField: View {
    @Binding var binding: HotKeyBinding?
    let action: HotKeyAction
    let model: AppModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(recording ? Palette.accent : (binding == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(recording ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Palette.accent : Color.clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            if binding != nil {
                Button { binding = nil; message = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Kürzel entfernen")
            }
        }
        if let message { FieldError(messages: [message]).multilineTextAlignment(.trailing) }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return String(localized: "Kürzel drücken …") }
        return binding.map(HotKeyLabel.text) ?? String(localized: "Nicht belegt")
    }

    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let code = UInt32(event.keyCode)
        let modifiers = HotKeyLabel.carbonModifiers(event.modifierFlags)
        if code == 53, modifiers == 0 { stop(); return }                     // Escape
        if (code == 51 || code == 117), modifiers == 0 { binding = nil; stop(); return } // Delete
        let candidate = HotKeyBinding(keyCode: code, modifiers: modifiers)
        if let other = model.settings.hotKeys.conflict(for: candidate, excluding: action) {
            message = String(localized: "Dieses Kürzel ist schon für „\(other.title)“ belegt.")
            stop(); return
        }
        if let problem = model.hotKeys.conflictMessage(for: candidate, action: action, previous: binding) {
            message = problem
            stop(); return
        }
        binding = candidate
        message = nil
        stop()
    }
}
