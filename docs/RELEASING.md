# Release

Ein Tag `vX.Y.Z` löst in GitHub Actions den Release aus: bauen, mit Developer ID signieren, bei Apple
notarisieren, DMG und Sparkle-Appcast ans GitHub-Release hängen. Installierte Apps holen sich das Update
von `releases/latest/download/appcast.xml`.

## Ablauf

1. Version in der Datei `VERSION` erhöhen (z. B. `1.2.0`), committen, per PR nach `main`.
2. Auf `main` den Tag setzen und pushen: `git tag v$(cat VERSION) && git push origin v$(cat VERSION)`.
3. Der Workflow `Release` bricht ab, wenn Tag und `VERSION` nicht übereinstimmen. Sonst entstehen
   `MacMonitor-<Version>.dmg` und `appcast.xml` am Release, mit automatisch erzeugten Release-Notes.

Die Build-Nummer ist die Anzahl der Commits (`git rev-list --count HEAD`), Sparkle vergleicht sie.

Lokaler Probelauf ohne Apple-Server: `scripts/release.sh --skip-notarize`. Echter lokaler Lauf: zusätzlich
`NOTARY_PROFILE=<Schlüsselbund-Profil>` und `SPARKLE_USE_KEYCHAIN=1` setzen (Profil einmalig mit
`xcrun notarytool store-credentials`).

## Einmalige Einrichtung

Voraussetzungen: Developer-ID-Application-Zertifikat im Schlüsselbund, App-Store-Connect-API-Schlüssel
(`.p8`, Key-ID, Issuer-ID), `gh` angemeldet mit Schreibrecht auf das Repo.

```bash
./scripts/setup-release-secrets.sh
```

Das Skript legt das Sparkle-Schlüsselpaar an (privater Schlüssel bleibt im Schlüsselbund), trägt den
öffentlichen Schlüssel in `Config/Sparkle.xcconfig` ein und setzt diese Secrets im Repo:

| Secret | Inhalt |
|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | Zertifikat samt Schlüssel als .p12 (Base64) und dessen Zufallspasswort |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | App-Store-Connect-API-Schlüssel für `notarytool` |
| `SPARKLE_PRIVATE_KEY` | privater EdDSA-Schlüssel, signiert die Updates im Appcast |

Danach `Config/Sparkle.xcconfig` committen. Ohne öffentlichen Schlüssel bricht `release.sh` ab, denn eine
App ohne Schlüssel könnte keine Updates prüfen.

Der private Sparkle-Schlüssel darf nie verloren gehen: Ohne ihn lassen sich bestehende Installationen nicht
mehr aktualisieren. Sicherung per `generate_keys -x <Datei>` in einen Passwortmanager.

## Wie signiert wird

`scripts/build-app.sh` baut ohne Xcode-Signatur und signiert danach von innen nach außen, ohne `--deep`:
Sparkles XPC-Dienste, `Updater.app`, `Autoupdate`, das Framework, zuletzt die App, jeweils mit Hardened
Runtime und Zeitstempel. `release.sh` prüft das (`codesign --verify --deep --strict`, Developer-ID-Autorität,
Runtime-Flag, Zeitstempel für jede Komponente), baut die DMG (APFS, lzfse), signiert sie und notarisiert sie.
