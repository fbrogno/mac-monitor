# Security policy

## Supported versions

Security fixes go into the latest release. MacMonitor updates itself through Sparkle, so users get a fixed version without doing anything. Older versions are not patched.

## Reporting a vulnerability

Please do not open a public issue or pull request for a security problem.

Report it privately through GitHub: open the [Security tab of this repository](https://github.com/fbrogno/mac-monitor/security) and choose "Report a vulnerability" ([GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).

Please include:

- the MacMonitor version (Settings, Updates & Info) and your macOS version,
- what you found and what it allows an attacker to do,
- steps to reproduce, or a proof of concept if you have one.

You will get an answer as soon as the maintainer can read the report. This is a small open-source project without a paid security team, so please allow some days. If the report is confirmed, the fix is prepared privately, released, and the advisory is published with credit to you if you want it.

## What counts

Examples of what we want to hear about:

- a custom rule, URL command (`macmonitor://...`) or Shortcut action that can be abused to end the wrong process, open a local file or run code,
- a way around the protected-process list or the check that a process id still belongs to the same program,
- tampering with the update channel, the signature or the notarization,
- the history or widget file exposing data to other users or apps.

Not security problems: a rule that reports too early or too late (use the "False alarm" template), and information that macOS shows to any app of your user anyway.

## Releases

Releases are built in GitHub Actions, signed with a Developer ID certificate, notarized by Apple, and updates are signed with an EdDSA key that Sparkle verifies. See [docs/RELEASING.md](docs/RELEASING.md).
