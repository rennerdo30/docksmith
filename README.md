# Docksmith

[![CI](https://github.com/rennerdo30/docksmith/actions/workflows/ci.yml/badge.svg)](https://github.com/rennerdo30/docksmith/actions/workflows/ci.yml) · [Documentation](https://rennerdo30.github.io/docksmith/)

Docksmith is an early, open-source macOS tool for inspecting connected Apple devices. The current Swift package contains a reusable `DocksmithCore` library and a **read-only** CLI probe. It uses Apple's separately installed `cfgutil` from Apple Configurator; Docksmith does not redistribute it.

Requires macOS 14 or later, Swift 6, and Apple Configurator. Connect the device, unlock it, and accept its trust prompt. Then run:

```sh
swift build
swift run docksmith devices
swift run docksmith probe --device 1
```

`devices` shows a transient number and device type for each connected device. Pass the chosen number to `probe`. The number can change when devices reconnect; check the list again before probing. You can pass `--cfgutil PATH` if the CLI cannot find your installation. The probe reports whether installed-app inventory and Home Screen layout were decoded, with counts and warnings. `inventory.count` is the decoded app count; `layout.count` is the Home Screen page count, excluding the Dock. It does not print raw identifiers, apps, or layouts, and it writes no local reports.

Finder's supported wireless setup begins with a cable: select the device in Finder, enable **Show this [device] when on Wi-Fi**, and click **Apply**. See [Apple's Finder Wi-Fi sync instructions](https://support.apple.com/en-is/guide/mac-help/mchlada1d602/mac). This does not establish that `cfgutil` device reads will work over Wi-Fi; Docksmith has not verified wireless probing.

Planned work includes a native macOS interface, deletion previews with explicit confirmation, and capability-gated Home Screen editing. None of those device-changing features are implemented here.

Run `swift test` for parser and selection checks. Do not include private device captures, pairing material, or inventory in issues or commits. Licensed under MIT.

CI tests and builds the CLI on native arm64 and x86_64 macOS runners without a connected device. Valid `vMAJOR.MINOR.PATCH` tags trigger unsigned, unnotarized CLI archives for both architectures plus SHA-256 checksums. Apple Configurator is a separate prerequisite and is not included in release archives.
