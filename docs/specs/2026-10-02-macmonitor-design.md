# MacMonitor — Design (2026-10-02)

## Ziel

Native macOS-Menüleisten-App, die dauerhaft und stromsparend läuft und echte macOS-Mitteilungen
schickt, sobald am Mac etwas auffällt. Ersetzt das SwiftBar-Plugin `macmonitor.15s.sh`, das pro
Durchlauf ~10 Prozesse (`top`, `ps`, `awk`, `sed`, `python3`) startet.

**Erfolg:** < 0,1 % CPU im Mittel bei geschlossenem Popover, keine Hilfsprozesse, Mitteilungen
kommen als „MacMonitor“ mit Aktions-Buttons an, startet beim Login.

## Architektur

```
MacMonitor.app (SwiftUI MenuBarExtra, LSUIElement, macOS 15+)
 ├─ AppModel        Zeitplan (adaptiv), Event-Quellen, verdrahtet alles
 ├─ Notifier        UNUserNotificationCenter, Aktionen „Beenden…“ / „1 h stumm“
 ├─ Views           Popover, Einstellungen, Menüleisten-Label
 └─ MonitorCore (Library, ohne UI, getestet)
     ├─ Metrics     SystemSampler (Mach/sysctl), ProcessSampler (libproc), Disk, Power
     ├─ Alerts      reine Regeln → Conditions; AlertEngine (Dauer, Hysterese, Erinnerung)
     └─ Support     RingBuffer, Formatierung
```

Messung ausschließlich über Kernel-Schnittstellen: `host_statistics` (CPU-Ticks),
`host_statistics64` (VM), `sysctl` (Swap, Speicherdruck), `proc_pid_rusage` (CPU-Zeit und
Footprint je Prozess), `ProcessInfo.thermalState`, `NWPathMonitor`, IOKit Power Sources.

## Stromsparen

- Intervall adaptiv: Popover offen 2 s · Netzteil 10 s · Akku 20 s · Stromsparmodus 30 s.
- `DispatchSourceTimer` mit 25 % Leeway → macOS kann Weckungen bündeln.
- Event-getrieben statt Polling, wo möglich: Speicherdruck, Thermik, Netz, Netzteil, Schlaf/Wach.
- Prozessnamen werden je PID gecacht; Disk nur alle 5 min.

## Regeln (Standardwerte, alle in den Einstellungen änderbar)

| Regel | Auslöser |
|---|---|
| Hängender Prozess | ≥ 90 % CPU über 3 min |
| Speicherfresser | Footprint ≥ 25 % des RAM über 1 min |
| CPU dauerhaft hoch | gesamt ≥ 90 % über 2 min |
| Speicherdruck | Warnstufe über 1 min, kritisch sofort |
| Swap | ≥ 8 GB und wachsend (≥ 1 GB in 10 min) oder bei Speicherdruck |
| Thermik | Zustand „ernst“ oder „kritisch“ |
| Festplatte | < 10 % oder < 15 GB frei |
| Netzwerk | offline ≥ 30 s (plus Meldung bei Wiederkehr) |
| Ruhezustand blockiert | Prozess hält im Akkubetrieb > 30 min eine Schlaf-Assertion |

Engine-Semantik: Eine Condition muss für ihre `sustain`-Dauer ununterbrochen aktiv sein, bevor sie
meldet. Danach meldet sie erst wieder nach dem Abklingen oder als Erinnerung nach 30 min.
Hysterese: Regeln nutzen beim Abklingen 85 % der Schwelle. Stummgeschaltete Prozesse und eine
Ignorierliste werden übersprungen.

## Grenzen

Ohne Root liefert `proc_pid_rusage` keine Werte für Prozesse anderer Benutzer (root-Dienste).
Die Gesamt-CPU und der Speicher werden trotzdem vollständig erfasst.

## Tests

Swift Testing für MonitorCore: Engine (sustain, Erinnerung, Abklingen), Regeln (Schwellen,
Hysterese, Ignorierliste), Prozess-CPU-Delta inkl. PID-Wiederverwendung, RingBuffer.
