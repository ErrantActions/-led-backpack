# LED Backpack for iOS

Independent SwiftUI + Core Bluetooth controller for compatible Bluetooth LED
backpacks. No vendor login, cloud database or account subscription is required.

## Requirements

- iOS 17 or later.
- A compatible backpack only for Bluetooth controls; phone display works
  offline without a backpack or account.
- Location, Bluetooth and notification permissions for the features you enable.
- Optional camera permission only when scanning a trusted-device adoption QR.

This is an experimental app. Background behavior and optional live features
depend on iOS permissions, system scheduling and device compatibility.
See the [packet protocol reference](Protocol.md) for integration details.

## Navigation and library

The app opens in **Library**. Four main tabs keep the common tasks separate:
**Library**, **Backpack**, **Create** and **Live**. Settings are available from
the Backpack gear or the Library filter menu. Password and compatibility fields
on the Backpack screen stay collapsed until requested.

The Aurora visual style uses a dark atmospheric canvas, mint/lavender/rose
accents, thin translucent cards, and artwork-first adaptive library tiles.
Library, Backpack, Create and Live use open scroll layouts rather than grouped
settings rows. System tabs/back navigation remain native, including the Duo
rail. Reduced Transparency uses opaque card surfaces; increased contrast
strengthens card edges, and library scopes stack at accessibility text sizes.
Decorative artwork is original, static and hidden from VoiceOver; connection
indicators and library badges reflect real state, not concept/demo values.

Library has **All / On iPhone / Cloud** scopes. **Discover GIFs** and Commons
are available without an account; preview a GIF and tap **Save to my library**
to keep it offline with its attribution, without opening an editor first.
The **+** menu imports images/GIFs or converts a video. Search is in the
navigation drawer; category/favorite filters are in the filter menu. Playlist
creation is a separate composer with slot selection instead of raw slot-ID
entry boxes.
Photo/file pickers are presented from the Library, not embedded in its menu.
One file picker routes images and videos to their respective editors; Photos
uses the current encoding to preserve GIF animation. The editor opens after
the picker closes, selections reset so the same asset can be imported again,
and loading or import failures are shown rather than silently ignored.

Private cloud and community submissions are separate actions. **Back up to
private cloud** opens private-cloud settings when unavailable, paused or locked.
**Submit to community review** requires explicit sharing/publication/AI-review
consent. Existing credits are preserved without a creator/license chooser.
There is no private-backup fallback through the community upload endpoint.

When protocol 1 is enabled by the actual server config and this device's user,
verified private cloud items appear in the same grid; known local/cloud pairs
appear once. Complete snapshot scans use up to 100 records per page and retain
grandfathered larger cloud libraries. The 100-item local capacity never permits
remote deletion. Removing local files, importing backups or signing out does
not erase cloud records. Associations remain account/server scoped and omitted
from local backups. Legacy cloud associations are linked by identity, not by
assuming old canonical GIF bytes equal pre-canonicalization local imports.
Legacy private reads are not described as user-held encrypted storage.

### Private cloud protocol 1: source integration

The implementation is capability-gated, not a deployment or runtime-validation
claim. Without `cloudLibraryEncryptionEnabled`, private uploads and vault
enrollment remain unavailable. Optional enrollment/adoption also require their
individual config and state flags. Public browsing, email/Apple account auth,
offline saving and Bluetooth remain independent.

- Server-managed is the default. User-held enrollment requires a **separate**
  confirmed recovery passphrase; it never reuses or transmits an account
  password. NFC UTF-8 preserves spaces; PBKDF2-HMAC-SHA256 uses 600,000
  iterations, a random 16-byte salt and a 32-byte wrapping key.
- AES-256-GCM combines nonce12/ciphertext/tag16 with exact protocol AAD.
  New private metadata hashes the exact original GIF bytes using canonical
  unpadded base64url SHA256. Unknown legacy metadata/hash formats are preserved,
  not trusted as new integrity/dedup evidence. Managed plaintext is **not**
  compared with the backend's stored-ciphertext hashes.
- User-held writes, deletes, wrapper changes, migrations and device adoption
  use DEK-derived Ed25519 possession proofs. Proof messages and migration
  manifests are independently reconstructed before signing. Migration verifies
  every staged plaintext against its captured source before atomic commit;
  pending migrations can resume/cancel. Historical server-readable backups
  require retention/expiration and cannot be promised retroactively secret.
- Device sync off pauses private synchronization only. Separately confirmed
  `DELETE CLOUD` requires fresh server login and retains local/community/account
  data. Remote reset/disable/generation changes pause synchronization; known
  user-held state rejects an unexpected managed downgrade. Old-generation,
  deleted and foreign-account copies need explicit independent-copy approval,
  never automatic re-upload.
- iOS 17 uses recovery passwords. iOS 18+ optional PRF passkeys are local
  encryption-unlock ceremonies with fresh random challenges, actual credential
  and provider checks, and password-only fallback. Association configuration
  alone is not PRF proof. No PRF output or password is persisted.
- Same-account QR adoption uses a public-only short-lived QR and explicitly
  approved P-256 HPKE, binding recipient/challenge/full encrypted box. Typed
  crypto helpers do not export raw vault keys to UI/network code. The key cache
  is origin/account/key-ID scoped, WhenUnlockedThisDeviceOnly.

Before any future signed build, the owner must enable **Associated Domains**
for the App ID, regenerate the applicable profile, and configure the server's
AASA `webcredentials` association for the real team/bundle ID and
`led.errantactions.com` RP. The source entitlement and camera purpose string
are prepared; no portal/profile/key changes are performed by this integration.
Before enabling vault flags, approved Mac compilation/XCTest plus real-device
Keychain, camera, provider-specific PRF and cross-runtime HPKE tests remain
required. App Attest policy is separate from vault/PRF; the later native integrity
checkpoint below does not activate that policy or validate Apple device proofs.

Local Windows source-only checks (the repository intentionally ignores this
local `ios/Tools` directory):
`node ios/Tools/validate.mjs` and `node ios/Tools/validate-cloud.mjs`.
The latter independently checks public fixture bytes with Node/OpenSSL; it
does not execute Swift/XCTest or establish CryptoKit HPKE interoperability.

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
| Frame-based pixel drawing, brush/eraser/eyedropper and animation timeline | [PixelAnimation.swift](LEDBackpack/PixelAnimation.swift), [PixelAnimationStudio.swift](LEDBackpack/PixelAnimationStudio.swift) |
| Live UI, settings/export | [StudioAndSettings.swift](LEDBackpack/StudioAndSettings.swift) |
| Saved-slot thumbnails, scoped erase-all and playback provenance | [BackpackStorage.swift](LEDBackpack/BackpackStorage.swift), [BackpackStorageViews.swift](LEDBackpack/BackpackStorageViews.swift) |
| Device-bound batch send queue and bounded GIF fitting | [BatchTransfers.swift](LEDBackpack/BatchTransfers.swift), [BatchTransferViews.swift](LEDBackpack/BatchTransferViews.swift) |
| Coalesced live drawing and scoped playback restoration | [DrawingLivePreview.swift](LEDBackpack/DrawingLivePreview.swift) |
| Rendered animated text effects | [TextArtworkEffects.swift](LEDBackpack/TextArtworkEffects.swift) |
| Account block list and confirmed unblocking | [CommunityBlocks.swift](LEDBackpack/CommunityBlocks.swift) |
| Independent phone-only playback, local snapshots and reversible keep-awake | [PhoneDisplay.swift](LEDBackpack/PhoneDisplay.swift), [PhoneDisplayViews.swift](LEDBackpack/PhoneDisplayViews.swift) |
| Capability-gated social/avatar and event/RSVP/organizer source foundation | [CommunityFeatures.swift](LEDBackpack/CommunityFeatures.swift), [CommunitySocialViews.swift](LEDBackpack/CommunitySocialViews.swift), [CommunityEvents.swift](LEDBackpack/CommunityEvents.swift), [CommunityEventViews.swift](LEDBackpack/CommunityEventViews.swift) |
| Apple Maps organizer fixed-geometry planner and scoped artwork references | [OrganizerMap.swift](LEDBackpack/OrganizerMap.swift), [EventRouteDraft.swift](LEDBackpack/EventRouteDraft.swift), [EventRouteClient.swift](LEDBackpack/EventRouteClient.swift), [EventRoutePlannerStore.swift](LEDBackpack/EventRoutePlannerStore.swift), [EventRoutePlannerView.swift](LEDBackpack/EventRoutePlannerView.swift), [RouteArtworkPicker.swift](LEDBackpack/RouteArtworkPicker.swift) |
| Live themes, animated ink, numeric gauges | [LiveTheme.swift](LEDBackpack/LiveTheme.swift), [LiveInk.swift](LEDBackpack/LiveInk.swift) |
| Theme editor and saved presets | [ThemeEditor.swift](LEDBackpack/ThemeEditor.swift) |
| Background removal, touch-up, frame direction/timing, Vision cutout | [GIFStudio.swift](LEDBackpack/GIFStudio.swift), [GIFEditor.swift](LEDBackpack/GIFEditor.swift) |
| Foreground timed playlists and shared expected-output monitor | [PlaylistRunner.swift](LEDBackpack/PlaylistRunner.swift), [PlaybackViews.swift](LEDBackpack/PlaybackViews.swift) |
| One-tap scenes, theme snapshots and playlist presets | [Scenes.swift](LEDBackpack/Scenes.swift) |
| Category browsing, animated thumbnails and full GIF previews | [GIFCatalog.swift](LEDBackpack/GIFCatalog.swift), [GIFPreviews.swift](LEDBackpack/GIFPreviews.swift) |
| Local category/favorite controls and preview rows | [MediaLibraryViews.swift](LEDBackpack/MediaLibraryViews.swift) |
| Crisp pixel text, measured layout and text-to-GIF controls | [TextArtwork.swift](LEDBackpack/TextArtwork.swift), [TextArtworkStudio.swift](LEDBackpack/TextArtworkStudio.swift) |
| Optional community catalog, HTTPS client and account deletion | [CommunityClient.swift](LEDBackpack/CommunityClient.swift), [CommunityAccounts.swift](LEDBackpack/CommunityAccounts.swift), [CommunityGallery.swift](LEDBackpack/CommunityGallery.swift) |
| Native admin dashboard, moderation, accounts, reports and ZIP imports | [CommunityAdmin.swift](LEDBackpack/CommunityAdmin.swift), [CommunityAdminViews.swift](LEDBackpack/CommunityAdminViews.swift) |

### Optional community catalog and accounts

The default catalog is **https://led.errantactions.com**. Override it under
**Settings > Community > Catalog server and account**, or clear the address to
disable the optional service. Existing custom URLs are preserved.
Use a valid trusted TLS certificate; insecure HTTP,
embedded credentials, cross-origin media and redirects are not accepted.
An address on your local network may require iOS local-network permission.
There is no embedded API secret.

**Library > Discover GIFs** supports guest browsing, category/name
search, previews, local imports and signed-in likes/reports/uploader blocking.
Credits, license information and original-work download restrictions remain
attached to imported artwork. The connected panel's prepared variant is used
when available, otherwise the default is 64x64. Upload and moderation tools
are separate: **Library > Actions > Submit to community review** requires
explicit sharing/publication/AI-review consent, then sends
`X-Catalog-Upload-Policy: community-review`. The server can publish approved
submissions; this endpoint is never private backup. **Account > My community
uploads** also supports explicitly submitting legacy private items for review.
Deleting an account removes **all** GIFs contributed by
that account, including approved shared GIFs. Other users' independent copies
and contributions are unaffected.
My community uploads shows legacy private/shared visibility and moderation status.
Only admins can delete individual community GIFs; protocol-1 private cloud
has its own owner-only deletion/proof flow. Legacy moderators have ordinary-user
permissions. Server deletion never erases local files.
Admins can open **Catalog account > Administration** in the native app.
It uses the same pinned HTTPS bearer session, never credentials in browser links.
Ordinary users and legacy moderators cannot enter; every request is independently
authorized by the backend. The page provides on-demand statistics, paginated
account search/promotion/enable/disable/reporter trust, shared-GIF moderation and
AI retry/deletion, report resolution, report-hold settings and Apple diagnostics,
plus explicit-consent ZIP community imports and owner-only import reports.
Account changes, moderation, deletion and settings changes require confirmation.
Own/existing-admin account protections and promotion eligibility remain enforced.
Private artwork is excluded: counts are not permission to browse private media.
Account/server changes discard in-flight responses; denied access clears admin
data. ZIP requests stream a protected temporary multipart file rather than
loading a 250 MiB archive into memory; the temporary file is removed after upload.
Interrupted uploads must be checked in Recent imports before retrying.
Bulk deletion/quarantine and host/key/service configuration are not exposed:
their production API/authorization contracts are not part of this native scope.
Native admin mock tests are prepared, not executed; no iOS build/CI or live admin
mutation has been performed for this source change.

Community sharing accepts GIFs with 1-120 frames, at most 5 MB and
40 million decoded pixels. Single-frame text/drawings are uploaded unchanged,
without duplicating frames, and remain usable locally. Older servers may reject
one-frame uploads until their single-frame support is deployed; the app surfaces
that rejection without retrying with artificial duplicate frames.
Download permission is not redistribution permission: keep imported attribution,
do not mislabel others' work as original, and confirm the right to publish.
If an upload connection fails after sending, check My uploads before retrying.

The deployed server declares `accountDeletionRetainsSharedGifs:false`, so native
signup is available with accessible in-app deletion. Signup is disabled if a
configured server instead declares retention or omits that policy. Signup also
follows the server's email-confirmation setting; immediate signup does not make
an unconfirmed email verified. This is not a claim of App Store approval.
Sessions are scoped to that server and stored only in device-local Keychain,
not diagnostics, ordinary preferences or library backups.

**Continue with Apple** appears only when the server enables Apple auth and
declares a compatible deletion policy. A fresh five-minute server challenge
supplies the nonce; the app hashes its UTF-8 string exactly once for Apple's
request and sends the original nonce with the returned identity token/code.
Email matches are never silently merged: sign in with the existing password
and explicitly **Link Sign in with Apple** when needed. Apple-only accounts
can freshly authorize deletion through Apple instead of entering a nonexistent
password. Apple credential revocation is checked on return to the foreground.
The app never contains an Apple server signing key or client secret.

The Account screen includes permanent account deletion with password
reauthentication and explicit `DELETE` confirmation. An accepted deletion
receipt is retained privately before sign-in credentials and cached account
identity are cleared. Pending cleanup status is checked without Authorization.
Failed or expired status checks never claim deletion completed. Receipts show
the historic retained-shared count when supplied (zero for new deletions under
the current all-contributions deletion policy). Server account
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
- Video import from Photos or Files, trimmed and converted locally to GIF.
- Animated previews, custom categories, favorite stars and local name/category
  search. Use an item's **Actions > Organize** menu to move it to a category.
  Categories/favorites are preserved in backups and do not rewrite GIF files.

Studio's text tools default to a crisp whole-pixel alphabet with auto-fitting,
whole-word wrapping and left/center/right alignment. Pixel type supports A-Z,
a-z, digits and all printable ASCII punctuation; system, rounded and monospaced fonts remain
available for other scripts. The preview updates as you edit. Scrolling GIFs
have adjustable frame duration and reject messages that cannot move smoothly
within the editor's frame limit; longer messages can use the live display.
Choose an exact LED letter size or open **Inspect every letter and size** to
save a physical-panel proof GIF. See the [letter-size guide](LED-TEXT.md).
The Animation picker adds Breathe, Reveal, Rainbow and Bounce. These are rendered
into GIF frames, never guessed firmware commands. Static text remains one frame;
new effects use 40 frames, existing scrolling retains its 120-frame bound.
Breathe changes brightness gradually rather than flashing on/off. Rainbow
cycles colors; Bounce may clip at the canvas edge. Preview before saving.

### Phone-only local display

**Library > Phone display** is a first-class local display target, available
without a backpack, Bluetooth connection, account, cloud or location permission.
Long-press a saved GIF > **Display on phone** is separate from **Send to backpack**;
opening/closing/changing phone artwork never writes a slot or stops hardware
playback. Library thumbnails remain artwork-only. The full-screen phone player
fits portrait/landscape geometry with a black background and crisp interpolation;
tap artwork to hide/show controls, pause/play, choose local library artwork or
open a PNG/JPEG/WebP still/GIF file. Brightness is not modified.
The launcher and player chrome reuse Aurora headings, mint/lavender/rose accents,
glass surfaces and primary buttons. Only the controls fade, respecting Reduce
Motion; no glow/filter/tint is applied to the full-screen artwork itself.

Sources are bounded to 5 MB, 4096px and 1–1200 frames. Selected files are read
through a bounded stream with a file-size-change check; a growing file cannot
bypass the input allocation limit. Decoding uses a
larger 32 MB nominal decoded-pixel budget / 40 MB actual-cost limit, scaling
large/long sources rather than retaining unbounded full-resolution frames.
Single frames stay still. Defined GIF centisecond delays and repeat metadata
are retained; zero repeats means continuous playback, absent repeat metadata
plays once, and positive Netscape repeat counts add repeats after the first
cycle. Finite animations stop on their last frame and Play restarts them.

Playhead uses a monotonic clock and freezes offscreen/inactive instead of
jumping ahead. Artwork replacement/restoration is foreground-only. Decoded
frames are released when not viewing; retained original
local bytes support resume. Reduced Motion initially shows a still; explicit
Play permits animation. **Keep screen awake** is opt-in (also useful for stills)
only while the foreground phone display is visible, and restores the previous
idle-timer setting on background, picker entry, exit or disabling it. No screen
brightness writes, background playback task, account/network request or BLE
packet is needed. Opened files are not edited or automatically added to Library.

`PhoneDisplaySnapshot` is an internal, self-contained Codable local checkpoint:
original bytes/source ID, elapsed phase, play intent, explicit motion override
and keep-awake preference. Restore validates before replacing the current
artwork, so failed loads do not lose the original. This is not a swap wire
protocol, automatic persistence, a crash-recovery journal or a received-art
collection. Future automatic GIF Swap must implement/prove those separately;
phone snapshots do not contain or require a peripheral/slot.

See [native TODO](TODO.md). Focused tests are prepared, not executed; native
compilation/XCTest, real-device timing/lifecycle/idle-timer and orientation/
accessibility review remain outstanding. No builds/CI/live operations ran.

### Friends, avatars and events: source foundation

The separate frozen `e64affb` event-image replacement source is under organizer
tools. It replaces only a selected existing image: metadata first, captured asset
revision and entire displayed gallery order, PNG/JPEG/WebP still bytes within
5 MB/8192px/40M decoded pixels, explicit permission and retained descriptions/file.
Refresh/conflict cannot rebase a captured draft. A new immutable ID/URL is verified
in the same order/cover position with public approval reset; acknowledged requests
are verified rather than repeated. Explicit Cancel discards/reloads. Current
organizer access and `canReorder` are required, never global admin privilege.
There is no invented replacement flag or production-route assertion. This bounded
slice awaits its separate Mac checkpoint; physical/deployment tests remain separate.

Account links appear only when the actual server config explicitly advertises
`socialEnabled`, `avatarsEnabled` or `eventsEnabled`. Missing/false flags are
unavailable. Source implementation does not prove deployment, native compilation
or Apple/device validation. Existing guest catalog/offline/BLE/private-vault
behavior is independent. That initial foundation did not invent an App Attest
HTTP contract. The later HTTP-v1 native checkpoint uses the subsequently frozen
contract and remains distinct from enforcement/device/provider activation.

Friends/profile supports source-defined profile preferences, paginated friends
and incoming/outgoing requests, explicit acceptance/decline, removal/blocking,
single-use 15-minute invite creation/sharing/redeeming/revocation, and directional
future-location-feature consent. Profile/consent controls do not enable GPS,
nearby scanning or live people maps. Reciprocal requests do not auto-accept.
Invite tokens stay in memory, are never logged or backed up, and clear on exit.
No messaging UI or E2EE/private-vault encryption claim is introduced.

Avatar upload requires explicit public-profile review consent. It accepts
bounded PNG/JPEG/WebP stills or 1–120-frame GIFs via metadata-first multipart.
Pending owner preview, rejected/null media, deletion and approved profile/friend
avatars are supported. API-root-relative avatar paths resolve only against the
configured catalog origin; same-origin absolute paths remain compatible.
Scheme-relative/foreign URLs, dot/encoded segments, queries and fragments are
rejected. Private profile reads retain the pinned bearer session; the narrower
source public-contributor policy never downgrades these authenticated reads.
Images use canonical authenticated same-origin routes,
5 MB network bounds and no cross-account cache. Animated avatars play only while
visible/active; Reduce Motion uses the static preview with explicit play.
Profile avatars are not a private-cloud media browser.

The AI-avatar slice uses frozen `bfdd5ef`/completed backend `6d4f56b`.
Uploads/retry require actual `avatarUploadsEnabled:true`,
`avatarApprovalMode:"ai"` and matching owner `uploadsEnabled/approvalMode`.
Absent flags on production `6bed90c` do not enable this workflow. Legacy owned
avatars may be read, but there is no manual-approval fallback for new writes.
Failed/pending screening exposes the owner error and explicit retry bound to
the displayed `expectedVersion`; no rebase/retry occurs automatically.
Upload metadata remains exactly `{"public":true}` per the frozen schema.
A preflight detects a changed displayed replacement version, but upload itself
has no server version-CAS field; only retry has a wire `expectedVersion`.

Approved mature-masked avatars may legitimately have null media URLs. Global
`allowMature` uses the existing owner preference endpoint. Renderers clear while
the setting is changing and invalidate their epoch afterward, without changing
vault/account session identity. All avatar surfaces retain authenticated,
canonical reads and `cache:false`; known URLs cannot be used as a mature filter
bypass. Server masking is authoritative for owners/admins too, and previously
downloaded copies cannot be recalled. Screening uncertainty is not proof every
frame is safe; private library/chat media are never screening inputs here.

Events support accessible/mine/invitations offset pagination, authorized detail,
explicit `going`/`declined` RSVP and capacity errors, and a server-time-anchored
countdown after going RSVP. The actual source keys are **`startsAtISO` and
`endsAtISO`**, plus ISO `serverTime` and `rsvpStatus`; no numeric-time or
`accepted`-RSVP DTO is guessed. Native `ContinuousClock` elapsed time includes
suspension and avoids wall-clock changes; parsed dates are cached rather than
reparsed each tick. Labels transition at start, +60 seconds, end and cancellation.
No ticking countdown is persisted.

Organizer tools create/edit/reschedule fixed venue details and private/public
visibility, invite/revoke, remove participants, add/remove co-organizers,
explicitly transfer ownership and cancel. Roles are event-scoped, never account
admin overrides. Revision-bearing writes use the captured `expectedRevision`;
409 conflicts preserve the unsaved draft and never auto-retry/overwrite it.
Background/countdown polling does not replace an open editor's state. Venue
coordinates are manually reviewed fixed geometry, never participant GPS.
Sharing a private link does not grant event access; revoking an invitation can
retain a going member's access, requiring separate participant removal.

Clients pin origin/account/revision before HTTP construction and after each
response. Stale confirmations/results are discarded and 401/403 clears private
view state. This foundation does not add unfinished notifications, progress,
event asset management, messaging or native calendar flows. The separate eligible
MapKit organizer slice below adds fixed planning and protected artwork references.
Focused mock/model tests are prepared, not executed; no native build/CI, live
social mutation or production activation was performed.

### Eligible Apple Maps organizer planning

The backend/API dependency is verified platform-v2/source **6bed90c**, not later
source-only private badges/gallery/chat work. This native slice is source work,
not an iOS compile, device-validation or deployment claim.

An event owner can open **Event > Plan venue route & checkpoints**. Event details
use a MapKit fixed-venue editor instead of numeric-coordinate entry. Place/address
search and tap/drag placement choose the venue; circle-edge taps and accessible
radius controls choose activation radius. Event type selection never invents a
route/GPS permission, and unchanged date controls preserve original ISO seconds
and milliseconds exactly. Dates use the settled ISO keys, not guessed aliases.

Planner maps/search require an explicit per-page opt-in before MapKit exists or
search starts. The app supplies no account token, event URL or participant
coordinates to Apple; normal viewport/place requests may contact Apple. There
is no `CLLocationManager`, user-location annotation, directions/routing request,
provider token setting or browser tile/canvas. The map is removed and place
search cancelled while inactive; turning imagery off retains the local draft.
Native planning requires actual `eventsEnabled`, explicit per-page Apple Maps/
search consent and current owner `canManageRoute`/revision/access guards.
`eventMapPlanningEnabled` describes web tile readiness only: false/missing or
changed web tile configuration never disables MapKit or discards its draft.
Native code never calls the web tile-config endpoint or asks for operator keys.

Start/intermediate/finish cards, draggable pins, named place results, circle
edges, radius steppers, intermediate/guide-point ordering, accessible nudge
buttons and fit-all edit fixed geometry. A straight guide can be explicitly
created from placed checkpoints; it is not navigation or a safe-route promise.
Publishing validates unique contiguous order and exactly one start first/finish
last, max 50 checkpoints, 200 guide points and 10 live event-defined finish
rewards. The latter is not the newer private-account badge collection.

Artwork uses named cards and separate namespaces: approved non-mature general
community `gifItemId`, or ready same-event `exclusiveGifId`, never both.
Protected choices require both actual exclusive capabilities and the event
`exclusiveArtworkReferences` setting, scoped authenticated previews and the
asset/event path context. Missing/withdrawn opaque references show unavailable,
must be cleared/replaced explicitly, and never fall back to community content.
No gallery upload/reordering, publication or private-vault operation is added.

Each draft captures the original revision immutably. Background checks only
update permission/conflict information, not draft fields. Saves preflight the
current owner/revision, then send `expectedRevision` unchanged. The returned plan
must match the normalized requested route, not merely return HTTP success.
409 preserves the draft: fetch/inspect the server plan, then explicitly discard
for the reviewed revision only. A second unseen revision requires another review.
No silent rebase/retry. Permission/404/account loss clears planning data.

Shared progress locks fixed identities/order/coordinates/radii/names/guide shape.
After a lock response, an explicit action restores captured fixed geometry while
keeping artwork/reward edits; no structural retry is made automatically.
Material review is displayed on going RSVP/countdowns, and going confirmation
carries the displayed `expectedParticipationRevision`. End/cancellation takes
precedence over review; withdrawal still works. Confirmation never shares
progress or enables GPS. Authorized participants can inspect a read-only fixed
plan before reconfirming; no attendee pins or progress-sharing control is added.

Aurora headers/glass cards/mint-lavender controls are reused. Existing phone
display, BLE/emulator, vault and community-upload behavior is preserved.
See [native TODO](TODO.md) for compile/device/visual gates. Targeted model/mock
tests passed on authorized unsigned Xcode 27.1 Mac CI (run `42138289158`).
That run compiled app/tests and executed 155 tests with zero failures and one
unsigned-host Keychain entitlement skip, including 16 MapKit, 11 phone and six
AI-avatar tests. Real signed-host/device/MapKit gesture/visual/provider checks
remain separate. Production settings, keys, models and signing/release remain
unchanged.

### Completed-contract messaging source

Frozen backend `bfdd5ef` supplies direct/group/event chat, separate private
organizer questions, private attachments and fixed pins. These source-only
features are unavailable on servers missing their actual capability flags;
production `6bed90c` is not assumed upgraded. Account > Messages separates
friends/recent questions from group/event-wide rooms. Event detail explicitly
opens/joins an eligible event-wide room; it never copies private questions or
auto-RSVPs. Group creation/invitation management uses named friends and captured
history choices/revisions, never account-admin bypass.

Send retains one exact serialized intent/ID for uncertain retries. Private
history uses paired direct cursors or room sequence/view-token invalidation;
account/access changes clear cached rows/drafts. Authorized SSE contains only
bounded hints, followed by current authorized reads; absent live support uses
labeled periodic refresh. Typing is optional, memory-only and carries no draft
text. Private image/GIF attachments are authenticated, context-bound unsent
drafts until explicit Send; deletion cannot recall saved recipient copies.

Fixed pins require explicit Apple Maps page consent and manual placement plus
chat Send. Receiving a card fetches no map imagery; opening its Apple Maps link
requires disclosure confirmation. No device GPS, route/navigation promise,
web tile dependency, AI input, private dedup or E2EE label is introduced.
Chat/pin source at `6c2883b` passed unsigned Mac CI `42140284682`: 168 tests,
zero failures and one unsigned Keychain skip, including thirteen chat fixtures.
Real gesture/visual/permission/transport-device checks remain separate.

Account > Private activity and Notification settings use the frozen owner-only
notification APIs and actual capabilities. Generic notices expose no private
message/venue/media previews and open current authorized feature reads, never a
reference interpreted as a route or peer ID. Settings capture revision/account
and preserve choices on conflict. Eight category/global/channel controls include
explicit default-off reviewed-event reminders; they do not auto-RSVP or collect
GPS. Apple push availability is not OS permission/registration/delivery, and an
unconfigured provider cannot become an enabled success. Six notification tests
passed with unsigned compilation in run `42141398919` at `f34c254`: 174 executed,
zero failures and the exact one unsigned Keychain skip. Proof-bound native APNs
and real Apple validation remain separate, not implied by these controls.

Account > Apple device alerts is a separate frozen `bfdd5ef` source slice. Actual
DeviceCheck calls reconstruct HTTP-v1 challenge bytes before attestation/assertion;
bearer/body/query, account/origin/key, expiry and bounds are checked. No native-looking
header alone is accepted. Device identity is the local acknowledged registration
scoped to the attestation key, not the first owned row or a caller's device ID.
Permission is explicit; token callbacks/foreground changes reconcile only an
acknowledged device with captured server revision. Lost acknowledgments fail closed
and require recovery. Remote notification `activity.id` is only an opaque input to
authenticated proof-bound destination resolution; payload route/type/reference is
not trusted. Local BLE disconnect notifications and independent phone display remain.

This slice passed unsigned Mac app/test compilation and eight codec/mock tests in
run `42144043428` at `d51512c`: 182 executed, zero failures and the one exact
unsigned Keychain skip. It does not verify Apple's cryptographic/device response.
Signed physical
App Attest, APNs capability/profile/provider environment, delivery, visual/lifecycle
and SDK validation remain unproven and are not provisioned/activated here. Guest
bootstrap/login, fresh-auth attestation recovery UI, immutable file-stream upload
hashing and authenticated SSE integrity remain integration blockers before any
enforcement activation. Ordinary authenticated in-memory requests use official
proofs when enforcement is advertised; unsupported targets fail rather than
downgrade. Production flags/keys/models/release stay unchanged.

Protected community GIF/event chat cards are a separate frozen `8697481` source
slice. Explicit current-chat pickers have 24-row paging and scoped authenticated
media, not catalog-wide/private-cloud/exclusive access. Private-event sharing binds
displayed event/participation revisions and never grants an invitation, RSVP or
progress/GPS. History hydrates current-viewer metadata, hides unavailable private
titles/venues/covers, shows changed plans, formats IANA event timezone and opens
the existing current-event review flow. Opaque direct/room tokens invalidate older
pages; visible cards reconcile every five seconds even with SSE. Normal message IDs
remain stable; mature preference transitions clear media/history/pickers immediately.
Exact retry intents retain references, never rebase to a changed event silently.
Unsigned Mac app/test compilation and all eight reference tests passed in
[42146109178](https://github.com/ErrantActions/-led-backpack/actions/runs/42146109178)
at `357cba1`: 190 executed, zero failures and the one exact unsigned Keychain
skip. Xcode 27.1/build `27A9275`, Swift 6.4, simulator SDK 27.1/iPhone Duo.
Failed access refresh hides reference metadata until reverified; media policy
is checked again after I/O. Production `6bed90c` lacks the new capability;
signed physical Apple/provider, transport/visual/lifecycle checks remain separate.

### Batch send queue

Long-press a library GIF and choose **Add to send queue**, or open **Library >
Send queue > Add local GIFs** to select several artwork tiles. The queue retains
up to 60 entries in schema-1 local storage/backups; repeated source IDs and
byte-identical independent files are allowed. This is not content deduplication.
Reorder entries with Edit and assign distinct destination slots. Automatic
assignment uses empty ordinary slots (2–59); reserved slots 0/1 require an
explicit selection. Review pins the device, dimensions and complete inventory.
Replacing occupied slots requires typing `OVERWRITE`; local/cloud files remain.

All GIFs are validated and fitted before the first destructive write. Already
matching GIFs stay byte-exact; resizing uses existing fit-to-panel rendering and
keeps one-frame GIFs single-frame. Prepared files are protected temporary files,
one asset is decoded at a time, and temporary files are cleaned up afterward.
The batch owns the BLE command pipeline so other operations cannot interleave.
Each successful upload is removed from the persistent pending queue. If
bookkeeping fails after a physical upload, the UI reports the partial result;
inspect the backpack before retrying. No automatic retry/resume/rollback exists.
Backgrounding or disconnecting stops the batch; incomplete slots may be partially
written. An optional final ordered loop runs autonomously on the backpack.

### Live drawing and blocked accounts

**Create > Pixel drawing > Preview drawing on backpack** streams the selected
frame without saving a program slot. Brush updates are coalesced at most every
150 ms instead of queued per touch. It preserves exact RGB colors, owns the live
display session, and writes a complete first frame (including black) rather
than assuming the device's live buffer is empty. Later frames use pixel deltas.
It attempts to restore captured stored playback on stop,
editor exit or background. It never restores an old device's program list to a
different device and does not automatically resume. Restoration failures are
explicit; an unknown/disconnected display is not reported as successfully reset.

**Catalog account > Blocked accounts** lists the current account's blocked
uploaders and provides confirmed unblocking through the documented authenticated
GET/DELETE block endpoints. Requests are origin/account bound; stale results
and confirmations cannot apply to a different account. Authentication failures
clear the list and show an error, never a fake empty-list success.

These four additions have focused model/mock tests prepared (not executed).
Local source/protocol/grammar checks do not replace Swift compilation, XCTest,
visual review or real transfer/live-preview/restoration tests. No native build,
CI, live BLE transfer or account mutation was run to validate this source change.

Imported source limits are 10 MB, 120 frames, and 4096x4096 input dimensions.
Encoded/local GIFs are limited to 5 MB; supported render sizes are 16x16, 64x64
and 96x128. Backups have explicit size limits. Media conversion re-encodes
frames and can change palette/quality; verify previews and real playback.
Keep original media files: local backups cannot recover unknown artwork
already stored on the backpack.
App updates do not rewrite existing artwork. If an older saved GIF already
contains inverted text, re-create it instead of reusing the inverted export.

### Video to GIF

Choose **Library > Convert video from Photos** or **Convert video file to GIF**.
Set the start/length, 2-20 FPS, panel size and fit/fill framing. Convert to preview,
then save the new GIF locally before sending to a backpack or sharing it.
Video orientation is respected; audio is omitted. No source video is uploaded.

Video sources are limited to 256 MB, 8192x8192 and 24 hours. Select clips of at
most 12 seconds producing 2-120 frames; shorten the clip or reduce FPS if it
exceeds that limit. The resulting GIF must fit the existing 5 MB library limit.
Conversion has progress/cancellation and releases its temporary source copy
when the editor closes. Closing the editor never deletes the original video.

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
- Opt-in **Ghost trails > Reset canvas between GIF frames**, with an original
  preview for comparison. [GIFFrameDisposal.swift](LEDBackpack/GIFFrameDisposal.swift)
  walks GIF blocks and changes frame disposal on a temporary in-memory copy,
  retaining timings, transparency indexes, palettes and compressed image data.
  Missing controls are added without adding image frames. Baked-in outlines are
  different: use halo trimming, color cleanup or the manual eraser. Disposal
  reset can damage intentional delta-frame animations; preview before saving.

**Create > Pixel drawing** includes 1–120 independently editable frames, blank
and duplicate frames, earlier/later reordering, per-frame delays, brush sizes,
gap-free strokes, eraser, eyedropper, move/pinch zoom and 30-action undo/redo.
Animation preview and both save actions create new local GIF files. Sending
continues through Library with its existing slot/overwrite confirmation.
Single-frame drawings stay genuine single-frame GIFs.

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
Playlist editing supports repeated slot entries, drag reordering, removal,
adding occupied slots and paired per-entry timings. New playlists bind to the
backpack serial; legacy unbound playlists remain compatible. Playback validates
the current complete inventory and rejects empty/missing or wrong-device slots.
Bindings survive schema-1 local backups; no schema bump is required.

### Backpack slot browser and erase-all

The slot grid reads the complete 60-record device inventory and displays
identifier-matched local GIF previews when available. Tap for play, identifier
details and confirmed single-slot deletion. **Erase all backpack slots** requires
typing `ERASE ALL` and pins the confirmation to that device and inventory.
It sends the recovered, acknowledged per-slot deletion command, then verifies
all 60 records empty. On failure it reports partial progress and attempts an
inventory refresh; it never claims rollback or retries destructive writes.
This is not a factory reset: local/cloud artwork, password and settings remain.

### “Now on backpack” monitor

The dashboard includes a shared expected-output monitor:

- Live: the resolved last frame whose BLE writes were submitted successfully.
- Known GIF: local preview of a file uploaded through this app, matched to a
  panel/slot identifier association.
- Unknown stored artwork / autonomous loops: an explicit unavailable/reported
  index state, not a fabricated pixel image.
- While the connected dashboard is visible and active, poll reported playback
  every five seconds when no other operation owns the display; also allow a
  manual read. Legacy single-slot modes 0/1 can use a cached matching preview.
  Autonomous mode 2 exposes the ordered list, not an invented current phase.

The app cannot download existing stored GIFs or read the physical pixel output.
This is **not a camera feed or proof of the physical pixels**; GIF phase may
differ, and external changes can make metadata stale until refreshed. The
preview clears on disconnect. Slot associations and panel identifiers can be
included in explicit backups; review before sharing.

Recovered vendor `getStoredSlotContent` uses its in-memory `slotStore` and
persistent `peekSlot` cache, not a GIF-byte BLE download. Its delete-slots path
iterates the same per-program delete. Native feature/model tests cover these
constraints, copy-on-edit, frame limits and disposal bounds, but are **not run**
without an authorized Apple toolchain build; hardware erase/playback and visual
ghost-repair behavior still require device validation.

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
Both workflows use GitHub's documented `xcode-27` image and exactly Xcode 27.1,
rejecting an older-toolchain fallback. Native validation selects the iOS 27.1
iPhone Duo simulator and exports layout screenshots for review.
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

Library tiles show only the GIF: no visible names, metadata, badges or action
buttons. Tap to open artwork; touch and hold local artwork for editing, sending,
favorites, organization, export, cloud/community actions or its source/license.
Names remain searchable and accessible to VoiceOver; credits remain stored.
Search cards and saved library items autoplay bounded animated thumbnails,
including long animations without a still-poster fallback. Resolution scales
with frame count to bound decoded memory; variable frame timing is preserved
without duplicating decoded frames. Playback pauses offscreen or while the app
is inactive. Single-frame GIFs remain still. Thumbnails are cached in memory.
Full previews
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
