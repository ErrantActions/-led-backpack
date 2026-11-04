# LED Backpack for iOS

Independent SwiftUI + Core Bluetooth controller for compatible Bluetooth LED
backpacks. No vendor login, cloud database or account subscription is required.

## Requirements

- iOS 17 or later.
- A compatible Bluetooth LED backpack.
- Location, Bluetooth and notification permissions for the features you enable.

This is an experimental app. Background behavior and optional live features
depend on iOS permissions, system scheduling and device compatibility.
See the [packet protocol reference](Protocol.md) for integration details.

## Build on GitHub / a Mac

1. Clone the repository, retaining the relative `ios/` and
   `.github/workflows/` locations. Do not commit signing credentials,
   passwords or private diagnostic exports.
2. Enable GitHub Actions and run **LED Backpack iOS** for an unsigned simulator
   build. The workflow generates the Xcode project and packages the app.

On a Mac:

```sh
cd ios
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
| Typed packets, checksums, reply parsing and commands | [Wire.swift](Packages/BackpackProtocol/Sources/BackpackProtocol/Wire.swift) |
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
| One-tap scenes, theme snapshots and playlist presets | [Scenes.swift](LEDBackpack/Scenes.swift) |
| Category browsing, animated thumbnails and full GIF previews | [GIFCatalog.swift](LEDBackpack/GIFCatalog.swift), [GIFPreviews.swift](LEDBackpack/GIFPreviews.swift) |
| Local category/favorite controls and preview rows | [MediaLibraryViews.swift](LEDBackpack/MediaLibraryViews.swift) |
| Crisp pixel text, measured layout and text-to-GIF controls | [TextArtwork.swift](LEDBackpack/TextArtwork.swift), [TextArtworkStudio.swift](LEDBackpack/TextArtworkStudio.swift) |
| Optional community catalog, HTTPS client and account deletion | [CommunityClient.swift](LEDBackpack/CommunityClient.swift), [CommunityAccounts.swift](LEDBackpack/CommunityAccounts.swift), [CommunityGallery.swift](LEDBackpack/CommunityGallery.swift) |

### Optional community catalog and accounts

The default catalog is **https://led.errantactions.com**. Override it under
**Settings > Community > Catalog server and account**, or clear the address to
disable the optional service. Existing custom URLs are preserved.
Use a valid trusted TLS certificate; insecure HTTP,
embedded credentials, cross-origin media and redirects are not accepted.
An address on your local network may require iOS local-network permission.
There is no embedded API secret.

**Library > Browse community catalog** supports guest browsing, category/name
search, previews, local imports and signed-in likes/reports/uploader blocking.
Credits, license information and original-work download restrictions remain
attached to imported artwork. The connected panel's prepared variant is used
when available, otherwise the default is 64x64. Upload and moderation tools
currently open in the web portal, which has its own sign-in; native bearer
credentials are never passed in links.

Native signup/signin follows the server's email-confirmation policy. A server
that permits immediate signup does not make an unconfirmed email verified.
Sessions are scoped to that server and stored only in device-local Keychain,
not diagnostics, ordinary preferences or library backups.

The Account screen includes permanent account deletion with password
reauthentication and explicit `DELETE` confirmation. An accepted deletion
receipt is retained privately before sign-in credentials and cached account
identity are cleared. Pending cleanup status is checked without Authorization.
Failed or expired status checks never claim deletion completed. Server account
deletion does not erase the iPhone's separate local library or backpack storage.

The server must implement the finalized v1 account-erasure contract. Deployment,
TLS and email delivery are operator responsibilities. The optional service does
not gate Bluetooth, offline media, Commons, scenes or animations by speed.

### One-tap scenes

Open **Backpack > Manage scenes** to save up to 50 named scenes. Each combines
brightness with either a live screen and its own saved theme/message, a stored
playlist loop, or a foreground timed sequence. The first three scenes appear
on the Backpack screen for quick access.

Scenes keep snapshots: editing a live theme or deleting a source playlist does
not silently change an existing scene. Playlist scenes bind to the backpack
used when saving them and require every referenced slot to remain occupied.
They do not upload, delete or overwrite artwork.

Applying a scene stops the previous live/timed session first. Permissions still
apply; a failed operation may leave brightness changed. Scene data is included
in local backups, with fresh scene IDs on import.

### Connection and controls

- Name/service-filtered scanning with an explicit show-all fallback.
- Connection status, explicit errors and optional existing panel passwords.
- Brightness, panel power, rotation, password change/disable.
- Five bounded reconnect attempts with exponential backoff; no automatic
  resume of a live display after a restored connection.

Passwords are stored only when requested, in device-local Keychain entries.
They are excluded from JSON backups and outgoing authentication log entries.
The app does not implement cloud password recovery.

### Storage and media

- Browse the backpack's stored artwork.
- Play a slot, delete a slot, play ordered local playlists.
- Explicit replacement confirmation before uploads; upload begins by deleting
  the target slot. There is no firmware-level backup of its old contents.
- GIF uploads with progress and playback controls.
- Photos/file import, local animated-GIF preview, static-image conversion.
- Fit/fill, quarter-turn rotation, brightness and frame-range trimming.
- Text and horizontal marquee generation with system fonts.
- Pixel drawing, eraser, undo/redo, and local GIF saving.
- Local media/playlist backups merge with fresh file IDs and preserve credits.
- Animated previews, custom categories, favorite stars and local name/category
  search. Use an item's **Actions > Organize** menu to move it to a category.
  Categories/favorites are preserved in backups and do not rewrite GIF files.

Studio's text tools default to a crisp whole-pixel alphabet with auto-fitting,
word wrapping and left/center/right alignment. Pixel type uses uppercase A-Z,
digits and basic punctuation; system, rounded and monospaced fonts remain
available for other scripts. The preview updates as you edit. Scrolling GIFs
have adjustable frame duration and reject messages that cannot move smoothly
within the editor's frame limit; longer messages can use the live display.

Imported source limits are 10 MB, 120 frames, and 4096x4096 input dimensions.
Encoded/local GIFs are limited to 5 MB; supported render sizes are 16x16, 64x64
and 96x128. Backups have explicit size limits. Media conversion re-encodes
frames and can change palette/quality; verify previews and real playback.
Keep original media files: local backups cannot recover unknown artwork
already stored on the backpack.
App updates do not rewrite existing artwork. If an older saved GIF already
contains inverted text, re-create it instead of reusing the inverted export.

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

Stopping a live session attempts to restore the previous playback program.
Connection loss can prevent restoration.

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

Complex effects can increase Bluetooth traffic; chosen refresh intervals are
targets, not promised frame rates.

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
Vision subject masks depend on platform/image support and can vary between
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

Changing stored playback timing requires the original media and an explicitly
confirmed upload, which replaces that slot. App playlist edits do not silently
rewrite stored artwork.

### “Now on backpack” monitor

The dashboard includes a shared expected-output monitor:

- Live: the resolved last frame whose BLE writes were submitted successfully.
- Known GIF: local preview of a file uploaded through this app, matched to a
  panel/slot identifier association.
- Unknown stored artwork / autonomous loops: an explicit unavailable/reported
  index state, not a fabricated pixel image.

The app cannot download existing stored GIFs or read the physical pixel output.
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

Full native iPhone Duo adaptation requires the **iOS 27.1 SDK or later**.
The minimum deployment target remains iOS 17.

No private hinge APIs, device-model guesses, or simultaneous independent
inner/outer-display control are claimed. This workspace also benefits other
wide windows; it is Duo-focused, not artificially hardware-locked.

- [Apple: preparing for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/)
- [Apple: applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Apple: Vision foreground mask](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatescaledmaskforimage(forinstances:from:))

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
background service.

References:

- [Apple: Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple: background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple: requesting notification permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)

## GIF catalogs and licensing

The built-in searchable source is **Wikimedia Commons** through its public
Action API. Browse Pixel art, Animals, Nature, Space, Patterns, Symbols or Retro,
or search across All. Searches use GIF MIME filtering and preserve relevance
order. More results can be loaded explicitly, up to 100 matches per search.
Files with missing
license information or over 5 MB are omitted. Results need not be animated:
the editor shows their frame count.

Search cards and saved library items show bounded animated thumbnails. Long
animations use a clearly labeled poster; tap to open the full animated preview.
Thumbnails are cached in memory and stop animating offscreen. Full previews
support up to 1200 frames, while importing into GIF Studio still requires no
more than 120 frames. Errors and unsupported files are shown explicitly.

Source page, author, license label and license URL are stored with imported
artwork and survive local backup/export of the library. Catalog titles become
the initial saved name, and the selected browse category is carried into the
editor. Review the source
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

- No vendor account or vendor backend is required. Optional community account
  information and catalog requests go to the server you configure.
- Bluetooth/logs are local; diagnostic exports are explicit and may contain
  panel identifiers. Review before sharing.
- Location is used only after starting a location-based feature.
- Weather sends coordinates to Open-Meteo when selected; no vendor tracking
  endpoint is involved.
- Commons search terms and downloads go to Wikimedia.
- Music metadata is rendered locally.
- Catalog sessions and account-deletion receipts stay in Keychain. No Bluetooth
  identity or GPS data is sent to the catalog by these features.
- No location history is persisted by this implementation.
- Stored files use protection compatible with operation after the first
  device unlock. Keychain items do not migrate to another device.

## Visual prototype

The [six-screen overview](Prototype/overview.png) and
[live-speed close-up](Prototype/live-speed.png) are browser-rendered mockups,
**not iOS simulator captures**. Their mock data/layout may differ after the
native build. Open [the HTML concept](Prototype/index.html) in a browser to
view the visual prototype; it does not control a device.

The newer **Aurora** design replaces that initial grouped-list concept:
[phone overview](Prototype/overview-v2.png),
[expanded workspace](Prototype/duo-workspace.png),
[theme close-up](Prototype/theme-studio.png), and
[full design board](Prototype/aurora-design.png).
Prototype palette/font/size and compact/expanded controls are local visual
interactions only; they do not save native presets or send BLE commands.
