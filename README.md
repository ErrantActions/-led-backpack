# LED Backpack

Independent native iOS controller for compatible Bluetooth LED backpacks,
built with SwiftUI and Core Bluetooth.

![Aurora design prototype](ios/Prototype/overview-v2.png)

*Browser-rendered design mockup, not an iOS simulator screenshot.*

## What is included

- Backpack discovery, status, controls, storage slots and GIF uploads.
- Local image/GIF library, editing, background cleanup and animation timing.
- Text/drawing tools and license-aware Wikimedia Commons GIF search.
- Live GPS, weather, supported system Music metadata and optional fun screens.
- Custom live themes, animated ink, gauges and saved presets.
- A local expected-output monitor, not device pixel readback.
- Supported background GPS/BLE behavior and disconnect notifications.
- Local backups, Keychain passwords, diagnostics and Swift tests.

Only the iOS app, its tests/design assets, and the Mac build workflow are
published here. No vendor APK, extracted vendor code, Windows tools or personal
device captures are included.

## Build and test

See the [iOS guide](ios/README.md) for setup, source layout, limitations and the
physical-device acceptance checklist.

On a Mac:

```sh
cd ios
swift test --package-path Packages/BackpackProtocol
brew install xcodegen
xcodegen generate
open LEDBackpack.xcodeproj
```

The [GitHub Actions workflow](.github/workflows/ios.yml) builds/tests on macOS
and uploads an unsigned simulator app. Installing on an iPhone requires your
own Apple signing setup; a simulator ZIP cannot be installed on a phone.

## Status and important limits

This is an experimental source implementation, **not a verified iPhone
release**. Source syntax and protocol fixtures were checked on Windows;
consult GitHub Actions for actual Mac build/test results.

- Continuous arbitrary background timers are not guaranteed by iOS.
- Phone motion is not a validated motorcycle lean measurement.
- The output monitor shows expected/cached content, not physical pixel feedback.
- Uploading replaces the chosen backpack slot; unknown stored artwork cannot
  be backed up through a recovered readback command.
- Native iPhone Duo adaptation requires an appropriate iOS 27.1+ SDK and testing.

Use the controls while stationary. Experimental live screens are supplemental,
not replacements for required lights or vehicle instruments.
