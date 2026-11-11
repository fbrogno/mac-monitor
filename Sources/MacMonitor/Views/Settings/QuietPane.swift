import MonitorCore
import SwiftUI

struct QuietPane: View {
    @Bindable var model: AppModel

    var body: some View {
        PaneForm {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Fokus beachten", isOn: .constant(false))
                        .disabled(!QuietState.focusDetectionAvailable)
                    SettingsNote("Nicht verfügbar: macOS verrät den Fokus nur Apps mit einer besonderen Apple-Berechtigung, die MacMonitor nicht hat. macOS selbst hält Mitteilungen im Fokus ohnehin zurück. Für das Hinweisfenster und den Ton helfen die Ruhezeiten unten.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Bei gesperrtem Bildschirm", isOn: $model.settings.quiet.respectScreenLock)
                    SettingsNote("Dann gibt es kein Hinweisfenster. Warnungen landen still in der Mitteilungszentrale.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Bei Präsentation oder Bildschirmspiegelung", isOn: $model.settings.quiet.respectPresentation)
                    SettingsNote("Erkannt wird ein gespiegelter Bildschirm, etwa ein Beamer im Spiegelmodus. Eine Bildschirmfreigabe in Zoom oder Teams und Folien im Vollbild erkennt MacMonitor nicht.")
                }
            } header: {
                Text("Wann Ruhe herrscht")
            }

            Section {
                Toggle("Ruhezeiten", isOn: $model.settings.quiet.quietHoursEnabled)
                if model.settings.quiet.quietHoursEnabled {
                    DatePicker("Von", selection: time($model.settings.quiet.quietHoursStart), displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: time($model.settings.quiet.quietHoursEnd), displayedComponents: .hourAndMinute)
                    SettingsNote("Liegt „Bis“ vor „Von“, gilt die Ruhezeit über Mitternacht hinaus.")
                }
            } header: {
                Text("Ruhezeiten")
            }

            Section {
                Toggle("Kritische Meldungen kommen immer durch", isOn: $model.settings.quiet.criticalBreaksThrough)
                Toggle("Ton bei Warnungen und kritischen Meldungen", isOn: $model.settings.quiet.soundEnabled)
                SettingsNote("In ruhigen Zeiten bleiben Hinweise ganz weg. Warnungen kommen leise in die Mitteilungszentrale, ohne Hinweisfenster und ohne Ton. Erinnerungen und „Behoben“-Meldungen machen nie ein Geräusch.")
            } header: {
                Text("Was trotzdem passiert")
            }
        }
    }

    /// Minutes since midnight as a time of day for the picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}
