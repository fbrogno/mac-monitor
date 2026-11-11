import Foundation

/// Looks a text up in this module's catalog (`Localizable.xcstrings`).
///
/// German is the source language: the key is the German text with `%@` / `%lld` for the
/// interpolations, the English text lives in the catalog. A plain `swift build` does not compile
/// catalogs, so there (tests, image renderer) the key itself is shown, i.e. German.
///
/// Only texts shown to the user belong here. Anything stored or compared (rule ids, condition keys,
/// export columns) stays language-neutral.
@inline(__always)
func L(_ text: String.LocalizationValue) -> String {
    String(localized: text, bundle: .module)
}
