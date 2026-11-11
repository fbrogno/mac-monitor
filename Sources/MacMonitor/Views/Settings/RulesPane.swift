import MonitorCore
import SwiftUI

/// All built-in rules by group: switch, thresholds and minimum duration, and a reset per group.
struct RulesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        PaneForm {
            ForEach(RuleGroup.allCases) { group in
                Section {
                    ForEach(group.rules, id: \.self) { rule in
                        RuleRows(model: model, rule: rule)
                    }
                    HStack {
                        Spacer()
                        Button("Auf Standard zurücksetzen") { model.settings.reset(group) }
                            .controlSize(.small)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
    }
}

private struct RuleRows: View {
    @Bindable var model: AppModel
    let rule: RuleID

    var body: some View {
        let on = model.settings.isEnabled(rule)
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(
                get: { model.settings.isEnabled(rule) },
                set: { if $0 { model.settings.enabledRules.insert(rule) } else { model.settings.enabledRules.remove(rule) } })) {
                Text(rule.title).fontWeight(.medium)
            }
            summary
        }
        if on { controls }
    }

    @ViewBuilder private var summary: some View {
        switch rule {
        case .runawayProcess: SettingsNote("Meldet, wenn ein einzelnes Programm lange ununterbrochen viel CPU braucht.")
        case .memoryHog: SettingsNote("Meldet, wenn ein einzelnes Programm einen großen Teil des Arbeitsspeichers belegt.")
        case .cpuHigh: SettingsNote("Meldet, wenn die CPU des ganzen Macs lange ausgelastet ist.")
        case .memoryPressure: SettingsNote("Meldet, wenn macOS den Arbeitsspeicher als knapp einstuft.")
        case .swap: SettingsNote("Meldet, wenn viel Speicher auf die SSD ausgelagert wird und der Swap weiter wächst.")
        case .thermal: SettingsNote("Meldet, wenn macOS den Mac wegen Hitze drosselt.")
        case .cpuTemperature: SettingsNote("Meldet, wenn die CPU dauerhaft zu heiß ist, noch bevor macOS drosselt.")
        case .fanMaxed: SettingsNote("Meldet, wenn ein Lüfter dauerhaft fast auf voller Drehzahl läuft.")
        case .gpuHigh: SettingsNote("Meldet, wenn die Grafikeinheit dauerhaft stark ausgelastet ist. Standardmäßig aus.")
        case .network: SettingsNote("Meldet, wenn der Mac keine Internetverbindung mehr hat, und wenn sie zurück ist.")
        case .batteryHealth: SettingsNote("Meldet, wenn der Akku deutlich an Kapazität verloren hat. Erinnert höchstens einmal pro Woche.")
        case .batteryDrainOnAC: SettingsNote("Meldet, wenn der Akku trotz angeschlossenem Netzteil weiter entlädt.")
        case .energyHog: SettingsNote("Meldet, wenn ein Programm im Akkubetrieb im Schnitt der letzten 5 Minuten viel Strom zieht.")
        case .sleepBlocker: SettingsNote("Meldet, wenn ein Programm im Akkubetrieb lange verhindert, dass der Mac schläft.")
        case .disk: SettingsNote("Meldet, wenn auf dem Startvolume der freie Platz knapp wird.")
        case .volumeFull: SettingsNote("Meldet, wenn auf einem weiteren Volume, etwa einer externen Platte, der Platz knapp wird. Nutzt dieselben Schwellen wie „Festplatte voll“.")
        case .ssdWear: SettingsNote("Meldet, wenn die SSD stark abgenutzt ist oder ihre Reserve schrumpft. Erinnert höchstens einmal pro Woche.")
        case .custom: EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        switch rule {
        case .runawayProcess:
            ValueStepper(title: "Ab CPU-Last eines Prozesses", value: $model.settings.processCPUThreshold, range: 50...800, step: 10, unit: "%")
            DurationPicker(title: "Mindestens für", value: $model.settings.processCPUSustain)
        case .memoryHog:
            ValueStepper(title: "Ab Anteil am Arbeitsspeicher", value: percentBinding($model.settings.memoryHogFraction), range: 10...60, step: 5, unit: "%")
            DurationPicker(title: "Mindestens für", value: $model.settings.memoryHogSustain)
        case .cpuHigh:
            ValueStepper(title: "Ab Gesamt-CPU", value: $model.settings.cpuTotalThreshold, range: 50...100, step: 5, unit: "%")
            DurationPicker(title: "Mindestens für", value: $model.settings.cpuTotalSustain)
        case .memoryPressure:
            DurationPicker(title: "Warnstufe mindestens für", value: $model.settings.memoryPressureSustain)
        case .swap:
            ValueStepper(title: "Ab Swap-Größe", value: $model.settings.swapThresholdGB, range: 1...64, step: 1, unit: "GB")
        case .thermal, .custom:
            EmptyView()
        case .cpuTemperature:
            ValueStepper(title: "Ab Temperatur", value: $model.settings.cpuTempThreshold, range: 60...110, step: 1, unit: "°C")
            DurationPicker(title: "Mindestens für", value: $model.settings.cpuTempSustain)
        case .fanMaxed:
            ValueStepper(title: "Ab Drehzahl-Anteil", value: $model.settings.fanMaxPercent, range: 50...100, step: 5, unit: "%")
            DurationPicker(title: "Mindestens für", value: $model.settings.fanMaxSustain)
        case .gpuHigh:
            ValueStepper(title: "Ab GPU-Auslastung", value: $model.settings.gpuHighThreshold, range: 50...100, step: 5, unit: "%")
            DurationPicker(title: "Mindestens für", value: $model.settings.gpuHighSustain)
        case .network:
            DurationPicker(title: "Offline mindestens für", value: $model.settings.networkOfflineSustain)
        case .batteryHealth:
            ValueStepper(title: "Warnen unter Kapazität von", value: $model.settings.batteryHealthMinPercent, range: 50...95, step: 1, unit: "%")
        case .batteryDrainOnAC:
            DurationPicker(title: "Entladen mindestens für", value: $model.settings.batteryDrainSustain)
        case .energyHog:
            ValueStepper(title: "Ab Leistung im Schnitt", value: $model.settings.energyHogWatts, range: 1...30, step: 1, unit: "W")
            DurationPicker(title: "Mindestens für", value: $model.settings.energyHogSustain)
        case .sleepBlocker:
            DurationPicker(title: "Im Akkubetrieb länger als", value: $model.settings.sleepBlockerSustain, options: [600, 1800, 3600, 7200])
        case .disk:
            ValueStepper(title: "Warnen unter freiem Platz von", value: $model.settings.diskMinFreeGB, range: 5...200, step: 5, unit: "GB")
            ValueStepper(title: "oder unter einem Anteil von", value: $model.settings.diskMinFreePercent, range: 1...50, step: 1, unit: "%")
        case .volumeFull:
            EmptyView()
        case .ssdWear:
            ValueStepper(title: "Ab Abnutzung", value: $model.settings.ssdWearPercent, range: 50...100, step: 5, unit: "%")
            ValueStepper(title: "Oder Reserve unter", value: $model.settings.ssdSpareMinPercent, range: 5...50, step: 5, unit: "%")
        }
    }

    /// A 0…1 fraction shown as percent.
    private func percentBinding(_ fraction: Binding<Double>) -> Binding<Double> {
        Binding(get: { (fraction.wrappedValue * 100).rounded() }, set: { fraction.wrappedValue = $0 / 100 })
    }
}
