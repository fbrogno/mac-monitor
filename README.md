<p align="center">
  <img src="docs/images/banner.png" alt="MacMonitor" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-0b1020?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.2%20Toolchain-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/UI-SwiftUI-3cc8dc" alt="SwiftUI">
  <img src="https://img.shields.io/badge/Abh%C3%A4ngigkeiten-keine-34c759" alt="Keine Abhängigkeiten">
</p>

**MacMonitor** ist eine native Menüleisten-App für macOS. Sie misst CPU, Speicher, Swap, Temperatur,
SSD, Netzwerk-Durchsatz, Akku und Schlaf-Blockierer direkt über die Kernel-Schnittstellen und schickt eine **echte macOS-Mitteilung**, sobald
etwas auffällt: ein Prozess, der seit Minuten hängt, ein Speicherfresser, Speicherdruck oder Überhitzung.
Solange alles normal ist, bleibt sie still und braucht kaum Strom.

<p align="center">
  <img src="docs/images/popover-dark.png" alt="Popover mit Auffälligkeiten (dunkel)" width="380">
  &nbsp;
  <img src="docs/images/popover-light.png" alt="Popover mit Auffälligkeiten (hell)" width="380">
</p>

## Was die App meldet

| Regel | Standard-Auslöser | In der Mitteilung |
|---|---|---|
| Hängender Prozess | ein Prozess ≥ 90 % CPU über 3 min | Beenden …, 1 h stumm, Aktivitätsanzeige |
| Speicherfresser | ein Prozess belegt ≥ 25 % des RAM über 1 min | Beenden …, 1 h stumm |
| CPU dauerhaft hoch | Gesamt-CPU ≥ 90 % über 2 min | die größten Verbraucher |
| Speicherdruck | Warnstufe über 1 min · kritisch sofort | belegter RAM und Swap |
| Swap | ≥ 8 GB ausgelagert | |
| Überhitzung | thermischer Zustand „ernst“ oder „kritisch“ | größter Verbraucher |
| Festplatte voll | < 10 % oder < 15 GB frei | |
| Internet weg | 30 s offline, Meldung auch bei Wiederkehr | |
| Ruhezustand blockiert | ein Prozess verhindert im Akkubetrieb > 30 min den Schlaf | Beenden …, 1 h stumm |

Alle Schwellen, Dauern und Regeln lassen sich in den Einstellungen ändern. Prozesse kannst du dauerhaft
ignorieren oder direkt aus der Mitteilung für eine Stunde stummschalten.

### Hinweis auf dem Bildschirm, an dem du arbeitest

macOS zeigt Mitteilungs-Banner nur auf dem Hauptbildschirm. Wer an externen Monitoren arbeitet, sieht sie
nicht. MacMonitor blendet deshalb zusätzlich ein eigenes Hinweisfenster oben rechts auf dem Bildschirm
ein, auf dem gerade der Mauszeiger ist. Es nimmt keinen Fokus, verschwindet nach 12 s (kritisch 30 s)
und bietet dieselben Aktionen. Einstellbar: aus, nur an anderen Bildschirmen (Standard), immer.

<p align="center">
  <img src="docs/images/overlay.png" alt="Hinweisfenster von MacMonitor" width="420">
</p>

Testen: `open macmonitor://test` oder „Testmitteilung senden“ in den Einstellungen.

**Damit es nicht nervt:**

- **Dauer statt Momentaufnahme.** Eine Regel meldet erst, wenn der Zustand ununterbrochen anhält. Kurze
  Spitzen beim Kompilieren oder Öffnen einer App lösen nichts aus.
- **Einmal melden, dann Ruhe.** Danach kommt erst wieder eine Mitteilung, wenn es schlimmer wird oder
  als Erinnerung nach 30 min (einstellbar).
- **Hysterese.** Zum Abklingen muss ein Wert deutlich unter die Schwelle fallen (85 %). Werte, die um
  die Grenze pendeln, flackern so nicht zwischen „Warnung“ und „OK“.
- **Schlaf zählt nicht.** Nach dem Aufwachen beginnen alle laufenden Zeitfenster neu.

## Warum sie so wenig Strom braucht

Das Vorgänger-Plugin für SwiftBar startete bei jeder Messung `top`, `ps`, `awk`, `sed` und `python3`.
MacMonitor startet **keinen einzigen Hilfsprozess**. Gemessen auf einem MacBook Pro (M4 Pro), Popover
geschlossen: **0,12 s CPU-Zeit in 162 s (≈ 0,07 % CPU)** bei konstant ~79 MB Speicher.

- **Direkte Systemaufrufe:** `host_statistics` (CPU), `host_statistics64` (VM), `sysctl`
  (Swap, Speicherdruck, 64-Bit-Netzwerkzähler), `proc_pid_rusage` (CPU-Zeit und Footprint je Prozess),
  IOKit (Akku, Ladezyklen, Power-Assertions).
- **Adaptives Intervall:** 2 s bei offenem Popover, 10 s am Netzteil, 20 s im Akkubetrieb, 30 s im
  Stromsparmodus.
- **Gebündelte Weckungen:** Ein `DispatchSourceTimer` mit 25 % Toleranz lässt macOS die Messungen mit
  anderer Arbeit zusammenlegen.
- **Ereignisse statt Abfragen:** Speicherdruck, Temperatur, Netzwechsel, Stromquelle und Aufwachen
  lösen sofort eine Messung aus, ohne dass dafür häufiger gemessen werden muss.
- **Ruhige Menüleiste:** Jede Textänderung in der Menüleiste lässt macOS das Symbol auf jedem Bildschirm
  neu rendern (~40 ms). Standard ist deshalb „Nur Symbol“, das nur bei Warnungen wechselt. Wer CPU/RAM
  als Zahl sehen will, bekommt sie gedrosselt: neu gezeichnet wird erst ab 5 Punkten Änderung.
- **Caches:** Prozessnamen werden je PID nur einmal aufgelöst, SSD-Platz und Akkuzustand nur alle
  5 min gelesen, Schlaf-Blockierer jede Minute.

## Installation

Voraussetzung: macOS 15 oder neuer und Xcode (bzw. die Swift-6-Toolchain).

```bash
git clone https://github.com/fbrogno/mac-monitor.git
cd mac-monitor
./scripts/install.sh
```

Das Skript baut die App im Release-Modus, signiert sie, kopiert sie nach `/Applications` und startet sie.
Signiert wird mit der ersten „Apple Development“-Identität im Schlüsselbund, ohne eine solche ad hoc.
Beim ersten Start fragt macOS, ob MacMonitor Mitteilungen senden darf. Gleichzeitig trägt sich die
App als Anmeldeobjekt ein (abschaltbar in den Einstellungen).

## Entwicklung

```bash
swift build                 # Debug-Build
swift test                  # Tests für MonitorCore (Swift Testing)
./scripts/build-app.sh      # build/MacMonitor.app
./scripts/make-icon.sh      # Resources/AppIcon.icns aus AppIconView rendern
./scripts/render-docs.sh    # README-Bilder in docs/images neu rendern
```

Icon und Screenshots werden **aus Code gerendert** (`MacMonitor --render-docs <ordner>`): aus derselben
`AppIconView` und `PopoverView` wie in der App, mit festen Demodaten. Bilder und App können so nicht
auseinanderlaufen.

### Aufbau

```mermaid
flowchart LR
    subgraph App["MacMonitor (App)"]
        Model["AppModel<br/>Zeitplan · Event-Quellen"]
        Notifier["Notifier<br/>UNUserNotificationCenter"]
        UI["PopoverView · SettingsView<br/>MenuBarLabel"]
    end
    subgraph Core["MonitorCore (Library, getestet)"]
        Samplers["SystemSampler · ProcessSampler<br/>DiskSampler · PowerSampler"]
        Rules["Rules<br/>Snapshot → Conditions"]
        Engine["AlertEngine<br/>Dauer · Erinnerung · Abklingen"]
    end
    Samplers -->|SystemSnapshot| Model
    Model --> Rules --> Engine -->|AlertEvent| Notifier
    Model --> UI
```

| Ordner | Inhalt |
|---|---|
| `Sources/MonitorCore/Metrics` | Messung über Mach, sysctl, libproc, IOKit |
| `Sources/MonitorCore/Alerts` | Regeln (reine Funktionen), AlertEngine, Einstellungen |
| `Sources/MacMonitor` | App, Zeitplan, Mitteilungen, SwiftUI-Oberfläche, Doc-Renderer |
| `Tests/MonitorCoreTests` | Engine, Regeln, CPU-Deltas inkl. PID-Wiederverwendung |
| `docs/specs` | Design-Dokument |

## Grenzen

- Ohne Root-Rechte verweigert der Kernel `proc_pid_rusage` für Prozesse anderer Benutzer (z. B.
  root-Dienste). Diese erscheinen nicht in der Prozessliste. In Gesamt-CPU und Speicher sind sie
  trotzdem enthalten.
- Temperatur wird als thermischer Zustand von macOS gemeldet, nicht in Grad. Auf Apple Silicon gibt es
  keine öffentliche Schnittstelle für Sensorwerte.

## Lizenz

Privat. Alle Rechte vorbehalten.
