# Privacy

MacMonitor measures your Mac and keeps everything on your Mac. It has no account, no analytics, no crash reporter and no server of its own.

## What the app reads

CPU, memory, swap, GPU, temperatures, fans, power, battery, disks, network throughput, the list of running processes (name, CPU, memory, energy, disk activity) and the programs that keep the Mac awake. It reads these through macOS interfaces on your Mac. Processes of other users, for example root services, are not visible without root rights, and the app does not ask for them.

Network throughput is read from the interface counters. MacMonitor does not look at the content of your traffic and does not know which program talks to which server.

## What the app stores

| What | Where |
|---|---|
| Settings, custom rules, ignored processes | the app's preferences, `~/Library/Preferences/com.fbrogno.macmonitor.plist` |
| History (measurements, alerts, per-app rankings) | `~/Library/Application Support/MacMonitor/history.sqlite` |
| Current values for the widgets | `widget-snapshot.json` in the app group container `~/Library/Group Containers/<TeamID>.com.fbrogno.macmonitor` |

The history keeps minute values for 2 days, 15-minute values for 30 days and daily values for 2 years. Alerts are kept for 90 days, the per-app rankings for 30 days. You can export the history as CSV or JSON and delete all of it in the app (History, Report, or Settings, Data). Nothing in these files is sent anywhere.

The history contains process names, because the app ranks programs by their load. If you share an export, check it first.

## What leaves your Mac

One thing: the update check. MacMonitor uses [Sparkle](https://sparkle-project.org). It asks `github.com` for the file `releases/latest/download/appcast.xml` of this repository and, if a newer version exists, downloads the new DMG from the GitHub release. As with any request to a web server, GitHub sees your IP address and the app's version in the request. You can switch the automatic check off in Settings, Updates & Info. Without it, the app makes no network connection at all.

Two things you set up yourself can also reach the network:

- A custom rule with the action "Open URL" asks your browser or another app to open the address you typed. Local files and other risky schemes are refused.
- A custom rule with the action "Run Shortcut" runs a Shortcut of yours. What that Shortcut does is up to you.

## What the app does not do

- It does not send measurements, process names, settings or history to anyone.
- It does not collect identifiers and does not count installations.
- It does not read the content of your files. "Clean up SSD" only measures and deletes the cache folders listed in the app, after you confirm.
- It does not need Full Disk Access, Accessibility or Screen Recording permission. It asks only for permission to show notifications.

## Questions

Open an [issue](https://github.com/fbrogno/mac-monitor/issues/new/choose). Because the app is open source, you can check every statement above in the code.
