import AppKit
import MonitorCore
import SwiftUI

struct IgnoredPane: View {
    @Bindable var model: AppModel
    @State private var newName = ""

    var body: some View {
        PaneForm {
            Section {
                if model.settings.ignoredProcesses.isEmpty {
                    SettingsNote("Es wird nichts ignoriert.")
                }
                ForEach(model.settings.ignoredProcesses, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button { model.settings.ignoredProcesses.removeAll { $0 == name } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Nicht mehr ignorieren")
                    }
                }
                HStack {
                    TextField("Prozessname", text: $newName, prompt: Text("Name des Prozesses"))
                        .labelsHidden()
                        .onSubmit(add)
                    Menu {
                        ForEach(suggestions, id: \.self) { name in Button(name) { newName = name } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Laufende Prozesse")
                    Button("Hinzufügen", action: add)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Dauerhaft ignorierte Prozesse")
            } footer: {
                Text("Diese Prozesse lösen keine Prozess-Warnungen aus. Der genaue Name steht in der Prozessliste.")
            }

            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let muted = model.mutedProcesses
                    if muted.isEmpty {
                        SettingsNote("Gerade ist kein Prozess stummgeschaltet.")
                    }
                    ForEach(muted, id: \.name) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text("noch \(Format.duration(max(60, (item.until.timeIntervalSince(context.date) / 60).rounded(.up) * 60)))")
                                .foregroundStyle(.secondary).monospacedDigit()
                            Button("Stumm aufheben") { model.unmute(item.name) }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Gerade stummgeschaltet")
            } footer: {
                Text("Stummschalten geht über „1 h stumm“ in einer Mitteilung. Nach Ablauf meldet MacMonitor wieder.")
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.settings.ignoredProcesses.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            newName = ""
            return
        }
        model.settings.ignoredProcesses.append(name)
        newName = ""
    }

    private var suggestions: [String] {
        let current = Set(model.settings.ignoredProcesses.map { $0.lowercased() })
        return (model.snapshot?.processes ?? []).prefix(40).map(\.name)
            .filter { !current.contains($0.lowercased()) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}
