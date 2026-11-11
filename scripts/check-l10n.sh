#!/bin/zsh
# Checks the string catalogs (*.xcstrings under Sources/): German is the source language, and
# every key needs a finished English text (and a German one, so the German .lproj is built too).
# Fails on
#   - a key without an English translation in the state "translated" (also each plural variant),
#   - a key without a German text,
#   - a key marked "stale" (no longer in the code; run scripts/l10n-sync.sh, then delete it),
#   - a catalog whose source language is not "de".
# Needs jq (preinstalled on macOS 15+ and on the GitHub runners). No build, runs in a second.
#
# Adding a text: write it in the code in German (Text("…"), String(localized: "…"), L("…") in the
# packages), run scripts/l10n-sync.sh, then enter the English text and the German text (value =
# key, with %1$@ style placeholders if there are several) in Sources/<Module>/Localizable.xcstrings
# (Xcode's catalog editor, or by hand) with state "translated". Finally run this script.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq fehlt." >&2; exit 1; }

catalogs=(Sources/**/*.xcstrings(N))
(( $#catalogs )) || { echo "Keine Kataloge gefunden." >&2; exit 1; }

# For one catalog: prints one line per problem.
read -r -d '' program <<'JQ' || true
def units(lang): [.value.localizations[lang]? // empty | .. | objects | select(has("stringUnit")) | .stringUnit];
def bad(us): (us | length) == 0 or any(us[]; .state != "translated" or ((.value // "") | length) == 0);
(if .sourceLanguage != "de" then "Quellsprache ist nicht de: \(.sourceLanguage)" else empty end),
(.strings | to_entries[]
  | select(.value.extractionState == "stale")
  | "veraltet (stale): \(.key)"),
(.strings | to_entries[]
  | select(.value.extractionState != "stale")
  | (if bad(units("en")) then "englische Übersetzung fehlt oder ist nicht \"translated\": \(.key)" else empty end),
    (if bad(units("de")) then "deutscher Text fehlt: \(.key)" else empty end))
JQ

failed=0
total=0
for catalog in $catalogs; do
  keys=$(jq '.strings | length' "$catalog")
  total=$(( total + keys ))
  problems=$(jq -r "$program" "$catalog")
  if [[ -n $problems ]]; then
    failed=1
    echo "$catalog: $(print -r -- "$problems" | wc -l | tr -d ' ') Problem(e)" >&2
    print -r -- "$problems" | sed 's/^/  /' >&2
  else
    echo "$catalog: $keys Schlüssel, alle übersetzt"
  fi
done

(( failed )) && { echo "check-l10n: FEHLGESCHLAGEN" >&2; exit 1; }
echo "check-l10n: ok ($#catalogs Kataloge, $total Schlüssel)"
