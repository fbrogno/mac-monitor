#!/bin/zsh
# One-time setup for the release pipeline, run by the repo owner on the Mac that holds the
# Developer ID certificate. Never prints a secret value.
#
#   1. Sparkle key pair (generate_keys, kept in the login keychain). Only the PUBLIC key goes
#      into Config/Sparkle.xcconfig.
#   2. ONLY the Developer ID Application identity exported as .p12 (via a temp keychain).
#   3. The six GitHub Actions secrets, set from stdin/files via `gh secret set`.
# Temp files are removed on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=fbrogno/mac-monitor
sparkle_bin=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin

command -v gh >/dev/null || { echo "gh fehlt." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh ist nicht angemeldet (gh auth login)." >&2; exit 1; }

tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

print "Setzt sechs Secrets in $repo und trägt den öffentlichen Sparkle-Schlüssel ein."
read -r "go?Fortfahren? [j/N] "
[[ $go == [jJ] ]] || { echo "Abgebrochen."; exit 1; }

# --- 1. Sparkle -------------------------------------------------------------------------
if [[ ! -x $sparkle_bin/generate_keys ]]; then
  xcodegen generate --quiet
  xcodebuild -resolvePackageDependencies -project MacMonitor.xcodeproj -scheme MacMonitor \
    -derivedDataPath build/DerivedData -quiet
fi
[[ -x $sparkle_bin/generate_keys ]] || { echo "Sparkle-Werkzeuge nicht gefunden in $sparkle_bin." >&2; exit 1; }

# Creates the key pair only if none exists; macOS may ask to allow keychain access.
"$sparkle_bin/generate_keys" >/dev/null
public_key=$("$sparkle_bin/generate_keys" -p)
[[ -n $public_key ]] || { echo "Öffentlicher Sparkle-Schlüssel nicht lesbar." >&2; exit 1; }
# A different key than the one already shipped would lock every installed copy out of updates.
existing_key=$(sed -n 's/^SPARKLE_PUBLIC_ED_KEY *= *//p' Config/Sparkle.xcconfig | tr -d '[:space:]')
if [[ -n $existing_key && $existing_key != "$public_key" ]]; then
  echo "ABBRUCH: Config/Sparkle.xcconfig enthält bereits einen anderen öffentlichen Sparkle-Schlüssel." >&2
  echo "Ein neuer Schlüssel würde Updates für alle installierten Versionen unmöglich machen." >&2
  echo "Den ursprünglichen privaten Schlüssel auf diesem Mac importieren: generate_keys -f <Datei>." >&2
  exit 1
fi
print -r -- "// Public EdDSA key for Sparkle update verification. Written by scripts/setup-release-secrets.sh.
SPARKLE_PUBLIC_ED_KEY = $public_key" > Config/Sparkle.xcconfig
echo "Öffentlicher Sparkle-Schlüssel in Config/Sparkle.xcconfig eingetragen."

"$sparkle_bin/generate_keys" -x "$tmp/sparkle.key" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" < "$tmp/sparkle.key"
rm -f "$tmp/sparkle.key"

# --- 2. Developer ID --------------------------------------------------------------------
# `security export` cannot pick a single identity, so everything is exported into a temp
# keychain first, every identity except the one Developer ID Application identity is removed
# there, and only that one is exported again. Nothing else ever leaves this Mac.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "Keine Developer-ID-Application-Identität im Schlüsselbund." >&2
  exit 1
fi
all_password=$(openssl rand -hex 24)
p12_password=$(openssl rand -hex 24)
kc_password=$(openssl rand -hex 24)
kc="$tmp/export.keychain-db"
kc_check="$tmp/check.keychain-db"
trap 'security delete-keychain "$kc" 2>/dev/null; security delete-keychain "$kc_check" 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM

security export -t identities -f pkcs12 -P "$all_password" -o "$tmp/all.p12" >/dev/null
security create-keychain -p "$kc_password" "$kc"
security unlock-keychain -p "$kc_password" "$kc"
security import "$tmp/all.p12" -k "$kc" -P "$all_password" -f pkcs12 -A >/dev/null
rm -f "$tmp/all.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_password" "$kc" >/dev/null 2>&1 || true

# Lines look like:  1) <40 hex> "Name" [(CSSMERR…)]
security find-identity "$kc" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)".*$/\1 \2/p' | sort -u > "$tmp/ids.txt"
keep=()
while read -r sha name; do
  if [[ $name == "Developer ID Application:"* ]]; then
    keep+=("$sha")
  else
    security delete-identity -Z "$sha" "$kc" >/dev/null
  fi
done < "$tmp/ids.txt"
if (( ${#keep} != 1 )); then
  echo "ABBRUCH: ${#keep} Developer-ID-Application-Identitäten gefunden, erwartet genau eine." >&2
  echo "Bei mehreren Teams die gewünschte Identität von Hand als .p12 exportieren." >&2
  exit 1
fi

security export -k "$kc" -t identities -f pkcs12 -P "$p12_password" -o "$tmp/identity.p12" >/dev/null

# Prove what is about to be uploaded: exactly one identity, and it is the Developer ID one.
security create-keychain -p "$kc_password" "$kc_check"
security unlock-keychain -p "$kc_password" "$kc_check"
security import "$tmp/identity.p12" -k "$kc_check" -P "$p12_password" -f pkcs12 -A >/dev/null
count=$(security find-identity "$kc_check" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) ".*$/\1/p' | sort -u | wc -l | tr -d ' ')
only=$(security find-identity "$kc_check" | grep -c "Developer ID Application:" || true)
if [[ $count != 1 || $only == 0 ]]; then
  echo "ABBRUCH: Die erzeugte .p12 enthält $count Identitäten statt genau der Developer ID. Nichts hochgeladen." >&2
  exit 1
fi
echo "Geprüft: Die .p12 enthält genau eine Identität (Developer ID Application)."

base64 -i "$tmp/identity.p12" | tr -d '\n' | gh secret set DEVELOPER_ID_P12_BASE64 --repo "$repo"
print -rn -- "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo"
unset p12_password all_password kc_password

# --- 3. App Store Connect API key (notarization) ----------------------------------------
read -r "p8_path?Pfad zur .p8-Datei des App-Store-Connect-API-Schlüssels: "
p8_path=${~p8_path}
[[ -f $p8_path ]] || { echo "Datei nicht gefunden: $p8_path" >&2; exit 1; }
read -r "key_id?Key-ID: "
read -r "issuer_id?Issuer-ID: "
[[ -n $key_id && -n $issuer_id ]] || { echo "Key-ID und Issuer-ID dürfen nicht leer sein." >&2; exit 1; }
print -rn -- "$key_id" | gh secret set ASC_KEY_ID --repo "$repo"
print -rn -- "$issuer_id" | gh secret set ASC_ISSUER_ID --repo "$repo"
base64 -i "$p8_path" | tr -d '\n' | gh secret set ASC_KEY_P8_BASE64 --repo "$repo"

echo
echo "Fertig. Gesetzt in $repo:"
gh secret list --repo "$repo" | awk '{print "  " $1}'
echo "Noch zu tun: Config/Sparkle.xcconfig committen und pushen, dann Tag v\$(cat VERSION) setzen."
