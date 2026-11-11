import Foundation

/// The field of the rule editor an error belongs to, so the message can stand right next to it.
public enum RuleField: String, Sendable, CaseIterable {
    case name, process, threshold, duration, cooldown, actions
}

extension RuleValidationError {
    public var field: RuleField {
        switch self {
        case .emptyName, .nameTooLong: .name
        case .thresholdNotFinite, .thresholdNegative, .thresholdAbove100: .threshold
        case .negativeDuration: .duration
        case .negativeCooldown: .cooldown
        case .missingProcessName, .protectedProcess: .process
        case .noActions, .actionNeedsProcessMetric, .emptyShortcutName, .invalidURL: .actions
        }
    }

    /// A complete German sentence for the person editing the rule.
    public var message: String {
        switch self {
        case .emptyName:
            L("Gib der Regel einen Namen, damit du sie in der Liste wiederfindest.")
        case .nameTooLong(let maxLength):
            L("Der Name ist zu lang. Er darf höchstens \(maxLength) Zeichen haben.")
        case .thresholdNotFinite:
            L("Gib für die Schwelle eine Zahl ein.")
        case .thresholdNegative:
            L("Die Schwelle darf nicht negativ sein.")
        case .thresholdAbove100:
            L("Diese Messgröße geht nur bis 100 Prozent. Wähle eine Schwelle von höchstens 100.")
        case .negativeDuration:
            L("Die Dauer darf nicht negativ sein.")
        case .negativeCooldown:
            L("Die Abklingzeit darf nicht negativ sein.")
        case .missingProcessName:
            L("Wähle ein Programm aus oder gib den Namen eines Programms ein.")
        case .noActions:
            L("Füge mindestens eine Aktion hinzu, sonst passiert bei dieser Regel nichts.")
        case .actionNeedsProcessMetric(let kind):
            switch kind {
            case .quitProcess:
                L("„Prozess beenden“ geht nur mit der Messgröße „CPU eines Prozesses“ oder „RAM eines Prozesses“.")
            case .throttleProcess:
                L("„Prozess drosseln“ geht nur mit der Messgröße „CPU eines Prozesses“ oder „RAM eines Prozesses“.")
            case .showNotification, .runShortcut, .openURL:
                L("Diese Aktion braucht eine Messgröße, die zu einem Prozess gehört.")
            }
        case .protectedProcess(let name):
            L("„\(name)“ gehört zum System oder zu MacMonitor und wird nie beendet oder gedrosselt. Wähle ein anderes Programm.")
        case .emptyShortcutName:
            L("Wähle einen Kurzbefehl aus oder gib seinen Namen ein.")
        case .invalidURL(let text):
            text.trimmingCharacters(in: .whitespaces).isEmpty
                ? L("Gib eine Adresse ein, die mit https:// beginnt.")
                : L("Diese Adresse kann nicht geöffnet werden. Sie muss mit https:// oder http:// beginnen oder die Adresse einer App sein.")
        }
    }
}
