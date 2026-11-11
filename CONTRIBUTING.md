# Contributing

Thanks for looking at MacMonitor. Bug reports, false alarms and small, focused pull requests are all welcome. For anything bigger than a fix, please open an issue first so we can agree on the approach before you spend time on it.

- Bug or false alarm: use the [issue templates](https://github.com/fbrogno/mac-monitor/issues/new/choose).
- Security problem: do not open a public issue, see [SECURITY.md](SECURITY.md).

## How the repository is laid out

| Path | What is in it |
|---|---|
| `Sources/MonitorCore` | The library without UI. `Metrics` (samplers for Mach, sysctl, libproc, IOKit, SMC), `Alerts` (built-in rules as pure functions, alert engine, settings), `Automation` (custom rules, actions, protected processes, quiet policy), `History` (SQLite store, retention, export), `Integration` (widget snapshot, mute state, status summary), `MenuBar`, `Support` |
| `Sources/WidgetViews` | SwiftUI views of the desktop widgets, shared by the widget extension and the screenshot renderer |
| `Sources/MacMonitor` | The app: schedule and event sources (`AppModel`), notifications, alert panel, SwiftUI popover, main window (monitor, history, tools, settings), Sparkle updater, Shortcuts (`Integration/Intents.swift`) |
| `Sources/MacMonitorWidgets` | The WidgetKit extension |
| `Tests/MonitorCoreTests` | Tests for `MonitorCore` (Swift Testing) |
| `project.yml`, `Config` | XcodeGen project of the app, public Sparkle key |
| `scripts`, `.github/workflows` | Build, release, CI |
| `docs` | Release guide ([docs/RELEASING.md](docs/RELEASING.md)), design notes, README images |

The rule of thumb: logic goes into `MonitorCore` as pure functions that take a snapshot and the current time and return a result. The app target only measures, shows and acts. Code in `MonitorCore` has tests; UI code usually does not.

## Build and test

You need macOS 15 or newer, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
swift build                 # library and UI target, without the Sparkle updater
swift test                  # tests for MonitorCore
SIGN_IDENTITY=- ./scripts/build-app.sh   # build/MacMonitor.app, ad-hoc signed
```

CI runs `swift test` and an ad-hoc app build on every pull request. Please run `swift test` yourself before you push.

Do not run `scripts/release.sh` or `scripts/setup-release-secrets.sh`. They sign and publish and need the maintainer's credentials.

## Style

- Follow the code around you. Small files, clear names, comments that explain why, not what.
- New rule or metric: add a test next to the existing ones in `Tests/MonitorCoreTests`. A rule is only done when the case "value missing" is covered. A Mac that does not report a value must never trigger an alert.
- Values a Mac does not report are hidden or shown as "not available", never as 0.
- Anything that ends or changes another process goes through the checks in `Automation/ActionSafety.swift`. Do not add a second path around them.
- No new dependencies without a discussion. Sparkle is the only one today.
- README and screenshots: the images in `docs/images` are rendered from the real views (`./scripts/render-docs.sh`). Do not edit them by hand.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`, for example `fix(core): ignore sleep blockers without a launcher`. Types in use: `feat`, `fix`, `perf`, `docs`, `build`, `ci`, `chore` (plus `refactor` and `test` where they fit). Scopes in use: `core`, `app`, `widgets`, `intents`, `release`, `build`. Write the subject in English or German, in the imperative, without a final period.

One pull request, one topic. Describe what changes for the user and how you checked it. Link the issue if there is one. A green CI run is required before merging.

## Reporting a false alarm

A false alarm is a bug, and a useful one. Use the "False alarm" template and include the rule, your Mac model, the macOS version and what MacMonitor said. If the rule is too eager for your use, say what you were doing at the time: the answer is often a better default, not a special case.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
