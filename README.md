# Docksmith

[![CI](https://github.com/rennerdo30/docksmith/actions/workflows/ci.yml/badge.svg)](https://github.com/rennerdo30/docksmith/actions/workflows/ci.yml) · [Documentation](https://rennerdo30.github.io/docksmith/)

Docksmith is an open-source native macOS app for browsing connected Apple devices, reviewing installed apps, and arranging a Home Screen layout. It uses Apple's separately installed `cfgutil` from Apple Configurator; Docksmith does not redistribute it. The package also contains a reusable `DocksmithCore` library and a read-only `docksmith` CLI probe.

Requires macOS 14 or later and Apple Configurator. Connect and unlock a device, then accept its trust prompt. Download the `.app.zip` for your Mac's architecture from a tagged release, expand it, and open `Docksmith.app`. Release builds are currently unsigned and unnotarized. To build locally with Swift 6:

```sh
swift test
swift build -c release
scripts/bundle-app.sh release 0.1.0 1 dist
open dist/Docksmith.app
```

For development, `swift run DocksmithApp` starts the native UI. The app offers a named device picker, app search and removal review, and a Dock/page/folder layout editor with a separate apply review. App removal and layout changes require explicit confirmation in the UI. Before a layout write, Docksmith checks that the device's layout has not changed and saves a private original-layout backup under `~/Library/Application Support/Docksmith/Backups`. If a device response is partial or a layout contains unsupported entries, editing is limited. The app requests available app icons from the selected device; some icons may be unavailable.

The companion CLI remains read-only:

```sh
swift run docksmith devices
swift run docksmith probe --device 1
```

The device number is transient and can change after reconnection. CLI probe output omits identifiers, app records, and layout contents. `inventory.count` is the decoded app count; `layout.count` is the Home Screen page count excluding the Dock.

Finder's supported wireless setup begins with a cable: select the device in Finder, enable **Show this [device] when on Wi-Fi**, and click **Apply**. See [Apple's Finder Wi-Fi sync instructions](https://support.apple.com/en-is/guide/mac-help/mchlada1d602/mac). This does not establish that `cfgutil` reads or changes work over Wi-Fi; Docksmith has not verified wireless use.

CI builds and tests on native arm64 and x86_64 macOS runners without a connected device. Valid `vMAJOR.MINOR.PATCH` tags package an app archive and companion CLI archive for each architecture, with SHA-256 checksums. Do not include private device captures, pairing material, inventory, or layouts in issues or commits. Docksmith is licensed under MIT.
