#!/bin/zsh
# One-time setup for the release pipeline, run by the repo owner on the Mac that holds the
# Developer ID certificate. Never prints a secret value.
#
#   1. Sparkle key pair (generate_keys, kept in the login keychain). Only the PUBLIC key goes
#      into Config/Sparkle.xcconfig.
#   2. Developer ID identity exported as .p12 into a temp dir (random password).
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
print -r -- "// Public EdDSA key for Sparkle update verification. Written by scripts/setup-release-secrets.sh.
SPARKLE_PUBLIC_ED_KEY = $public_key" > Config/Sparkle.xcconfig
echo "Öffentlicher Sparkle-Schlüssel in Config/Sparkle.xcconfig eingetragen."

"$sparkle_bin/generate_keys" -x "$tmp/sparkle.key" >/dev/null
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" < "$tmp/sparkle.key"

# --- 2. Developer ID --------------------------------------------------------------------
# `security export` cannot pick a single identity; every identity in the keychain is included.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "Keine Developer-ID-Application-Identität im Schlüsselbund." >&2
  exit 1
fi
p12_password=$(openssl rand -base64 24)
security export -t identities -f pkcs12 -P "$p12_password" -o "$tmp/identity.p12" >/dev/null
base64 -i "$tmp/identity.p12" | tr -d '\n' | gh secret set DEVELOPER_ID_P12_BASE64 --repo "$repo"
print -rn -- "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo"
unset p12_password

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
