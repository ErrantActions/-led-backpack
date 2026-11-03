# LED Backpack for iOS

Independent SwiftUI + Core Bluetooth controller for stock Nyan-compatible
backpack firmware. No vendor login, cloud database, account subscription,
firmware flashing, or ESP32 is required by this implementation.

## Current status: source implementation, not a verified iPhone release

The selected feature surfaces are implemented in source, with packet-codec
tests, rendering/storage tests, and a GitHub macOS build/test workflow.
**Xcode compilation, signing, iPhone Bluetooth operation, and locked-screen
background behavior have not been verified from this Windows environment.**
Do not treat syntax checks or visual mockups as an iOS build.

The wire protocol was independently exercised on Windows against a 64x64
`EXYB-AS#GGMJXZ180` running `V2.9.1#V20`: identity, dimensions, all storage-slot
records, live bitmap animation and simulated speed worked. That does not
certify every command or the Core Bluetooth implementation on iOS.

See the [packet protocol summary](Protocol.md) and the committed Swift test
fixtures. This repository does not include vendor applications, extracted
vendor code, Windows analysis tools or personal device captures.

## Build on GitHub / a Mac

1. Clone the repository, retaining the relative `ios/` and
   `.github/workflows/` locations. Do not commit signing credentials,
   passwords or personal device captures.
2. Enable GitHub Actions and run **LED Backpack iOS**. The workflow:
   - Runs the pure Swift protocol package tests.
   - Installs XcodeGen and generates the Xcode project.
   - Selects an available iPhone simulator.
   - Builds/tests the SwiftUI app without signing.
   - Uploads the simulator app and test result bundle.
3. Address any compiler/test issues exposed by the first Mac run. No successful
   workflow result is being claimed before that run.

On a Mac:

```sh
cd ios
swift test --package-path Packages/BackpackProtocol
brew install xcodegen
xcodegen generate
open LEDBackpack.xcodeproj
```

In Xcode, choose your own unique bundle identifier and development team.
The generated project uses `com.errantactions.ledbackpack` and includes an original
LED-wave app icon. A simulator ZIP **cannot** be installed on an
iPhone: real-device development signing or a separately configured
Apple Developer/TestFlight distribution workflow is required.

The workflow does not contain signing keys, Apple account credentials, or
automatic App Store submission.

For signed internal beta distribution, follow [TestFlight setup](TESTFLIGHT.md).
The configured bundle ID is `com.errantactions.ledbackpack`; create that App ID
and App Store Connect record before configuring the protected upload workflow.

## Features and where they live

| Surface | Implementation |
|---|---|
| BLE scan/filter, discovery, notify, writes, reconnect, state restoration | [BluetoothLink.swift](LEDBackpack/BluetoothLink.swift) |
| Typed frames, checksums, field lengths, captured-layout parsers, commands | [Wire.swift](Packages/BackpackProtocol/Sources/BackpackProtocol/Wire.swift) |
| Identity/dimensions, slot inventory, controls, panel passwords, upload/playback | [PanelController.swift](LEDBackpack/PanelController.swift) |
| Local GIFs, attribution, playlists, backup/merge, Keychain passwords | [LocalLibrary.swift](LEDBackpack/LocalLibrary.swift) |
| Image/GIF decode, fit/fill, rotate, brightness, trimming, GIF encode, pixel diff | [MediaCodec.swift](LEDBackpack/MediaCodec.swift) |
| Searchable Commons GIFs, HTTPS bounded downloads, weather | [NetworkServices.swift](LEDBackpack/NetworkServices.swift) |
| GPS, display cap, optional slowdown indicator, music, weather, fun screens | [LiveEngine.swift](LEDBackpack/LiveEngine.swift) |
| Device, library, media editor, catalog search UI | [Views.swift](LEDBackpack/Views.swift) |
| Text/marquee, drawing/undo/redo, live UI, settings/export | [StudioAndSettings.swift](LEDBackpack/StudioAndSettings.swift) |
| Live themes, animated ink, numeric gauges | [LiveTheme.swift](LEDBackpack/LiveTheme.swift), [LiveInk.swift](LEDBackpack/LiveInk.swift) |
| Theme editor and saved presets | [ThemeEditor.swift](LEDBackpack/ThemeEditor.swift) |
| Background removal, touch-up, frame direction/timing, Vision cutout | [GIFStudio.swift](LEDBackpack/GIFStudio.swift), [GIFEditor.swift](LEDBackpack/GIFEditor.swift) |
| Foreground timed playlists and shared expected-output monitor | [PlaylistRunner.swift](LEDBackpack/PlaylistRunner.swift), [PlaybackViews.swift](LEDBackpack/PlaybackViews.swift) |

### Connection and controls

- Name/service-filtered scanning with an explicit show-all fallback.
- Both `FFF0/FFF2/FFF1` and `FF00/FF02/FF01` service families.
- Platform-reported write limits and WWR readiness; no Android MTU assumptions.
- Fragmented/coalesced notification assembly and checksum validation.
- Sequence-correlated status/NAK handling; timeouts are errors, not success.
- Optional existing panel password and legacy initialization.
- Brightness, panel power, rotation, password change/disable.
- Five bounded reconnect attempts with exponential backoff; no automatic
  resume of a live display after a restored connection.

Passwords are stored only when requested, in device-local Keychain entries.
They are excluded from JSON backups and outgoing authentication log entries.
The app does not implement cloud password recovery.

### Storage and media

- Reads all 60 physical storage records.
- Play a slot, delete a slot, play ordered local playlists.
- Explicit replacement confirmation before uploads; upload begins by deleting
  the target slot. There is no firmware-level backup of its old contents.
- ACK-gated 960-byte GIF transfer, progress, commit, and playback.
- Photos/file import, local animated-GIF preview, static-image conversion.
- Fit/fill, quarter-turn rotation, brightness and frame-range trimming.
- Text and horizontal marquee generation with system fonts.
- Pixel drawing, eraser, undo/redo, and local GIF saving.
- Local media/playlist backups merge with fresh file IDs and preserve credits.

Imported source limits are 10 MB, 120 frames, and 4096x4096 input dimensions.
Encoded/local GIFs are limited to 5 MB; supported render sizes are 16x16, 64x64
and 96x128. Backups have explicit size limits. Media conversion re-encodes
frames and can change palette/quality; verify previews and real playback.
Unusual GIF disposal/delta-frame behavior requires representative iOS tests.

Normal iOS software testing must precede destructive hardware operations.
Brightness/password/rotation/upload commands are based on recovered app
behavior, not a claim that every one has been verified on the user's device.

### Live screens

- GPS speed with explicit `NO GPS` on invalid/older-than-five-second data.
- User-configurable numeric speed cap in selected mph/km/h display units.
  The cap changes only the rendered value; raw GPS and slowdown detection
  retain uncapped measurements. Changing units retains the entered numeric
  cap; the settings UI tells the user to check it.
- Optional experimental GPS slowdown screen, off by default. Not a brake
  sensor or a replacement for required vehicle lights.
- Weather from Open-Meteo, with update age, stale indication and expiration.
- Supported system Music item metadata; **not universal Spotify/other-app
  access**. No music streaming or audio extraction.
- Phone motion/roll, phone heading, phone battery, clock, scrolling messages,
  blinking pixel eyes, and a “loading rider” screen.

Phone sensors measure the phone, not inherently the motorcycle. No valid
motorcycle lean estimate is claimed. Use the app while stationary, not while
operating a vehicle.

Live rendering uses previous/target RGB frames and a bounded per-frame palette,
sends changed-color bitmap bands with black last, and awaits platform write
completion without gating each bitmap on a protocol ACK. Observed NAKs and
disconnects stop the session. Begin/exit/restore use explicit ACK gating.
Stopping attempts to restore the captured program mode/list and re-queries it;
link loss can prevent restoration.

### Custom live displays

Each screen now has its own saved theme and named presets:

- Eight base ink/background colors, plus secondary ink.
- Continuous RGB morphing, rainbow sweep, moving stripes, checker and sparkle.
- Monospaced, rounded or system typefaces, relative size, alignment/layout.
- Editable labels above and below numbers/text.
- Optional secondary phone time or battery field.
- Still, marquee, floating or typewriter text with speed and refresh controls.
- Optional bar/arc gauges with explicit numeric minimum and maximum.

The speed gauge uses the **capped displayed speed**, not an uncapped hidden
measurement. Missing/stale data removes the gauge. Critical statuses such as
NO GPS and STALE override hidden/custom labels and disable distracting ink/text
animation for that status.

Text is first rasterized to a crisp foreground/background mask. Animated ink is
then applied to that mask using a bounded palette per frame. Morph colors are
preserved as exact RGB values in live deltas rather than thresholded back to
binary channel values. More patterns/colors can increase BLE work; chosen
refresh intervals are targets, not promised frame rates.

Eye graphics use palette/refresh settings and blink speed; text-specific
typography/layout controls apply to text-based screens. Themes/presets are
included in backups. Legacy library JSON without theme fields is supported.

### GIF cleanup, timing and non-live playback

GIF Studio works on **imported/local source media**, not unknown GIFs read out
of backpack flash. It provides:

- Global selected-color removal with RGB-distance tolerance.
- Edge-connected flood fill, using fitted image bounds so black letterboxing
  does not prevent background removal.
- One-pass dark-halo trimming and isolated-pixel cleanup.
- Manual brush/eraser for the current or selected frame range, stroke undo/reset.
- Optional on-device Vision foreground-instance masks per frame.
- Source/frame-range trimming, per-frame delay overrides and global speed.
- Forward, reverse and ping-pong order; endpoint frames aren't duplicated.
- GIF repeat metadata (zero means forever), edited-animation preview and
  saving as a new local copy with source attribution.

Removed/transparent pixels are flattened to **black for the LED panel**.
Vision subject masks depend on hardware/image support and can vary between
frames; unsupported detection is surfaced as an error, never a fake successful
cutout. Inspect every animation before sending. Manual edits are bounded to
200,000 pixel assignments and cannot be carried across an unacknowledged
geometry change; reset them before changing fit/rotation/size.

Timing has separate layers:

1. **GIF frame timing/repeat:** encoded into the local GIF and sent on upload.
2. **Autonomous backpack loop:** a slot list dispatched once, using timing
   already stored on the device. It can continue without an active app.
3. **Foreground timed sequence:** per-slot app durations (1...3600 seconds)
   and repeat. It stops/restores when backgrounded; iOS cannot guarantee
   arbitrary exact playlist timers while suspended.

Uploads optionally include a recovered program-dwell field. That field has
unit/vector coverage but **has not been verified on the user's iPhone/panel**.
Changing it requires the original media and an explicitly confirmed upload,
which replaces that slot. App playlist edits do not silently rewrite flash.

### “Now on backpack” monitor

The dashboard includes a shared expected-output monitor:

- Live: the resolved last frame whose BLE writes were submitted successfully.
- Known GIF: local preview of a file uploaded through this app, matched to a
  panel/slot/16-byte identifier association.
- Unknown stored artwork / autonomous loops: an explicit unavailable/reported
  index state, not a fabricated pixel image.

The device does not expose a recovered pixel stream or GIF/firmware readback.
This is **not a camera feed or proof of the physical pixels**; GIF phase may
differ, and external changes can make metadata stale until refreshed. The
preview clears on disconnect. Slot associations and panel identifiers can be
included in explicit backups; review before sharing.

### Modern UI and iPhone Duo

The native UI now uses a midnight/aurora visual system, larger live previews,
adaptive signal tiles, theme cards and system typography. Custom glass panels
use Apple's native Liquid Glass when compiled with an appropriate SDK and run
on iOS 26+; earlier systems use a material fallback. Reduce Transparency is
respected; theme preview animation respects Reduce Motion.

The expanded Live workspace and theme editor place controls beside a persistent
preview when available width permits. Compact windows stack those sections.
Selection/draft state lives above the geometry-dependent layout, and the BLE
session lives in the app model, not in a fold-specific view.

Apple says full native iPhone Duo adaptation requires the **iOS 27.1 SDK or
later**. The GitHub workflow uses `macos-latest` and has an optional
`require_duo_sdk` check that fails rather than claiming Duo qualification on
an older SDK. The minimum deployment target remains iOS 17.

No private hinge APIs, device-model guesses, or simultaneous independent
inner/outer-display control are claimed. This workspace also benefits other
wide windows; it is Duo-focused, not artificially hardware-locked.

- [Apple: preparing for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Apple: applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple: Vision foreground mask](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatescaledmaskforimage(forinstances:from:))

Native Duo pose/resize tests and iPhone rendering are still pending. On a
physical Duo, fold/unfold during preview, theme editing, an active connection,
and a live session; verify no reconnect, lost edits, clipped controls or layout
assumptions.

## Background GPS, weather, other live screens, and disconnect alerts

Declared background modes: `bluetooth-central` and `location`.

- **GPS:** start the live session in the foreground. Grant location access,
  enable Background GPS, and grant Always access for this app's background
  path. A location indicator is shown and automatic pauses are disabled for
  precise speed sessions. Restart after changing background preferences.
- **Weather:** meaningful coarse location updates and BLE events can wake
  the app. Refresh is opportunistic (normally every five minutes), not an
  exact perpetual timer. Data becomes marked stale after five minutes and
  unavailable after fifteen minutes.
- **Music/clock/fun screens:** animate while active; background refresh is
  opportunistic on allowed BLE/location/foreground callbacks. They do not
  start high-accuracy location just to keep unrelated animations alive.
- **Disconnect notification:** request user notification permission. An
  unexpected drop of an established connection schedules a local alert.
  Initial connection failures and intentional disconnects do not generate
  that alert. The connection also requests the OS's disconnection alert
  facility for suspended cases; OS presentation is not guaranteed.
- **State restoration:** Core Bluetooth can restore a connection after some
  OS-managed terminations. Status is re-read; live painting is not silently
  restarted. No claim is made about recovery after a user force-quit.

iOS does **not** grant unlimited background execution to these modes.
Suspension, force-quit, system termination, permissions, Focus settings, and
notification policy can delay or prevent updates/alerts. The app does not use
silent audio, fake location work, private APIs, or timers disguised as a
background service. Always test locked-screen behavior on a physical iPhone.

References:

- [Apple: Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple: background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple: requesting notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)

## GIF catalogs and licensing

The built-in searchable source is **Wikimedia Commons** through its public
Action API. Searches request GIF files and license metadata. Files with missing
license information or over 5 MB are omitted. Results need not be animated:
the editor shows their frame count.

Source page, author, license label and license URL are stored with imported
artwork and survive local backup/export of the library. Review the source
page before use; licenses can require credit and share-alike terms.
Exporting a GIF alone does not embed a license sidecar: retain/provide the
displayed attribution when sharing it. Edits do not erase attribution.

- [MediaWiki Imageinfo API](https://www.mediawiki.org/wiki/API:Imageinfo)
- [Commons reuse requirements](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia)
- [GIPHY API](https://developers.giphy.com/docs/api/) requires a separate key,
  production review and terms compliance. This app links to its website;
  it does not scrape or embed the API without authorization.
- [Tenor's current quickstart](https://developers.google.com/tenor/guides/quickstart)
  says new API clients are no longer accepted as of January 2026.

No third-party artwork is bundled in this source tree.

## Privacy and network behavior

- No application account or vendor backend.
- Bluetooth/logs are local; diagnostic exports are explicit and may contain
  panel identifiers. Review before sharing.
- Location is used only after starting a location-based feature.
- Weather sends coordinates to Open-Meteo when selected; no vendor tracking
  endpoint is involved.
- Commons search terms and downloads go to Wikimedia.
- Music metadata is rendered locally.
- No location history is persisted by this implementation.
- Stored files use protection compatible with operation after the first
  device unlock. Keychain items do not migrate to another device.

## Tests and verification

The protocol package tests consume fixtures generated by the existing
hardware-tested JavaScript codec. They cover frame/hash/upload parity,
captured dimensions, length variants, assembly/checksum failures, and speed
cap/stale-data behavior. App tests cover GIF round-trip, pixel-delta
reconstruction and backup/attribution behavior.

Fixtures are committed in the Swift test package; no Node or Windows parent
project is required. When changing the codec, update its vectors and add
corresponding Swift tests.

On this Windows machine, Swift sources were syntax-parsed, XML/fixtures were
checked, and existing Node tests can run. **Swift/XCTest and Xcode tests must
run on the Mac workflow; they have not run here.**

Physical-iPhone acceptance checklist:

1. Build on a Mac; inspect warnings and fix any platform-specific errors.
2. Install a signed build; confirm permissions and filtered discovery.
3. Read identity, dimensions, storage and playback without display writes.
4. Run a temporary simple live screen; stop and confirm restoration.
5. Test speed cap/stale GPS with controlled test data, not while riding.
6. Lock the phone during an authorized GPS session; check data freshness.
7. Interrupt power/link; verify alert, reconnect, and no unsolicited repaint.
8. Test notification denial, GPS denial and revoked background access.
9. Verify all storage controls on expendable artwork before valuable slots.
10. Test GIF timing/disposal, large media errors, backup restore, and rotation.

## Visual prototype

The [six-screen overview](Prototype/overview.png) and
[live-speed close-up](Prototype/live-speed.png) are browser-rendered mockups,
**not iOS simulator captures**. Their mock data/layout may differ after the
native build. Open [the HTML concept](Prototype/index.html) in a browser to
view the visual prototype; it has no connection to real backpack hardware.

The newer **Aurora** design replaces that initial grouped-list concept:
[phone overview](Prototype/overview-v2.png),
[expanded workspace](Prototype/duo-workspace.png),
[theme close-up](Prototype/theme-studio.png), and
[full design board](Prototype/aurora-design.png).
Prototype palette/font/size and compact/expanded controls are local visual
interactions only; they do not save native presets or send BLE commands.
