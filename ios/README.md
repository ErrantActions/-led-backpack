# LED Backpack for iOS

### TestFlight 0.1.0 (11)

Source `191d8af` passed [full native validation](https://github.com/ErrantActions/-led-backpack/actions/runs/42577133898):
1,044 unit tests / 0 failures / 2 explicit skips, 14 UI tests / 0 failures,
and separate live public integration 1 / 0. Exact native inputs were promoted
as `fc4bcc2`. [Signed upload](https://github.com/ErrantActions/-led-backpack/actions/runs/42581582161)
archived, exported and uploaded build 11; signing cleanup succeeded.
Apple processing and internal tester availability are not verified.

This build includes the routing/paging corrections, connected-device reading
and registration, nickname-only editing, erase opt-in toggle and peer protocol
v2. The newer visual-editor redesign and found-device recovery messaging are
separate follow-up work, not features claimed shipped in this build.

### Current source: adoption and recovery redesign (not in build 11)

Backpack > My devices lists saved backpacks and checks an already-connected
backpack directly. There is no manual device entry or scan on page entry.
The check reads identity/dimensions and sends the ID privately to the configured
registry; only **Adopt this backpack** creates an association. Adoption re-reads
the connected device and uses its model/dimensions, with Rename available later.
An existing own record keeps its customization. Another account's association
cannot be taken over. Ambiguous IDs disclose no person.

This requires `connectedDeviceRegistrationVersion >= 2`, not just the old
registration flag. When the single registered account opted into finder contact,
the check can display its screen name and scoped avatar plus **I found your
device**. Finder contact defaults off per backpack; the owner's toggle is the
explicit choice, without an additional confirmation dialog.

**Found-device messages** is available from My devices and Messages when enabled.
Pending finders can send only their introduction. An owner's first reply accepts
the contextual conversation and sends the reply; it does not create friendship,
general messaging, device control, library or location access. Accepted
participants can reply later without a Bluetooth connection. History is bounded
to 100 messages and read in ascending order across at most two pages.
Retries retain the exact recipient, text and request UUID in device-only
Keychain. Drafts are account/server/conversation/peer scoped. Explicit delivery
errors, same-ID Retry and local Clear remain available; Clear is not a recall.
Close, account blocking and purpose-specific message reporting remain separate
controls. Recovery expires after 30 days and is revoked by server policy.

The friend-invite preview now has one **Send friend request** action with the
same exact inviter/token/expiry server recheck, rather than a second dialog.
Incident reports retain the entered explanation/consent form but no duplicate
submission dialog. Original private messages are not copied automatically.

Live uses the native iOS 27.1 arrangement container for wide or actively divided
windows, with independent preview/action and mode/preset scrolling surfaces.
The primary surface keeps mode selection, mode-specific notices and Start/Stop
even when the secondary surface is hidden. Current reserved regions determine
fold handling; there are no fixed hinge gaps. Compact windows and iOS 17 retain
the single-flow fallback, and operational/message state stays outside reflow.

Private cloud's sync toggle is its explicit opt-in, without a second same-purpose
dialog. Replacing a reset user-held library remains a separately named action;
ordinary enable cannot silently authorize that replacement. Encryption enrollment,
system authentication and destructive deletion retain their distinct boundaries.
Chat has a keyboard-safe composer with attachment/typing tools in Add, diagnostics
under Delivery details, automatic local outbox inspection and automatic archival
after a confirmed send. Uncertain replies retain visible same-ID retry/clear.
Stale delivery receipts cannot clear a newer pending message.

Backpack Scan now keeps a bounded explicit request while Bluetooth initializes,
instead of requiring a second tap. It waits at most 30 seconds for readiness and
an active app, then scans for 15 seconds. Stop, backgrounding, denial, power-off
and expiry cancel the request; returning later does not start a scan. Initial
system permission interruption can resume only that still-current request.
Opening the app, My devices or a discovery page creates no scan intent.

Native validation and deployment of this newer source are tracked in
[TODO](TODO.md). Do not infer live v2 availability or physical-device acceptance
from the build-11 upload.

### Peer protocol v2

Local pairing QR codes and phone swap/friend-play cryptographic domains now use
neutral LED protocol names. **Update both phones and exchange fresh pairing
codes.** Older peer protocol versions are explicitly rejected; there is no
fallback or mixed-version pairing. Existing original/recovery journals are
retained, and Stop/Restore remains available. This changes neither backpack
firmware commands nor account/cloud storage protocols.

### Erase backpack

Erase review uses an **Allow erase** toggle, off by default, instead of a typed
phrase. The destructive action still requires a connected, idle backpack and
the exact captured inventory/device. Confirmation resets on connection or slot
changes, backgrounding and dismissal. This erases stored programs, not a factory
reset; local/cloud GIFs and backpack credentials are retained.

### Connected backpack account association in build 11

Backpack > Add connected backpack to my account (also available from My devices)
requires sign-in and the server's `connectedDeviceRegistrationEnabled` capability.
Read is explicit: the app uses the existing password-bearing vendor identity read
(`0x0A`) and dimension read (`0x1B`), with no scan, display change or device write.
The vendor's 10-byte ID is case-sensitive and distinct from iOS's peripheral UUID.
Malformed IDs, uniform placeholders and the known `TLVDEFIDV5` default are rejected.

Review the private ID/model/firmware/dimensions, enter a nickname and explicitly
confirm physical access and account association. Save reads the device again.
A disconnect/reconnect, account change, backgrounding, withdrawn confirmation,
changed identity/dimensions or a reading aged 120 seconds requires reconfirmation.
IDs and passwords are not included in Bluetooth diagnostic identity messages.
Firmware is displayed locally, not submitted to the registration API.

`POST /devices/connected` saves a private **unverified association**, not ownership
or anti-clone proof. The ID is mutable and can be copied. The same account/ID
reuses its existing record without changing
customized labels, sharing, pending transfer or revision. New records have owner
sharing off. An uncertain receipt requires reloading My devices before deliberate
retry; the app does not automatically retry registration.
Manual device entry is not offered in the app. Only the nickname can be edited;
model and dimensions remain read-only. Legacy records and their generic API
remain compatible. Public owner cards and incoming transfers do not reveal the ID.
Accepting a label transfer removes its private connected-ID binding; the recipient
must explicitly read/register the backpack. Unlink does not alter hardware or GIFs.

Hardware acceptance still requires the owner's powered backpack. Verify that its
ID survives reconnect/reboot and matches on another phone; the simulator cannot
establish factory uniqueness, reset persistence, ownership or BLE security.
The requested version-2 registry lookup, adoption and opt-in owner recovery
conversation are still a separate native integration task. Do not treat a
service association as verified physical ownership.

### UX corrections included in build 11

Social's four primary buttons now use explicit distinct destinations instead of
multiple NavigationLinks competing inside one List row. Add Friends follows the
owner's rough three-action layout (look nearby, own QR, scan QR), with Find Me
showing actual armed findability and a separate default-off discovery permission
step. Opening the page does not activate Bluetooth, GPS or friendship.

Community, Commons, legacy owned-library rows, My Uploads, route artwork and
admin catalog/moderation lists use guarded near-end paging. Page/cursor identity,
one in-flight operation, account/filter/generation cancellation, stable-ID
upserts, preview invalidation, exhaustion and explicit error Retry are retained.
Local collections and the event's bounded full-order gallery do not invent
remote paging. Required inventory reconciliation for unified cloud sync remains
automatic.

Workflow end screens use shorter outcomes and expandable advanced controls.
The GIF editor keeps Cancel in a fixed bottom action area, independent of the
system toolbar's placement on Duo.
Required sharing consent, errors, destructive confirmation, Stop and Restore
remain available. Gallery definition conflicts retain local drafts; actual
role/access loss still clears them. The previously unreachable catalog settings
link was moved out of the backup button's action.

These changes are included in build 11, not build 10. Simulator captures are
source-matched debug-fixture evidence, not physical TestFlight device captures.

Independent SwiftUI + Core Bluetooth controller for compatible Bluetooth LED
backpacks. No vendor login, cloud database or account subscription is required.

### One owned library

Library no longer has All / On iPhone / Cloud storage scopes. After the existing
explicit cloud-sync consent, protocol 1 automatically uploads local imports,
copies, categories and favorites and downloads owned remote GIFs into the same
durable phone library. Remote version changes update an unchanged phone copy;
concurrent edits fail explicitly without overwriting either side. Linked artwork
appears once. Cached GIFs remain usable offline. Foreground sync retries every
30 seconds and after local changes; pause, unlock, reset and account boundaries
remain enforced. Storage limits and failures stay visible, not labeled synced.

Community and Commons remain discovery, not separate owned libraries. Removing
a local download still retains its cloud copy; sync does not silently infer
remote deletion from missing local files or re-upload foreign/reset associations.
Cloud-only deletion remains explicitly confirmed in sync settings.
Frozen source `0772fd9` passed full unsigned native validation in
[run42502718422](https://github.com/ErrantActions/-led-backpack/actions/runs/42502718422):
1011 native tests/0 failures/2 explicit skips, all7 UI regressions/0 failures,
and separate read-only public integration1/0. All18 synchronization fixtures
passed. Reviewed XCTest screenshots show one artwork collection without storage
scopes. Remote byte changes also invalidate Library, phone, queue and picker
previews while preserving artwork identity. Release `1ef59c3` was signed,
archived, exported and uploaded as **0.1.0 build10** in
[run42506053458](https://github.com/ErrantActions/-led-backpack/actions/runs/42506053458).
Signing cleanup passed. Apple processing and internal tester availability are
not verified; TestFlight9 does not include these changes.
The existing unsigned source workflow's `library` mode runs the cloud-sync,
library, vault/protocol/crypto and direct-cloud-send tests together with all
navigation UI regressions, followed by the separate read-only public integration.

### Clean LED interface overhaul - uploaded in TestFlight build10

The five tabs remain Library, Social, Backpack, Create and Live. Compact
artwork-first cards replace oversized introductions; restrained LED accents,
short action labels and expandable details reduce reading on entry screens.
Social keeps its actual capability/sign-in gates, rather than substituting a
second library. Library, phone playback and nearby games have direct routes.

Flows now show the relevant next action: prepare copies before explicitly
sending, review changed timing before saving a new copy, pair/compare before
color-game setup, and start or confirm a hunt according to its current state.
SOLO's scenes, daylight, badges, recaps and advanced geometry are expandable.
Consent, destructive confirmations, important sharing/safety warnings,
errors and original-recovery controls are not replaced with automatic approval.
No protocol, account, sensor, cloud-access or firmware permission is added.

UI regressions cover default-off games, guest capability gates, expanded scene
actions and timing invalidation/new-copy preservation. The existing unsigned
workflow now exports XCTest screenshots for visual review. Native compiler,
test counts and screenshot results are recorded above. These changes are
uploaded in TestFlight build10, not build9; tester/device acceptance remains
a separate checkpoint.

For UI-only fixture corrections, the existing unsigned source workflow has a
`ui` mode: compile, run all NavigationTests, run separate read-only public
integration, and export screenshots. It does not claim a full unit sweep;
unchanged app source can retain its separately recorded full-unit evidence.

### Unsigned private fixed-point capture follow-up - source only

SOLO area setup now offers a separately consented, foreground-only one-fix
capture or the existing offline numeric fallback. Permission preparation does
not enable sensing/PHONE automation. An already-authorized full-accuracy source
requests one fix, accepts only fresh≤5s/accuracy≤25m valid geometry, and times out
after10s without silent retry. Source cancellation/stop/background/permission
changes retire the continuation; request IDs prevent old timers/cancellation
from finishing a new capture.

The chosen point goes only into the visible private area draft. It neither
saves an area nor reports a visit/badge or publishes a route. Explicit Save
still validates local scene/bounds and reliable stopped configuration.
Draft cancellation/consent removal/background clears capture work; async
results cannot replace a closed/new draft. No maps, search, provider keys,
server coordinates or physical device operations are added.
Three new injected-source/quality/context/cold-consent fixtures passed at
df40e46 in run42452361645: actual app/test compile and98focused native
tests/0failures. This source is not in build9; physical capture/permission
acceptance remains unperformed.

A subsequent source follow-up checks the monotonic ten-second capture window
when accepting a fix and after awaiting the source, independently of delayed
timeout callbacks. Late/backwards completions cannot enter the draft.
The exact-boundary capture-window fixture passed atf43f6cc in run42453233273:
actual app/test compile and99focused native tests/0failures.
This remains an unsigned software fixture checkpoint, not real GPS capture/
permission/private-provider acceptance, a full release sweep or a new beta.

### Current released checkpoint: TestFlight0.1.0(9)

Committed source1944292 passed native compilation, portable9/0, priority96/0,
focused528/0, full964/0/2explicit skips, integrated UI5/0 and separate read-only
public integration in run42435195099 attempt2. The existing protected workflow
signed/exported/uploaded build9 in run42437873593 and cleaned signing assets.
App Store Connect browser authentication expired afterward; processing and
internal availability are not yet visually verified. See TESTFLIGHT.md.
This software checkpoint supersedes older unexecuted statements only for its
exact source/scope. Physical GPS/BLE/UWB/backpack and Apple/private-provider
proof remain separate. Subsequent roadmap source is not part of build9.

### Automatic current-GIF swap / Found Users - source follow-up

Both players independently opt in to the foreground PHONE game beforehand.
No per-encounter popup or friendship is required. Play a phone GIF, open the
player menu's Automatic GIF swap / Found Users sheet, prepare GAME Bluetooth,
then enable. This sheet leaves the actual player visible/playing; choosing
artwork through the old library picker is not treated as current playback.
Social/GPS game entries also offer the existing local library and player path.
Signed-out browsing keeps authenticated radio preparation/arming unavailable,
even when the public config advertises the game; friendship is not required.

Outgoing capture now requires actual playing, unfinished PHONE bytes with
unchanged artwork/policy revisions before and after sanitization. Pause,
selection, policy, background, token/account/target changes stop sharing.
Saved viewer settings that disable automatic phone playback block game arming;
the game never silently overrides them.
A received GIF that is now playing becomes the next other-peer source; the
durable FIRST original and its attribution/playhead are never substituted.
Accepted-friend intents retain their separate selected-artwork/consent behavior.

The 60-second throttle uses monotonic runtime time and resumes the retained
service-clock cooldown. Same-peer IDs and the staged exchange are retained in
the existing original journal, so stop/rearm or a new controller cannot reset
the current original's suppression. Only an acknowledged explicit original
restore and subsequent new journal create a new game recovery association.
No peer encounter times, GPS, RSSI, exact distances or timeline are uploaded.

Found Users is a scoped projection of existing ReceivedSwapArtwork records,
paired atomically with existing LocalMetFriend cards ONLY after both validated
application receipts, current authenticated peer/service binding and matching
staged exchange/bytes/recovery. Partial, legacy unconfirmed, mismatched,
cancelled and conflicting duplicate outcomes cannot synthesize Found success.
Identical confirmed duplicates reuse the same record. Outgoing digest is
retained locally for duplex duplicate integrity, never an encounter upload.
No new parallel contact/artwork collection is created.

Rows show the received GIF and corresponding minimal sender, with explicit
permanent local Save, Remove, optional Send Friend Request, Block, private
Report and the existing first-original Restore. Preview respects motion/data
saving. Bound Received records are filtered by account in recovery UI too.
Removing a receipt does not delete the first original or separately saved copy;
blocking/reporting remain separate normal service-authorized actions.
BLE observation/token/key/transcript/readiness/recovery remain mandatory.
Nearby Bluetooth is not reliable meters, anti-relay or physical proximity proof.
No fixed-beacon checkpoint binding, backpack original recovery or fake NI proof
is added. Existing GPS quality/dwell/lease/manual-private-claim paths remain.

14 new PhoneSwapGameTests and one native navigation fixture passed within
the exact1944292 native validation checkpoint above. Initial local syntax/
scope checks alone were not compiler evidence; subsequent actual Mac validation
and build9 upload are recorded separately. Windows still has no local Xcode.
No physical phone/backpack or new provider/key operations were performed.
These changes are in build9, not the earlier TestFlight build8.

### Post-build9 GPS hunt follow-up - separate source

The selected checkpoint now has a same-screen explicitly reviewed manual
fallback for denied/reduced/stale/uncertain GPS, without selecting it again.
It requires the same current event/plan/own opt-in and stopped/on-foot choice,
uses the existing private collection API, and never supplies GPS proof or
changes cooperative/profile-sharing consent. GPS confirmation still consumes
an exact fresh scope-bound hint; manual confirmation does not manufacture one.

Private hunt success is no longer inferred from a busy flag returning false.
The existing store exposes a transient selected-target receipt only after the
request, current client/ticket checks and matching plan/opt-in/event read-back.
Normal checkpoints must actually be marked collected; finish needs current
private completion prerequisites. Clear/cancellation/reload/partial responses
cannot manufacture an acknowledged selected-target UI outcome.
Three new EventSocialSourceTests passed with the existing GPS fixtures:
49native tests/0failures at source796c444 in run42439286316; actual app/test
source compiled. The existing unsigned workflow's bounded gps selector covers
EventSocialSourceTests and GPSGameEligibilityTests; old modes remain unchanged.
This source is not in uploaded build9; physical GPS and private API/device
acceptance remain separate.

A subsequent lease follow-up carries the existing CatalogEventClock captured
at the authorized event response through the hunt-state read and both GPS start
paths. Known local elapsed time reduces the event deadline; a wrong/backwards
clock, event read older than5s, or event ending during the dependency fetch
cannot start a new lease. Permission checks are followed by another deadline
check before updates begin. The maximum remains60s, with no wall-clock reset,
new sensor permission, stored samples or claims of perfect network clock sync.
Three new lease regressions passed in run42440162550 at15ab177:
actual app/test compilation and52targeted event/GPS tests/0failures.

A further source follow-up retains scoped hint cooldown deadlines in a bounded,
memory-only map across sensing stop/rearm. It neither stores coordinates/
samples nor writes an encounter timeline. A different authorized target is
independent; active deadlines are not evicted to permit instant reentry.
Expired entries are pruned and invalid monotonic inputs fail closed.
Three new cooldown fixtures passed: app/test compile and55targeted native
tests/0failures atf7e9660 in run42440878081. This source is not in build9.

SOLO's subsequent stationary-place follow-up requests recurring authorized
foreground fixes without a movement distance filter, allowing fresh continuous
dwell while standing still. Existing accuracy/noise/gap rules still govern
approximate trip distance; no speed/chase objective is added. Cancelled stale
callbacks are checked against both current session and latest-fix identities.
Two new SOLO dwell/noise fixtures passed at2005e72 in run42441726482:
actual app/test compile and69focused native event/GPS/SOLO tests/0failures.
The bounded gps selector includes SoloSourceTests. Actual stationary-phone
cadence/permission and private gameplay/device acceptance remain unverified.

The next SOLO permission-state source follow-up aligns the controller with the
location source's deliberate OS-permission pause: sensing is off, stale work
retired and area/trip sample anchors discarded, while an explicit Start remains
available after granting. It does not silently restart, drop accrued distance
or create a straight-line catch-up segment. A small location-source interface
keeps the real lazy CLLocationManager as default and permits deterministic
controller fixtures without requesting OS/device permissions.
Two new permission/restart/trip-anchor regressions passed atc71a34f in
run42442572805: actual app/test compile and71focused native tests/0failures.
This remains a software fixture checkpoint, not real GPS/permission/device
acceptance or an additional TestFlight upload.

The next unsigned SOLO area follow-up clears dwell/inside observations on stop
but retains in-memory configured entry cooldowns. Stop/rearm cannot make a
recent area entry instantly repeat, and partial dwell never resumes. Evaluators
are reconciled after reliable configuration loads/saves, so removed targets
cannot grow an unbounded memory index. No sample/coordinate/entry timeline is
persisted or uploaded; explicit manual scene choices remain separate.
Two new cooldown/restart regressions passed at9346b00 in run42443394862:
actual app/test compilation and73focused native tests/0failures.

The next unsigned paired-NI source follow-up checks coarse local stability
against its monotonic sample deadline at every application/reauthorization,
instead of trusting a cached Boolean until an expiry callback runs. Expiry
callbacks are current-session/sample-generation guarded; invalid objects cancel
older expiry work. The existing paired-game loop reports freshness loss through
the existing authenticated Boolean message without new protocol fields or
automatic fallback. Peer claims remain claims, not physical/ranging proof.
Three new freshness/reset/invalid-clock fixtures passed at5cab1ba in
run42444333653: actual app/test compilation and88focused native tests/0failures.
The targeted unsigned selector includes LocalPairingTests. No NI session is initialized by
cold/unconsented fixture checks, and no physical or exact-distance proof is added.

A further unsigned queue-boundary follow-up requires current local NI freshness
again after previous encrypted sends drain, immediately before dispatching a
positive nearby announcement to the radio. Expired queued claims fail closed
with explicit recovery status rather than being silently substituted or sent.
The transmission-time regression passed at01bf425 in run42445262344:
actual app/test compile and89focused native tests/0failures. Peer protocol
fields and manual fallback behavior remain unchanged.

The next unsigned local-pair outcome follow-up separates in-flight display
preparation from verified local application and successful receipt sending.
An early peer receipt cannot claim bilateral completion before local display
commit/receipt; late async completions recheck current epoch/pair and cannot
change a stopped/new session. Two state-machine regressions passed at87f71b3 in
run42446095517: actual app/test compilation and91focused native tests/0failures.
No physical display atomicity, ranging or identity proof is inferred.

The next unsigned hunt UX source shows only the owner's private confirmed
target count and offers an explicit next-remaining-target choice after a claim.
Targets remain any-order selectable, and finish is offered only after current
private completion prerequisites. Selecting a target starts neither GPS nor
collection, changes no sharing/cooperative consent and computes no peer or
contributor counts/distances. Two private-progress/remaining-target fixtures
passed at698b0f9 in run42447324717: actual app/test compilation and93focused
native tests/0failures. This source is not in uploaded build9.

The next unsigned GPS HUD source reports remaining dwell only from actual
usable continuous fixes. Outside/invalid/stale/eligible/cooldown/stopped states
clear that feedback; no timer predicts arrival or automatically confirms it.
Both event hunt and route eligibility views share the existing evaluator/
controller feedback. Two fresh-dwell/reset regressions passed at40c9c8b in
run42448104253: actual app/test compile and95focused native tests/0failures.
The accumulated post-build9 code at40c9c8b (evidence commitb0b89d3) passed
consolidated unsigned run42448942902: portable9/0, priority116/0 plusUI1/0,
full native989/0/2explicit skips, integratedUI5/0 and separate read-only public
integration1/0. The existing focused stage also completed successfully.
Repeated selections are not additive unique coverage. This is software/
simulator/public-client evidence, not physical GPS/BLE/UWB, private service,
provider/enforcement readiness, signing or another beta upload.
Build9/main app source1944292 remain unchanged; post-beta code stays on
native-recovery with independently dirty firmware research excluded.

### Social tab navigation follow-up - source only

A fifth Social tab groups community browsing/Favorites, friends/requests/QR/
nearby discovery/profile/device cards, events/creation/routes/GPS hunts and
playlists, messages/requests/activity/reminders, phone swap/Met/received recovery/
offline paired play, and owned incident/block/admin review controls.
Account settings retain account/security/cloud/device management and offer
Open Social instead of hiding personal social navigation inside the account.
Library/GPS shortcuts remain shortcuts, not a separate permission model.

Each destination retains current resource/role/account checks; disabled rows
say Sign in or Unavailable and do not synthesize capability flags. Guest
community/local Favorites/offline pairing remain possible. Entering Social
fetches public config only, never starts GPS/BLE/NI/peer consent. Swap game and
keyless peer withdrawal remain independent of friends/messaging availability.
Seven SocialTabTests and one native Social navigation method are prepared,
unexecuted. Changed files: new SocialTabView.swift and SocialTabTests.swift,
CommunityAccounts.swift, NavigationTests.swift, native-recovery workflow,
README/TODO; only AppTab.social and RootView's fifth tab hunks from independently
dirty LEDBackpackApp.swift/Views.swift. No new backend/provider/device operation.

### GPS gameplay P0: same-screen hunt confirmation - source follow-up

Library now has a prominent GPS & nearby games hub; event detail/hunt tools link
to the actual GPS checkpoint hunt. It reuses NativeEventSocialStore and
ForegroundCheckpointLocation, not a second protocol/sensor model. Current
going/review/published public hunt/own opt-in, event/participation/plan/opt-in
revisions and the actual server window are checked before sensing and private
confirmation. Broad local GPS needs fresh≤5s/full-accuracy≤25m confidence bounds
and continuous10s dwell; observation gaps/backward time reset eligibility.
Stationary targets now request recurring fixes with no distance filter, within
the existing60s foreground lease.

Eligible hints are ephemeral, exact-account/event/participation/checkpoint bound,
freshly renewed only while valid inside-radius observations continue, consumed
once and cleared on drift/stale/stop/expiry/account/OS changes. Expiry callbacks
are cancellation/epoch guarded so old timers cannot clear a new session.
The same hunt screen offers an explicit PRIVATE self-collection button while
stopped; no coordinates/GPS proof/public progress/automatic badge post is sent.
Co-op remains a separately chosen boolean contribution, no hidden counts or
participant locations. Ride/checkpoint eligibility also carries the selected
checkpoint into explicit progress review with sharing OFF, not automatic claim.
The HUD does not replace global PHONE artwork; existing SOLO/peer automatic
display still requires first-original recovery.

BLE peer games remain independent: observed short-lived purpose token, current
resolved key/account/session, encrypted transcript/readiness/recovery. GPS does
not precisely tag a peer; RSSI is rough. Optional NI measures supported phones,
not backpacks, and current paired calm-color mode is not a completed physical
tagging game. No authenticated fixed-checkpoint BLE-beacon contract exists;
an arbitrary nearby phone/backpack is not checkpoint proof.

Six GPSGameEligibilityTests and one default-off games/SOLO navigation UI test
are prepared, not executed; three existing
LocationFoundationTests now supply continuous fresh samples instead of assuming
widely separated fixes establish dwell. Required acceptance is actual supported
phone foreground/background/lock/denied/reduced accuracy/OS revoke/drift/
cooldown/stop/restore and two-phone BLE/NI/key/token/ready behavior, separately
from compilation/simulator/source flags. No device/provider operation occurred.
Changed files: new GPSGamesView.swift, EventGPSHuntView.swift,
GPSGameEligibilityTests.swift; ForegroundLocation.swift, LocationFeatureViews.swift,
EventProgressView.swift, EventSocialViews.swift, CommunityEventViews.swift,
PhoneDisplayViews.swift, LocationFoundationTests.swift, recovery workflow,
README/TODO; only the primary GPS hub link hunk in independently dirty Views.swift.
The separate Windows simulator workspace has no native edit/ownership role.
The native recovery workflow now checks GPS/nearby priority unit groups and
that default-off navigation before the full suite; its result remains pending.

### In-flight direct private-cloud send preserved - source only

Owner-private cloud rows/details now have Send & Play without requiring Keep
local. Only the explicitly selected item is temporarily read through the
existing managed/user-held client and unlock state; no server key is an app
credential. Owned state/item generation/key/version/metadata/hash/URL are checked
before/after download and before upload/playback. Legacy owned items use current
owner/detail/manifest checks, not another account's library scan/public fallback.
Pause/lock/delete/account/policy changes clear temporary send state. No permanent
local copy/publication or hidden cloud re-enablement occurs.
Six CloudBackpackSourceTests are prepared, unexecuted. Changes in
CloudVaultProtocol/Store/Views, CloudLibrary, CloudBackpackSource,
BackpackDirectSend/its view and recovery test selector are preserved pending
validation. OWNER PRIORITY now switches to GPS/Bluetooth games; this slice is
not being expanded or labelled validated/beta-ready.

### Direct Send & Play, GIF timing/loops and natural eyes - source follow-up

Community/Favorites selection and a local artwork's Send & Play action now open
one direct preparation screen, without requiring a local library save or a
manual slot-number form. Separate copies are fitted to the connected panel,
only empty ordinary slots2–54 are chosen, and every destination is re-read before
the first destructive upload packet.1–20GIFs/50MB prepared data are bounded.
No occupied/reserved destination is automatically overwritten. The existing
advanced queue remains the deliberate manual-overwrite alternative.

The direct sender uses the same known ordered-loop playback command for ONE
GIF as for a multi-GIF batch, rather than treating slot selection/ATT delivery
as an animation receipt. It checks stored occupancy and actual reported loop
mode/list after upload, refreshes inventory, and exposes uncertainty instead of
claiming physical frames are read back. Time on screen is explicitly written
with each program, not left at the old short default. Power/brightness are not
forced. Any interrupted upload can leave its current destination partly changed;
no automatic resend or rollback. Physical animation/repeat behavior still needs
the owner's backpack test; source/receipt assertions alone are not proof.

Controls distinguish animation speed/frame delay from Time or GIF loops before
switching to the next program. Timing patches modify GCE delay bytes (or insert
an explicit missing control) and repeat metadata in a separate copy; original
pixels/compressed image streams/credits remain unchanged. The local Adjust GIF
timing / loops screen can save a new copy and retains source repeats by default;
the existing GIF Studio still supplies per-frame editing.1total loop removes
repeat extensions rather than incorrectly encoding0/infinite;Nloops encodeN−1
repeats. Device display time for loops is calculated from edited frame timing
and rounded up to whole seconds (≤600s), explicitly not a verified firmware loop
counter. One-frame sources remain still and are labelled, never fabricated into
animations. Invalid/overflow timing fails instead of silently clipping pauses.

Natural pixel eyes now use a shared renderer for live output and previews:
smooth eased glances with fixations/micro-movement, variable fast-close/slow-open
blinks including occasional double blinks, curved eye masks and moving pupils/
accent highlights. Existing theme colors/speed are honored; Reduce Motion gives
stable open eyes. No sensor/radio/background behavior is started by the renderer.

The direct free-slot safety depends on the previously prepared complete20-byte
slot-record occupancy/equality fix: a nonzero size-like prefix with zero suffix
must NOT be considered empty. Only that narrow Slot/parser change and two new
portable tests are included; dirty bitmap/OTA/firmware algorithms and unrelated
cache/reserved research remain excluded. Existing16-byte identifier API is
preserved for callers.19new native methods (13GIFTimingAdjustmentTests and
6NaturalEyesTests) and2portable SlotMetadataTests are prepared, not yet executed.
The existing community UI regression now checks direct-send availability and
uses the actual BackButton rail, not an absent standard navbar back button.

Prior source `df0b15e` compiled and passed912unit tests,0failures/2explicit skips
in run42398734050, but one of2UI regressions failed on that back-button locator;
the live-public step was skipped. This does not validate the new send/eyes
snapshot. Exact new/changed sources: `GIFTimingAdjustment.swift`,
`GIFTimingViews.swift`, `BackpackDirectSend.swift`, `BackpackDirectSendView.swift`,
`NaturalEyes.swift` (new); `GIFStructure.swift`, `CommunityGallery.swift`,
`CommunitySelection.swift`, `CommunitySelectionControls.swift`,
`CommunityFavoritesView.swift`, `MediaLibraryViews.swift`; only eyes-renderer
call hunks in `LiveEngine.swift`/`LiveTheme.swift`; only Slot/parser hunks in
`Packages/BackpackProtocol/Sources/BackpackProtocol/Wire.swift`;
new `LEDBackpackTests/GIFTimingAdjustmentTests.swift`, `NaturalEyesTests.swift`,
new `Packages/BackpackProtocol/Tests/BackpackProtocolTests/SlotMetadataTests.swift`,
`LEDBackpackUITests/NavigationTests.swift`, recovery workflow, README and TODO.
No physical device/firmware/provider/key/enforcement operation was executed.

### Map-first road routes and checkpoint pins - source follow-up

The route planner now supports named start/destination place pickers, explicit
driving or walking directions via MapKit, route shaping handles and checkpoint
pins projected onto the blue route. Choose Add draggable route handle, tap the
route, then drag its ↔ marker; directions recalculate through the ordered handles.
Dragging a start/finish also recalculates an already generated route. Normal
creation requires no latitude/longitude entry; numeric/manual tools remain
collapsed as optional fallback, not a required step.

Apple Maps consent discloses viewports/searches and selected endpoint/shaping
coordinates. No device/participant GPS, identity/account token/private event text
is supplied. At most8 shaping points/9legs and12,000 transient polyline points
are accepted. Saved route geometry uses a documented10m simplification tolerance,
preserves endpoints/corners and must fit the existing200-point API limit. Routes
that cannot fit fail without truncation or invented backend fields. Directions
failure/cancellation/account/endpoint/draft/role/structure changes preserve the
prior draft; pending route changes block saving.

Checkpoints are placed within100m of a tapped road-line point and snapped onto
that line; off-route taps fail explicitly. Rerouting does not silently move
previously defined checkpoints: any >100m from the new line must be moved/removed
before review/save. Map directions are organizer preview geometry, not live
navigation, GPS attendance or safe-routing certification. Gate/checkpoint naming,
ordering/optional-stage/structural locks/artwork and exact save review use existing
API semantics.8new `EventRoadRouteTests` methods are prepared; no actual MapKit
directions/radio/sensor/device operation was executed here.

The first UX compile run42397694385 failed on a SwiftUI type-check time budget
in the expanded event editor;0native fixture methods executed. The editor form,
initialization/lifecycle and owner-monitor task are now separated into bounded
expressions without changing access/review behavior. Another actual runner pass
is required before any update is released. No old build8/30ee227 pass validates
this route/selection/wizard follow-up.

Additional changed files: new `LEDBackpack/EventRoadRoute.swift`,
`EventRoutePlannerView.swift`, `EventRouteDraft.swift`, `EventCreationSteps.swift`,
`CommunityEventViews.swift`; new `LEDBackpackTests/EventRoadRouteTests.swift`,
native-recovery workflow, README and TODO. Independent dirty firmware/source
remains unstaged and excluded from this update.

Community browsing now shows an image-only GIF grid: no visible titles,
uploader names or dimension/frame captions on tiles. Credits remain in the
saved attribution instead of opening a detail page on tap. Reduce Motion and saved motion/
data-saving settings use still previews instead of automatically loading GIFs.
Thumbnail decoding runs off-main. This follow-up is source-only and not part
of uploaded TestFlight build8; native validation/release remains pending.

### Community selection and guided event creation follow-up

Community tile taps now select/deselect up to20 GIFs in explicit tap order,
without opening a per-GIF page. Favorite reuses current authorized original/
manifest downloads and saves credited copies in the local Favorites list;
Send to LED saves originals and queues them, then offers the existing explicit
panel/slot/overwrite/compatibility confirmation screen. No slot is written by
the gallery, no account/public like/cloud publication is required, and originals
are not rewritten to hardware size. Partial cancellation/failure states state
exactly how many copies were completed; remaining selections are not replayed.
Selection is invalidated on filter/account/policy changes. Batches are bounded
to20 selections/50MB with60queue and100local-library limits. Favorite and queue
metadata are atomically committed together for each accepted library copy.
The image-only My Favorites screen permits multi-select queueing/removal of
favorite flags without deleting originals or credits.

Events now have a prominent Create event action and four guided steps:
Basics → Time → Venue → Review. Explicit times, valid timezone, venue review,
current permissions/revisions and exact pre-save confirmation are preserved.
New events suggest the device timezone, but displayed suggested start/end times
still need deliberate approval. Venue map/search has selectable pin-labelled
results and a collapsed numeric alternative. Editing coordinates/radius/name
invalidates venue approval. After creation, the next-step screen links directly
to the existing map/numeric planner for start/finish gates, intermediate game/
ride checkpoints and route guides, and to the event's participant/invite tools.
No new gate wire type, GPS route tracker, automatic RSVP/grant or stale retry.

**16 new regression methods prepared, not yet executed:**10
`CommunitySelectionTests`,5 `EventCreationStepsTests`,1 new native UI
`NavigationTests` method. The DEBUG-only public fixture is generated locally,
with no server/provider/radio operation; it checks image-only multi-select,
Favorites and disconnected Send queue. The real native recovery workflow is
queued for compilation/focused/full/UI/public-adapter validation of this exact
source; this follow-up is NOT part of uploaded build8 until a new release.

Exact files: `LEDBackpack/CommunityGallery.swift`, `GIFPreviews.swift`,
`LocalLibrary.swift`, new `CommunitySelection.swift`,
`CommunitySelectionControls.swift`, `CommunityFavoritesView.swift`,
`CommunityEventViews.swift`, `OrganizerMap.swift`, `EventRoutePlannerView.swift`,
new `EventCreationSteps.swift`, `LibraryPreviewFixture.swift`;
new `LEDBackpackTests/CommunitySelectionTests.swift`, `EventCreationStepsTests.swift`,
`LEDBackpackUITests/NavigationTests.swift`, `README.md`, `TODO.md`,
`../.github/workflows/native-recovery.yml`. Independent dirty firmware/GIF/
reserved55–59/full20-key source remains excluded from publication/validation.

## Verified native checkpoint - 2026-11-07

Source `30ee227`, branch `native-recovery`:
[Run42360855629](https://github.com/ErrantActions/-led-backpack/actions/runs/42360855629)
**PASSED** unsigned app/unit/UI compilation on Xcode27.1/build27A9275,
Swift6.4, simulator SDK27.1/iPhone Duo, macOS27.0.1.

- Portable protocol:7tests/0failures (committed Wire only).
- Consolidated source groups:449tests/0failures.
- Full unit suite:889tests/0failures/2explicit skips.
- Native UI regression:1test/0failures.
- Actual public native-client live integration:1test/0failures/**0skips**.

Unit skips are unsigned signed-Keychain integration and the separately enabled
live method. `TEST_RUNNER_` forwarding made the live GET/config/catalog/current-
access/manifest/hash method actually execute in its own step; a green skipped
step is not integration evidence. No accounts/backend mutations were performed.

All34source families/P0-P11scope and remaining gates are reconciled in
[TODO.md](TODO.md#current-verified-native-milestone---2026-11-07).
This is a precise simulator/source/public-integration milestone, NOT full
VoiceOver/Dynamic Type/memory/device/privileged-service acceptance, physical
BLE/NI/hardware recovery, signed Keychain/PRF/App Attest/APNs, TestFlight or
provider/key/enforcement/deployment readiness. Disabled backend features remain
gated; ComfyUI stays deferred. Independent dirty firmware/GIF/full20-key/
reserved55..59 work was excluded and preserved.

The older recovery/failure narrative below is history; the result above
supersedes its pending/unexecuted labels only within this exact verified scope.

## Actual recovery build - compilation passed / consolidated tests failed

The selectively published APP branch is `native-recovery`. Executed toolchain:
Xcode27.1/build27A9275, Apple Swift6.4, simulator SDK27.1/iPhone Duo,
macOS27.0.1. Independent dirty firmware/Wire/GIF hardware work is excluded.
The first nine completed runs passed **7 portable protocol tests** against
committed Wire, then failed compilation with exit65; their native test stages
were skipped. The tenth run now passed actual unsigned app/unit/UI-bundle
compilation, then executed449consolidated tests with20failures (18unexpected).
Full regressions were skipped; no overall test/native green.

| Published source | Actual run | Compilation failure |
|---|---|---|
| `797d538` | [42344369261](https://github.com/ErrantActions/-led-backpack/actions/runs/42344369261) | Route helpers declared in local scopes. |
| `c18bcdb` | [42344704373](https://github.com/ErrantActions/-led-backpack/actions/runs/42344704373) | Event cover type declared inside gallery ViewBuilder. |
| `defc74f` | [42345149797](https://github.com/ErrantActions/-led-backpack/actions/runs/42345149797) | Event-social error type not visible to client/views. |
| `503719a` | [42345466960](https://github.com/ErrantActions/-led-backpack/actions/runs/42345466960) | Swift compiler assertion on guestbook binding/state shadowing. |
| `0eb9903` | [42345826592](https://github.com/ErrantActions/-led-backpack/actions/runs/42345826592) | Friend capability getter accesses private controller from another file. |
| `989c42e` | [42346143892](https://github.com/ErrantActions/-led-backpack/actions/runs/42346143892) | Received renderer/control visibility and recovery builder complexity. |
| `39b54bd` | [42346607753](https://github.com/ErrantActions/-led-backpack/actions/runs/42346607753) | Native test compilation: expected positive event receipt must unwrap optional event. |
| `517c05d` | [42347029754](https://github.com/ErrantActions/-led-backpack/actions/runs/42347029754) | Chat/event SwiftUI expression type-check budget exceeded. |
| `142d0db` | [42347472381](https://github.com/ErrantActions/-led-backpack/actions/runs/42347472381) | Governance fixture calls a missing known-event RSVP decline member. |
| `feb2a6f` | [42347922942](https://github.com/ErrantActions/-led-backpack/actions/runs/42347922942) | App/unit/UI bundles compiled;449consolidated tests,20failures; full regression skipped. |
| `257fb97` | [42348958929](https://github.com/ErrantActions/-led-backpack/actions/runs/42348958929) | Compiled;449consolidated tests,1failure; full regression skipped. |
| `61adcd1` | [42350257799](https://github.com/ErrantActions/-led-backpack/actions/runs/42350257799) | Compiled;449consolidated/0failures; full regression cancelled at job limit. |

The earlier route/cover/error/getter scopes and guestbook binding were corrected
without changing their intended checks/bodies or SDK. The sixth build exposed
that the earlier PHONE-control correction still left type nesting; controls are
now actually module-scoped. The next build removed those errors and reached
test compilation. The existing positive RSVP test now explicitly unwraps the
expected event; nullable production access-loss receipts remain unchanged.
One existing test updated, no new fixture or executed-test count inferred.
The latest runner cleared that fixture error but exposed chat/event builder
complexity. Typed content/form/lifecycle properties now split those expressions;
the loaded event no longer shadows mutable state. Presentation order and
authorization/consent remain unchanged; another actual build must verify it.
The next build cleared those diagnostics and exposed a known-event decline
helper that was local to ownership transfer. Its unchanged checked/nullable
implementation is now client-extension scoped; no metadata grant or fake
receipt was added. Another actual build must verify the correction.
That correction is now included in the successful unsigned `feb2a6f` build.
The18groups completed with449executed/20failures; no skip-method entries were
recorded. Runtime fixture corrections retain weakly bound owners for their
proper lifetime, encode exact source timing without changing hardware GIF
work, use owned isolated writable directories, and verify decoded PNG pixels/
alpha/dimensions/authored state rather than nondeterministic metadata byte order.
These fixes add no new methods or weaken production checks; rerun required.
Completed logs were retrieved after live-log access returned404 while running.
This is not overall native/test/beta readiness.
The corrected snapshot executed449tests with1failure (0unexpected), resolving
19earlier failures. Exact timing now passes, but absent GIF loop metadata was
incorrectly interpreted using ImageIO's synthesized loop0. The shared recorded-
loop parser now supplies phone and native pixel decoding with exact recorded
metadata; thumbnails keep existing policy and malformed/conflicting loop blocks
fail explicitly. Missing/finite/forever assertions are strengthened rather than
waived; another actual runner must verify the correction.
That source correction passed **449consolidated tests/0failures**. Full regression
hit the60minute job limit after an invitation-role assertion and organizer-write
test hang. Fixtures now script GET-before-PATCH revalidation and fail unscripted
requests immediately; intentional suspension is bounded by5seconds and rejection
wording is current. Production access/revision checks remain unchanged.
Partial output includes the signed-
Keychain prerequisite skip, not a completed full-suite result. The queued
read-only/time-bounded checkpoint is now active; no live/physical/beta readiness.

The bounded checkpoint subsequently failed full regression and identified the
organizer timeout plus incomplete event fixtures, phone decode supersession and
UI reveal assertions. Corrections preserve production event/access constraints,
guard queued decode before it can cancel newer work, encode explicit loop
fixtures and use actual UI viewport geometry. A new phone supersession
regression is prepared. Exact rerun results, full totals and the public live
step remain pending; no waived tests or completion claim.
Deadline request-history assertions are also made safe while retaining exact
POST/body/count/deadline checks, so fixture regressions fail rather than crash.

**Actual full native pass at88dbb9a /
[Run42357495220](https://github.com/ErrantActions/-led-backpack/actions/runs/42357495220):**
unsigned app/unit/UI compilation; consolidated449/0failures; unit889/0failures/
2skips; UI1/0failures. Skips: unsigned signed-Keychain integration and the separate
public opt-in method. The dedicated public step incorrectly skipped too because
plain shell environment was not forwarded into XCTest. `TEST_RUNNER_` forwarding
is now wired; no live-native integration pass is claimed until1method/0skip
actually executes. Physical/signing/provider and broader acceptance remain gated.
The safe-assertion follow-up passed unit889/0failures but exposed intermittent
UI overscroll (control above the viewport). Bounded slow geometry-based drags
now replace reversing full swipes; containment/hittability assertions remain.
Actual repeat UI/live verification is still pending.
The next actual runner must verify these fixes; logs remain retained. Neither
portable7/7 nor a running workflow establishes native integration/beta readiness.

## Replacement APP checkpoint - PURPLE / unsigned runner validation resumed

Owner clarification: the intended Mac execution path is the existing GitHub
Actions `xcode-27` runner. Its active unsigned-validation workflow last succeeded
in run `42159868752` at historical source `0c5850e`; current dirty source is not
included. No separate local Mac provisioning is needed. The owner has now
explicitly unpaused narrow native commit/push and unsigned runner validation.
Independent firmware/GIF/full20-key/reserved-slot work must not be sweep-staged.

The owner-requested [dedicated recovery workflow](../.github/workflows/native-recovery.yml)
is now prepared. It runs manually or on the isolated `native-recovery` branch,
never ordinary branch pushes. It uses the existing `xcode-27` runner, compiles
unsigned, executes all18source fixture groups together and then full unit/UI
regressions. Each stage stops on failure and retains provenance/logs/result
bundles. No signing, provider activation or deployment is included. Its initial
workflow/ignore-allowlist-only commit `2b19e7f` was pushed successfully; the reviewed
native snapshot is published and now passed unsigned app/test compilation;
XCTest and broader acceptance remain pending. The dedicated branch trigger
uses authorized Git push without requiring a new API token or provider key.
Local YAML/permission/trigger checks, all6Bash syntax checks,18selector-file
checks and result-retention checks passed for the initial manual workflow.
The isolated branch trigger's local YAML/Bash/selector checks also passed.
This is workflow syntax/wiring evidence only, not executed native tests.

One explicit [read-only live native integration fixture](LEDBackpackTests/NativePublicIntegrationTests.swift)
is prepared for actual guest config/catalog/current-access/manifest/hash calls
through the native adapter. It runs only in its enabled workflow step after full
regressions, not ordinary unit runs; no accounts, mutations, providers or device
operations. Missing live capability/signing prerequisites fail the enabled step.
It is not yet compiled/executed and does not prove private-feature integration.
Recorded results must distinguish its ordinary opt-in skip from its live result.

Per-test timeouts are enabled; the next preflight checks runner support:
focused60/120s,
full600/900s and public120/300s default/maximum. They bound stalled tests and
preserve named failures/results, not replace performance measurements.

The native publication checkpoint is a selectively staged APP snapshot, not a
claim to validate every remaining dirty firmware edit. Independent Wire/full20-
key/reserved-slot/storage/batch/OTA/evidence/hardware-GIF work remains unstaged.
Mixed app roots retain their committed hardware APIs in the indexed snapshot;
native account/service/player/editor/lifecycle/permission changes travel together.
Working-tree research bytes remain unchanged. Runner results apply to the exact
published snapshot SHA, never automatically to the remaining dirty work.

Current P0-P11 /34-family reconciliation and exact ownership/limitations are in
[TODO.md](TODO.md#replacement-app-recovery-reconciliation---2026-11-06-purple).
Retained artwork/main PHONE/SOLO/offline pairing/optional NI and other feature
entry points were not reimplemented. Recovery fixed module visibility of the
shared `ScopedPhoneCanvasControls` and rejected old ordinary request responses
after same-origin account/reload changes or cancellation. Logout/erasure's
explicit separate receipt handling is preserved. Five new `CommunityTests`
methods are prepared, **ALL UNEXECUTED**; no native compiler/runtime pass.

This replacement independently read the live public `/api/v1/config` over normal
TLS: deterministic artwork tools, manifests/size filters, presence/friend peer
identity, event moderation/keyless withdrawal are enabled. Messaging/chat,
playlists, guestbook/report creation, Apple push, cloud, redraw and integrity
enforcement remain disabled. Keep actual in-app capability/error gating; do not
enable providers/keys or ComfyUI. Backend35c13fb/616+13/Linux/live evidence is
separate from native proof.

### Consolidated Mac commands - prepared only, not executed

Prerequisite: publish the **reviewed native snapshot and its dependencies**,
then let the authorized runner check out that exact SHA. Independent dirty
hardware changes remain outside this milestone. No source copying is needed.
The Windows host lacks
Swift/Xcode/XcodeGen and cannot execute iOS builds/XCTest. Existing workflow
requires Xcode27.1, simulator SDK27.1 and an available iOS27.1 iPhone Duo.
Verify those installations before executing; do not silently use another SDK.
Ruby/Bundler/fastlane/signing are not needed for this unsigned simulator phase.

The following is **Mac Bash**, only after execution/source-access authorization.
Set `NATIVE_CHECKOUT` to the owner-approved Mac path for this retained tree and
`SIMULATOR_ID` to the verified simulator UDID; no guessed destination.

```sh
set -euo pipefail
cd "${NATIVE_CHECKOUT:?Owner-approved current native tree required}/ios"
: "${SIMULATOR_ID:?Verified iOS27.1 iPhone Duo simulator UDID required}"
export DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer
test -d "$DEVELOPER_DIR"
xcodebuild -version | grep -Fx "Xcode 27.1"
swift --version
xcodebuild -showsdks
test "$(xcrun --sdk iphonesimulator --show-sdk-version)" = "27.1"
xcrun simctl list devices available
xcodegen --version
xcodegen generate
swift test --package-path Packages/BackpackProtocol
xcodebuild build-for-testing -project LEDBackpack.xcodeproj -scheme LEDBackpack \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/Recovery CODE_SIGNING_ALLOWED=NO
TESTS=()
for CLASS in CommunityTests AccountNativeParityTests CatalogManifestTests \
  AdminArtworkTests AutomaticPhoneSessionTests ScopedPhonePreviewTests \
  SoloSourceTests LocalPairingTests FriendArtworkSelectionTests FriendPlaybackTests \
  LocationManagerInitializationTests LocalPixelDocumentTests LocalPixelCodecTests \
  LocalPixelGIFTests LocalPixelStoreTests EventSocialSourceTests \
  OwnerPlaylistSourceTests CommunityChatSourceParityTests; do
  TESTS+=("-only-testing:LEDBackpackTests/$CLASS")
done
xcodebuild test-without-building -project LEDBackpack.xcodeproj -scheme LEDBackpack \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/Recovery -resultBundlePath build/RecoveryFocused.xcresult \
  -parallel-testing-enabled NO "${TESTS[@]}" CODE_SIGNING_ALLOWED=NO
xcodebuild test-without-building -project LEDBackpack.xcodeproj -scheme LEDBackpack \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/Recovery -resultBundlePath build/RecoveryIntegrated.xcresult \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

Stop on any failed preflight/build/test; retain logs, unique result bundles,
source provenance and actual executed/failure/skip counts. Do not run a later
stage to hide an earlier failure. Existing manual CI focused mode selects four
older groups only; it is not the consolidated recovery selector above.

Full regression includes `LEDBackpackTests` and `LEDBackpackUITests`; XCTest
navigation fixtures are not a live-service acceptance pass. Still required:
current-config live integration with owned normal test-account data, manifest/
hash/error/unavailable UX, offline composed GIF pixels/timing/bounds, crash/
first-original/restore, cancellation/expiry/roles/blocks, memory, VoiceOver/
Dynamic Type and foreground lifecycle. Real-device Keychain/PRF/App Attest/APNs,
two-phone BLE/NI/recovery, hardware transport and signed distribution remain
separately owner-gated. No native green or beta readiness is claimed.

## Main PHONE, SOLO and explicit local pair continuation - PURPLE/source only

The scoped event/owner-playlist player now offers a distinct **Play on main
PHONE / preserve my original** action. It stops the isolated preview first
(including its screen leases), acquires the shared PHONE owner, saves the actual
initial bytes/playhead/policy durably, and uses the existing exact scoped media
aliases/current-access checks. Authorization is checked again after decode,
immediately before commit. Initial originals survive successive entries; stale
manual selections/targets/accounts cannot be adopted. Stop retains explicit
recovery; restore acknowledges exact original bytes without deleting the copy.

This global path honors the CURRENT captured source/cue lease, at most30seconds;
it never silently renews it or promises full unattended playback of longer
playlists. A new explicit source request is required for another window.
The owner editor additionally has a default-off one-shot option to start one
main-PHONE window at the next due foreground schedule occurrence. It consumes
that consent, disarms future occurrences on leaving the editor and never runs
background/catch-up work. Ordinary preview requests do not trigger this option.
Owner entry timing pauses while loading; event entries are discarded if the
server-clock cue moved during I/O. Gentle scene frames are encoded once as a
bounded local animation, not repeatedly sent to the server or journaled per
frame. No hardware commands, guaranteed synchronization or background scheduler.
The earlier scoped-player misplaced type declarations/starting-entry watchdog
reference were corrected directly in source; this is NOT a compiler pass.

The cancelled SOLO implementation has been retained and inspected: actual local
scene copies, fixed place/adventure/event-kind targets, quality/dwell/hysteresis/
cooldown offers, approximate distance, one-shot milestones, optional route-free
recaps, local solar/polar/manual states and owned atomic archive are wired.
Foreground/location/PHONE consent are explicit, lazy and distinct. Manual
changes during arming/restoring now invalidate the operation, restore captures
its expected revision across I/O, and nonrepeating daylight scenes no longer
restart their final original GIF just to fill a presentation window.
Selected scene copies follow the displayed local-library order, not Set order.
Home/work coordinates remain device-only; samples/routes/encounters are not
stored/uploaded. Actual quality/solar/lifecycle/device behavior is unverified.

**Offline paired calm colors** is a new bounded account-free PHONE game, not an
offline substitute for online friendship or original-GIF sharing. Both devices
explicitly exchange fresh two-minute QR/manual codes, compare all four key-hash
groups, approve stationary/noncontact play and choose the same preset/ranging
mode. A third separate BLE UUID namespace carries only ephemeral hints and
bounded encrypted frames. X25519/HKDF/AES-GCM proves the manually compared key,
domain-bound to both canonical codes/nonces/roles; locator UUIDs are not secrets.
Both application-ready acknowledgments and reliable recovery precede displaying
generated complementary colors. No original/private GIF/file/name/account/GPS
is transferred; no Met/Received collection or online consent is created.
Lost receipts are uncertain; no exactly-once/anti-relay/proximity/safety claim.

Optional NearbyInteraction is real source using NISession/discovery-token
secure coding and the authenticated channel. It initializes only after explicit
foreground NI game consent and original preparation. Only coarse fresh relative
stability is exposed, never exact distance/direction/map/history. No sample is
persisted. Unsupported/denied/suspended/stale/removed ranging stops, with an
explicit manual-mode/new-pair option, never silent fallback or resume. Stable
relative range does not prove people are stationary; user approval remains
required. Usage descriptions are wired without enabling background NI/signing.
All actual camera/BLE/NI/device operations and two-phone proof remain UNEXECUTED.

**32 NEW deterministic fixtures prepared, ALL UNEXECUTED:**8 in
`AutomaticPhoneSessionTests.swift`,12 in `SoloSourceTests.swift`,12 in
`LocalPairingTests.swift`. They cover actual first-original/lease/restore/
post-decode authorization, local persistence/quality/dwell/trip/solar/no-route
bounds, canonical pair codes/comparison/purpose crypto/replay/range stability
and cold denied-manager/session paths. They are not executed or device evidence.

Exact source files: new `AutomaticPhoneSession.swift`, `ScopedGlobalPhone.swift`,
`LocalPairing.swift`, `LocalNearbyInteraction.swift`, `LocalPairedGame.swift`,
`LocalPairedGameView.swift`; changed `ScopedPhonePreview.swift`, `PhoneDisplay.swift`,
`PhoneDisplayViews.swift`, `SwapRecovery.swift`, `SoloSceneController.swift`,
`SoloSceneViews.swift`, `PhoneSwapRadio.swift`, `PhoneSwapProtocol.swift`,
`LEDBackpackApp.swift`, `OwnerPlaylistViews.swift`, `Info.plist`; the three new test files above, README,
TODO and Protocol. Existing firmware/full20-key/reserved55–59/wire logic is
unchanged. Native build/typecheck/tests/grammar/CI remain UNEXECUTED; Mac/Xcode
consolidation, accessibility/memory/Keychain/crypto/OS permissions, actual NI/
radio/recovery and distribution/provider gates remain separate.

The final VS Code request to run the new artwork/automatic PHONE/SOLO/local-pair
Swift groups was cancelled before any result arrived. There is no confirmed
native execution/pass from that request. Consolidated validation requires an
authorized Mac/Xcode environment; Windows/source inspection is not a substitute.

## Native admin artwork studio - PURPLE, ALL UNVALIDATED

Administration now opens real capability-gated **Owned artwork previews /
compare / branches**. Choose a named current public catalog source, an owned
completed result, or one explicitly picked local GIF. Settings and deliberate
processing consent create a new owned preview job; no cloud/private-library scan,
community publication, source overwrite, provider installation or hardware action.
Cleanup/upscale are deterministic, not AI; redraw requires its separate actual
capability and never falls back to pretending resizing is AI.

The typed job client uses the existing current-admin/account/origin/media-policy
scope and exact-byte request/integrity pipeline. JSON selects exactly one source;
immutable multipart puts settings metadata before the sole GIF. No community
upload-policy header/publication grant is applied to private editing inputs.
Creation must return HTTP202 with the captured normalized settings and source.
Late account/role/capability/media-policy results are discarded.

Latest20 owned jobs, status/error/24-hour expiry, retained-input availability,
explicit paused input/result comparison, independent branch creation, ten-step
session-local selection undo and cancel/remove are actual UI. Download re-fetches
current authorization and bytes, checks exact canonical same-origin owned routes,
size, complete bounded GIF decode and64x64 result canvas, then rechecks the job.
No nonexistent digest manifest/revision-CAS or synchronized-display guarantee is
invented. Unknown legacy input stays unavailable. Exported copies cannot be
recalled; provider assets have their separately managed retention.

One active job/10submissions-hour,5MB input/output,120source frames/40million
decoded pixels and16AI-redraw frames remain explicit. Previews own no global
phone selection, journal, brightness/awake lease or backpack transport. Current
jobs/access are polled only while foreground; closing/background/account/role/
policy changes clear private state and stop local work. New loaded images pause
comparison; motion/data-saving restrictions never silently resume it. Uncertain
submissions require deliberate owned-job reconciliation, not automatic replay.
The source does not claim that polling eliminates all revocation races.

**24 NEW AdminArtworkTests methods prepared, ALL UNEXECUTED:** settings/AI gates,
job retention/status/legacy input, URL safety, exact one-source/multipart/privacy
policy, corrupt/resource bounds, role/capability/scope separation, duplicate jobs,
creation HTTP/auth/source binding, branches, before/after authorized media/
64x64 validation, late account change, cancellation receipts and store clearing.
Changed native files: `AdminArtwork.swift`, `AdminArtworkStore.swift`,
`AdminArtworkViews.swift` (new), `AccountServiceScope.swift`,
`CommunityClient.swift`, `CommunityAdminViews.swift`;
`LEDBackpackTests/AdminArtworkTests.swift` (new), README and TODO.
No native checks/build/tests/typecheck/grammar/CI were executed. All native source
remains PURPLE; actual UI/memory/Keychain/integrity/device evidence remains P10.
The interrupted backend inspection made no key/env/container/template changes.
Existing dirty firmware/GIF/full20-key/reserved55–59 work is preserved.

## Separate friend artwork selection and isolated preview - PURPLE/source only

The accepted-friend page now selects a greeting/pass artwork independently of
the current phone display. Choose an explicitly picked local file, an owner-local
phone original or an existing local GIF; alternatively explicitly copy the
displayed phone artwork. No private-library/cloud scan or automatic upload.
Selection/preview never calls the global phone player's show/restore methods,
acquires a screen/display lease, writes a slot, arms Bluetooth or starts service
work. The current phone bytes/playhead remain the initial recovery original.

The selected bytes/attribution are captured separately by the friend authority:
greetings play the selected local greeting only after existing authenticated
eligibility, and a pass sender transmits only the selected privacy-safe candidate.
The recipient's current artwork remains recovery-only and is never substituted
as outgoing art. Original local bytes, timing, repeats and attribution are
preserved. Known current-controller attribution is reused only while its current
account/artwork revision still matches; a new choice with no credit never
inherits unrelated original artwork credit.

The isolated preview reuses the bounded GIF decoder and monotonic playback clock,
starts paused, uses exact source delays/repeats, and owns no awake/brightness
lease. Palette/duet preview does not overwrite the selected media. Explicit
preview Play respects Reduce Motion and local animation/data-saving controls;
policy/lifecycle changes pause it and never silently restart it. One chosen
original, one decoded preview and at most one cancellable decode worker are
retained; originals remain <=5 MB and the shared decoded-preview budget is
40 MB each. Sender pass selection additionally validates the <=128 KiB sanitized
GIF and safe credit before preparing its media intent. Unsupported still pass,
corrupt/resource-exhausting media and I/O errors preserve the previous choice.

Account/service/target/background/selection changes reject late results.
Changing artwork/preset or withdrawing draft consent discards unarmed
preparation; the Arm button observes actual radio readiness and binds the exact
prepared choice/preset. Immediate rejected starts do not consume a session or
initialize a radio; an activation that actually starts remains conservatively
consumed if its later outcome is uncertain. Existing peer crypto/ready/recovery,
current service proof and separate game consent boundaries are unchanged.

**14 NEW FriendArtworkSelectionTests methods prepared, ALL UNEXECUTED**:
selection versus global phone, corrupt/oversize/still rejection, byte-preserving
pass candidate, cancelled/late reads, isolated preset preview, original timing/
repeat/pause policy, separate greeting/recipient bytes, account-draft clearing,
failed arming, durable original separation and correct attribution.
Exact changes: `LEDBackpack/` — `FriendArtworkSelection.swift` (new),
`FriendPeerInteraction.swift`, `FriendPlaybackViews.swift`, `PhoneSwapGame.swift`;
`LEDBackpackTests/FriendArtworkSelectionTests.swift` (new), `README.md`,
`TODO.md`, `Protocol.md`. Source only; no validation/build/test/typecheck/grammar/
CI, actual radio/camera/sensors/device/firmware, signing/provisioning, commit/push
or deployment. Hardware/UWB/standalone offline pairing and runtime evidence
remain pending. Independent dirty firmware/reserved55–59 work is untouched.

## Event social and owner playlists - PURPLE, SOURCE ONLY

Event teams, separately consented hunts/cooperative goals, guestbook, private
recap and display-plan forms are now source-wired, as are owner-only playlists,
foreground source schedules and separately consented public snapshots/paused
local QR previews. Current capability/access/revision/consent guards remain
authoritative; server-managed encryption is not E2EE. Saved plans/schedules
are not physical synchronization, background execution or verified attendance.

The initial batch reports60new XCTest methods prepared, ALL unexecuted, in
[EventSocialSourceTests.swift](LEDBackpackTests/EventSocialSourceTests.swift)
and [OwnerPlaylistSourceTests.swift](LEDBackpackTests/OwnerPlaylistSourceTests.swift).
The public-snapshot DTO's accidental function-local scope was corrected during
integration; no compiler or tests were run. Current-session publish receipts
and revoke-all do not invent an owner-wide share inventory endpoint.

The follow-up now wires actual isolated PHONE previews via
[ScopedPhonePreview.swift](LEDBackpack/ScopedPhonePreview.swift): exact original
aliases, bounded media/decode, before/after and periodic current authorization,
fixed foreground lease, paused explicit controls, durations/shuffle and gentle
scenes.30additional methods make90cumulative event/playlist fixtures, ALL
unexecuted. Global selected artwork/original journal/root/backpack/background/
physical synchronization remain untouched or unverified.

## Chat requests, published cards and recovery - PURPLE, SOURCE ONLY

Opt-in message requests, authorized published-playlist chat cards/paused
revalidated viewers and immutable exact-byte Keychain outbox are source-wired,
with30-day retained-history recovery and60-day minimal receipt limits.
Server-managed encryption is not E2EE. Private playlist IDs/text/schedules are
not substituted for published snapshot references; no owner-wide inventory API
is invented.52new fixture methods are prepared, ALL validation unexecuted.
Actual server capabilities, Mac/Keychain/media/access/cancellation/integration
validation and beta gates remain pending.

## Offline pixel studio and phone policy integration - PURPLE, SOURCE ONLY

Phone display > Offline pixel & GIF studio is account-free local RGBA editing,
editable projects and explicit new-copy PNG/GIF export. It never automatically
selects the active display, uploads, pairs or writes hardware. Dimensions are
1..128 per side, at most120frames/8MB decoded RGBA, with bounded undo and
off-main cancellable I/O. Original input bytes are not rewritten.

[LocalPixelGIF.swift](LEDBackpack/LocalPixelGIF.swift) uses the existing
structural reader and ImageIO patch decoding to compose logical-canvas frames,
including optimized rectangles, binary transparency, local palettes,
interlacing and disposal0..3. Centiseconds and absent/finite/forever loop
semantics are retained; missing delay controls use the existing10cs local
default. Reserved disposal, plain-text/user-input GIFs, APNG and animated WebP
remain explicitly unavailable. Exact GIF export rejects partial alpha and
unrepresentable palettes; transparent animations reserve a palette entry
(at most255opaque colors/frame). PNG/projects retain RGBA.

The interrupted follow-up's source was recovered and integrated, not executed.
There are75new LocalPixel XCTest methods prepared across four files, plus
three new phone saved-preference policy fixtures; ALL validation is unexecuted.
These counts and source inspection are not compile/runtime/composition proof.

Saved viewer preferences now gate automatic phone animation separately from
explicit manual Play and local phone controls. Policy changes stop automatic
playback/hand-offs without restarting when re-enabled; original recovery and
local controls are not rewritten. Studio previews start paused, stop on viewer
policy changes and still require explicit Play. The root observes current user
preferences; the studio observes `avatarPolicyRevision`. No hardware behavior
or beta readiness is claimed.

## Account, catalog, devices and admin continuation — PURPLE, SOURCE ONLY

This bounded source batch adds real native forms, selectors, paging, confirmations
and request/state handling, not live activation. Production **6bed90c** remains
unchanged; absent source capabilities display unavailable. **All validation is
unexecuted**: no build, XCTest, typecheck, grammar/lint, CI, signing/provisioning,
provider/credential work, deployment, radio/camera/sensor/device/firmware operation,
commit or push occurred. Existing dirty source and independent firmware/full20-key,
GIF timing/transparency and reserved55–59 work are preserved.

Wired surfaces:

- Account > Profile avatar now selects an immutable local raster/GIF snapshot,
  separately previews the exact file and optional oriented percentage crop, and
  explicitly uploads/replaces only the previewed selection. Changing file/crop/
  account invalidates that preview. The original bytes plus crop metadata go to
  the existing AI-only service; there is no local GIF rewrite, timing clamp,
  private-library selection/upload/AI scan or manual approval queue. Current
  avatar version is reread before replacement/removal; retry captures the failed
  immutable version. Existing input/decoded-pixel/consent/error limits remain.
- Account > Motion and data-saving preferences saves mature-content preferences
  independently of avatar-upload availability, and loads/saves revision-bound
  viewer motion/data settings when advertised. Shared profile/admin/contributor/
  scoped-device avatars and private attachment rendering use those settings,
  reduced motion and the existing visible/active renderer. Explicit Play may
  still use data. Saved settings now govern automatic phone presentation;
  explicit manual Play and independent local controls remain separate. GIF
  timing/original bytes and backpack playback are not changed.
- Community search, My uploads and the new bulk community queue expose exact
  native versus actually-recorded-export any/all size filters: advertised
  16/32/48/64, explicitly legacy96x128, and up to16 custom rectangles. No rotation
  or resized-as-native claim. My uploads pages owner records. Community detail
  explicitly selects an original or recorded export (no missing-export fallback),
  rechecks authorized detail before/after bounded media I/O, and checks per-file
  bytes, dimensions, frames and actual bounded frame decoding. The source-only
  `catalogDownloadManifestEnabled` contract now provides the trusted per-file
  SHA-256 manifest; the native path binds and rechecks it before/after download,
  checking the digest before any raster decoding. Save/customize deliberately
  reacquire a current authorized/verified copy rather than commit an old preview.
  Stale account/mature/policy results clear; anonymous official-app browsing
  remains distinct from admin-only web. Attribution and local independent copies
  are preserved. Contributor avatars confer no general profile access.
- Account > My devices adds/edits owner-private generic labels and optional matrix,
  defaults owner sharing off, explicitly issues/replaces/revokes locally rendered
  unverified QR tags, selects current accepted friends for offers, and accepts/
  declines/cancels/unlinks captured revisions. Incoming offers and friend
  selectors are bounded/paged. Explicit paste/read of a shared owner card displays
  only minimal identity/approved scoped avatar, rechecks every5seconds while
  visible, and uses the tag header plus normal native proof. Transfers/revocation/
  unlink never resurrect tags or alter local GIFs. There is no physical ownership
  proof, readable-identifier claim, public directory or automatic connection.
- Account > Firmware library lists currently authorized published stock/custom
  releases with exact model/hardware/version/tag filters and paging. Explicit
  `.bin` export rechecks captured revision/access before/after I/O and independently
  verifies declared size/SHA-256. Administration adds metadata-first immutable
  `.bin` draft upload, separate declared-target publication, withdrawal and
  deletion. A digest or admin declaration is not authenticity/compatibility:
  execution, flashing, recovery protocol and recommendations stay unavailable.
- Account > Optional model research submits only `{targetId,consent:true}` after
  an initially unchecked choice of an admin-curated generic combination.
  Administration separately creates/deletes sanitized combinations and views
  aggregate **self-reports**, never verified devices/installs. No raw device
  strings, BLE/MAC/serial/IP/account/location/source/time or connection history
  is collected into the submission. Authentication is not anonymous transport;
  individual aggregate contributions cannot be retrieved/withdrawn.
- Existing Administration navigation now reaches page-local exact-ID community
  quarantine/delete, including quarantine holds, and content-blind paged upload
  alerts with visible/active30second refresh. Bulk actions capture confirmation,
  reason, account/role and item snapshots, preflight current state, and validate
  the atomic selection receipt. Private/cloud items are rejected. Quarantine
  release still uses the existing explicit safety/audience item editor, not AI.
  Acknowledge and deliberate account-wide upload-hold release are distinct; alerts
  expose only counters, never private content. Conflicts/uncertain receipts demand
  reconciliation, not silent retries.

Contract boundaries (not unfinished native download wiring):

- The new continuation-source `GET /items/:id/download-manifest` is now genuinely
  wired through `NativeCatalogManifest.swift`, gated by
  `config.catalogDownloadManifestEnabled`. `CatalogItem`/`PanelVariant` remain
  unchanged; hashes come only from the separate current trusted API response,
  never optional speculative fields, downloaded bytes, names or local
  fingerprints. The native decoder requires manifest version1, matching item,
  `integrityOnly:true`, valid ISO server time, exactly one original and the exact
  currently recorded original/export set, at most6 unique canonical names/URLs,
  configured HTTPS origin/path, lowercase hex64 SHA-256 and source byte/dimension/
  frame/40M decoded-pixel bounds. Preview/unknown/missing/rotated/invented files
  cannot substitute. Byte length/SHA are checked before GIF structure, canvas/
  frame-rectangle and actual per-frame decoding checks. Current detail and a
  second current manifest are checked after I/O; changed hashes/descriptors,
  authorization, account, mature/viewer policy, server/capability or local
  selection/load generation discard late results. Busy/quota/conflict failures
  propagate without legacy fallback or automatic retry.
- Absent flags (including live6bed90c) preserve legacy limited browsing/download
  behavior with the explicit **Checksum unavailable / not checksum-verified**
  label. Only an advertised, successful manifest path may say its SHA matched.
  Missing-live capability is not missing-source wiring: the source server
  contract and native consumer now both exist, all unvalidated/unactivated.
  A trusted manifest proves current transfer integrity, not authorship, safety,
  historical variant authenticity, firmware compatibility or perpetual access.
  Save/customize reacquire current bytes and recheck selection/account generation
  immediately before their separate local copy; previously saved copies cannot
  be recalled. No community integrity-manifest coding surface remains blocked.
- Existing, different digest contracts are not absent: firmware detail supplies
  `id,revision,byteSize,sha256,downloadUrl`, already bound and verified by
  `AccountFirmwareLibrary.swift`. Owner-private `/cloud/items` and migration
  contracts supply `dataHash`, `metadataHash`, optional private
  `metadata.contentHash` and migration `manifestHash`; existing `CloudVaultClient`,
  `CloudVaultStore` and `CloudVaultWire` check their account/key/generation/version
  bindings, ciphertext hashes/decryption and independently reconstructed migration
  manifest. Managed plaintext is not compared to ciphertext `dataHash`. Those
  private contracts do not authorize or authenticate community originals/exports
  and were not replaced or widened here. Validation remains unexecuted for all
  contracts, including the new community manifest continuation.
- Bulk/alert APIs do not expose client version-CAS fields; item/alert preflight
  and server community-selection authorization are real, but cannot certify
  absence of every concurrent edit. Avatar replace/remove similarly use current
  version preflight; no undocumented expected-version write field is sent. This
  is an explicit absent-server-contract guarantee, not an independently actionable
  native CAS implementation left blocked or unfinished.
- LocalLibrary, PhoneArtworkLibrary, PhoneDisplayViews, all LocalPixel files,
  PhoneDisplay/LiveEngine/BluetoothLink/LEDBackpackApp and GIF/firmware wire files
  were untouched by this batch. The narrow phone integration hook is
  `community.user?.mediaPreferences?.permitsAnimation(reducedMotion:manual:)`,
  invalidated by `community.avatarPolicyRevision`. Use it for service avatar/
  attachment requests, not to rewrite timing or override local playback controls.
  Local size/provenance filtering must use recorded source dimensions, never
  infer native size from a resized panel copy.

New source files in `LEDBackpack`: `AccountMediaPreferences.swift`,
`NativeCatalogSizes.swift`, `AccountServiceScope.swift`, `AccountDevices.swift`,
`AccountFirmwareLibrary.swift`, `AccountDeviceResearch.swift`,
`CommunityBulkModeration.swift`, `CommunityUploadAlerts.swift`,
`NativeCatalogManifest.swift`.
Direct integrations: `CommunityClient.swift`, `CommunityFeatures.swift`,
`CommunityAccounts.swift`, `CommunitySocialViews.swift`, `CommunityGallery.swift`,
`CommunityUpload.swift`, `CommunityAdmin.swift`, `CommunityAdminViews.swift`, plus
only the shared-attachment preference renderer in `CommunityChatViews.swift`.
`LEDBackpackTests/AccountNativeParityTests.swift` prepares **70 NEW XCTest
fixtures**, all unexecuted (crop/immutable GIF bytes, mature/viewer settings,
size/native/export bounds, guest/role/current-account/late-result guards,
unverified tags/transfers/scoped headers, firmware bytes/revisions, provenance-
free research, bulk selection/conflicts and content-blind alert decoding).
`LEDBackpackTests/CatalogManifestTests.swift` adds **30 NEW** focused manifest/
decoder/state fixtures: **100 NEW total** in this bounded account/catalog batch,
all unexecuted. They cover strict complete descriptors/origin/names/hash bounds,
actual GIF bytes/decoding, missing-flag honesty, no busy/error downgrade, current
account/mature/capability/late-hash rejection and anonymous official-app requests.
The existing recursive `project.yml` source/test directories include these files;
no project generation or build was performed. Native/device/beta validation and
all absent live capabilities remain pending, never green.

## Native event owner/reports and builder/gallery — PURPLE, SOURCE ONLY

This bounded follow-up implements native source for the local event contracts
in the catalog `API.md` (147a808 plus the post147a808 independent moderation
flag correction). Production 6bed90c does **not** advertise these new policy
capabilities. Nothing here deploys/activates them, provisions a key/provider,
builds the app or establishes beta readiness. All prior independent dirty
friend/phone, GIF/timing, full20-key and reserved55–59/firmware work is preserved.

Actual native surfaces:

- Event organizer tools now link to **Named co-organizers / ownership / audit**.
  Add choices come from the currently authorized named roster; remove/transfer
  choices are current named co-organizers. Current event-owner role and captured
  revision are required, never a global-admin override. Ownership receipt/audit
  controls require the advertised source ownership capability. Explicit retain/
  relinquish controls additionally require the actual event setting; omission
  retains the legacy co-organizer choice. A successful nullable receipt clears
  old event/management/audit/media/chat state without an unauthorized detail
  reread; independent membership comes only from the receipt. Only the current
  owner pages history. Erased references remain nullable opaque IDs, never
  private-profile lookups.
- Event details offer a blank category/details, initially unchecked **Report
  event** form only with `eventReportsEnabled` and the event setting. No title,
  venue, roster, chat, GIF, screenshot, scan or GPS is copied into its request.
  **Account > My event reports / withdrawal** pages own explanations/revisions/
  expiry, with no staff notes or event detail requirement. Withdrawal captures
  the report revision and acknowledges unchanged moderation.
- **Administration > Typed event report cases** has typed literal notes and
  hold/release/resolve with captured report/event/actual moderation revisions,
  including actual zero for a first hold. ReviewContext is a separate type,
  never normal event/membership authority. Private `contentWithheld` drops even
  injected formerly-public definitions; no case-authorized media/roster/chat/
  profile reads exist. The independent **Existing event holds / release only**
  surface uses `eventModerationEnabled`, even with reporting/key unavailable.
  Only when that flag is absent does an explicitly true legacy reporting flag
  support the old held routes; explicit false never falls back. Release requires
  actual existing held state and never decrypts or invents a report.
- Holds hide normal progress, badge-collection, media and conversations/contact
  entries; stale media is dropped on authorization/context changes. Organizers
  can still correct definitions. A known own RSVP can be deliberately declined
  without a detail read, accepting an acknowledged `event:null` honestly. Release
  never restores shared progress or bypasses participation review/new consent;
  report withdrawal, thirty-day expiry and erasure never release a hold.
- Create/edit retains the existing meetup/group-ride, schedule/IANA timezone,
  capacity, fixed venue/radius and exact unchanged ISO seconds/milliseconds.
  New dates must be explicitly selected. Advertised unlisted controls send
  `unlistedLinkConsent:true` only after deliberate consent and warn about
  link-readable/public venue exposure. Public/unlisted-to-private local review
  explicitly retains going/invited/organizer membership until separate removal.
  Back/cancel performs no write or implicit GPS/progress/friend consent.
- Native MapKit still uses actual events/roles/revisions/structural locks and
  per-page imagery/search permission, **not** web `eventMapPlanningEnabled`.
  Typed numeric venue/stage/guide alternatives require no imagery. Required
  start/finish have distinct IDs even at identical loop coordinates. Optional
  intermediates require both actual config/event gates; legacy optional/artwork
  assignments are retained. Server published/order/progress/review locks remain
  authoritative. Named authorized community/event-exclusive artwork is reused.
- Event-definition and route saves now have mandatory structured **LOCAL
  pre-save review** of their exact immutable, separate payloads: schedule/zone/
  visibility/fixed geometry/radii/order/optional stages/rewards/artwork/consent/
  copy retention. Only explicit confirmation writes. Back, input/account/
  selection/access/revision changes invalidate review; late artwork is dropped.
  Acknowledgement never overwrites newer local edits.
- **Event > Organizer image gallery** adds explicit bounded raster staging/
  decoded preview, caption/alt edits, complete order/first-image cover, upload
  and removal, while reusing immutable replacement. Metadata precedes one still
  file; 5 MB, PNG/JPEG/WebP, 20-image, 8192px/40M input and 1600px preview budgets
  apply. No PDF/video/camera/cloud scan exists. Revision/full-order conflicts
  retain choices; explicit cancel/reload is required. Replacement retains order/
  cover, resets public-link approval and retires the old URL. Pending public/
  unlisted images are labeled unpublished and never used as a published cover.
  Account/event/role/access/mature-policy changes clear covers/requests.

Current contract limits: upload appends atomically under server capacity rules,
but its DTO has no expected-order field. Removal likewise has no server
compare-and-swap revision/order field; native preflight pins the snapshot without
inventing rejected fields or promising race-free DELETE. Order and replacement
do have server full-order guards; metadata editing has an asset-revision guard.
Uncertain acknowledgements never trigger automatic retries.

**46 NEW focused XCTest fixtures prepared, ALL UNEXECUTED**:
`LEDBackpackTests\EventGovernanceTests.swift` (23) and
`LEDBackpackTests\EventBuilderGalleryTests.swift` (23). Existing route fixtures
were adapted to nullable RSVP and explicit route-review inputs, not executed.
Decoder/role/withheld/nullable/expiry/conflict/independent-release/form/
separate-draft/geometry/media/order/late-result coverage is prepared source only.
`project.yml` already includes both whole source/test directories; no generation
or project/signing change is needed.

**ALL validation remains UNEXECUTED:** builds, XCTest, typecheck, grammar, lint,
CI, browser/simulator/device/visual/accessibility/media/network/radio/camera/
sensor/receiver/firmware checks. No commits/pushes, backend edits, deployment,
signing/provider/key/model operations or live device/server operations occurred.

## Accepted-friend PHONE interactions — PURPLE/source only

Active, owned accepted sessions now open **Choose / preview / arm PHONE
interaction** in Friends > Location-powered consent. The invitation/acceptance
controls still start no playback; each phone must separately select local media,
choose the same supported preset and approve the kind/role/media-sharing intent.
Manual local previews start paused and make no current-friendship or sync claim.
They do not require a live account response or silently arm Bluetooth.

The new source consumes `friendSessionPeerIdentityEnabled` and the documented
revision-bound GET/POST participant peer-identity contract. Only the original
start/accept login and a currently active, mutually permitted session qualify.
Opaque hint hashes are SHA256 of the UTF8 token STRING. Keys are ephemeral
Curve25519, public keys only go to the service, and session UUIDs are locators,
not secrets. Immutable-role keys are erased on stop/background; there is no
silent replacement or session renewal. This bounded UI requires a fresh accepted
session after stopping; it does not automatically rotate an expired friend hint.

The existing bounded GATT framing and encrypted exchange core now supports a
distinct accepted-friend UUID namespace (`A7C25000...` service, `...5001` hint,
`...5002` inbox, `...5003` outbox; shared suffix
`9055-4916-B4FE-CE72ED134B06`). It advertises only the service UUID, then serves
only the intended friend's short-lived hint. No friend-discoverability or GIF
game enablement is required or synthesized. Their service endpoints/tokens,
managers and authorization remain independent. HKDF/AES-GCM transcripts bind
the distinct friend purpose, service origin, both account-bound keys/hints,
nonces, main session/kind/preset/roles/revisions and unchanged expiry. Both
participants must independently read stable hints and prove key possession;
this is still relayable, not verified proximity.

Actual phone behavior is source-wired:

- Greeting plays only the owner's explicitly selected local still/GIF after
  authenticated eligibility; that greeting is NOT transmitted.
- Shared palettes render a matching soft 24-frame preset; duet renders
  complementary left/right halves of a common local scene.
- Pass-animation transfers only the session sender's separately sanitized
  chosen GIF <=128 KiB, preserves source timing/repeats, validates the complete
  bytes, and alternates visible/black two-second presentation legs. The
  recipient's previous artwork is never shared. Source originals are not
  rewritten; unsupported still transfer fails rather than converting it.
- Encrypted matching media agreements precede media offers. Each actual local
  scene is rendered/decoded before its explicit scene-ready acknowledgment;
  complete validation and bilateral application-ready/ready-ack precede replacement. ATT delivery
  alone is insufficient. The known initial original is durable before arming.
  Friend-specific recovery readiness does NOT pretend either side enabled the
  separate game. Only actual pass recipients enter Received swaps; public
  protocol markers and generated scenes create no receipt or Met-friends card.

Authenticated monotonic ping/pong measures RTT/offset and a stated error budget;
RTT >600ms or inconsistent/missed scheduling fails explicitly. Shared starts
use a four-second lead plus the server-clock expiry anchor, not GPS. Translation,
nonce/counter replay and role/preset checks are bounded. Actual GATT latency,
render timing and visual synchronization are UNVERIFIED, not certified sync.
Final receipt loss can leave outcomes uncertain; no exactly-once promise.

One controller leases the phone target, excluding an armed game/friend
interaction/manual recovery race. Durable originals retain purpose/session
association and initial bytes across replacements. An active journal from
another purpose/session requires explicit restore first. Stop closes local
radio/key/playback before service withdrawal, retains recovery, and never
restores over a newer deliberate selection. Motion/data-saving/foreground and
both hint deadlines remain gates through decode and scheduled commit. Peer Stop
releases phone brightness/awake leases without changing their independent opt-in
settings; explicit Play, restore or presentation action can acquire them again.
No automatic same-encounter retrigger. No coordinates/history, progress/badges,
private-library scans/uploads, game consent, hardware-slot or firmware writes.

**24 deterministic FriendPlaybackTests fixtures prepared, ALL UNEXECUTED**:
actual renderer/palette/duet/timing, privacy-safe pass/recipient boundaries,
clock quality/invalid samples, purpose/key/revision/counter replay, token-string
hash/identity/login/expiry, explicit bilateral agreement, restart/purpose-bound
durable originals/readiness/cancellation/repeated replacement, target exclusion,
actual phone policy/handoff/late selection, and receipt-versus-marker retention.
The CGImage pixel encoder is shared with the existing MediaCodec path so bounded
scene generation and GIF encoding run off-main, without duplicating encoders.
Recovery preparation/staging methods were also lifted to repository scope so
the shared actor exposes the actual methods used by both engines.

Source changes: `LEDBackpack/` — `CommunityClient.swift`,
`FriendPeerInteraction.swift` (new), `FriendPlaybackViews.swift` (new),
`LEDBackpackApp.swift`, `LocationFeatureViews.swift`, `MediaCodec.swift`,
`PhoneArtworkLibrary.swift`, `PhoneDisplay.swift`, `PhoneDisplayViews.swift`,
`PhoneSwapGame.swift`, `PhoneSwapLocalStore.swift`, `PhoneSwapProtocol.swift`,
`PhoneSwapRadio.swift`, `SwapRecovery.swift`, `SwapRecoveryViews.swift`;
`LEDBackpackTests/FriendPlaybackTests.swift` (new), this README and TODO.

Hardware recovery/transport, UWB/ranging, fully standalone offline paired modes,
consolidated compile/typecheck/XCTest/grammar/CI, physical radio/permissions/
timing/privacy verification and signing/rollout remain pending. No validation,
camera/radio/sensor/device operation, provider/provisioning, commit/push,
deployment or production activation occurred. Preserve PURPLE, not green.
Independent dirty firmware and reserved slots55–59 remain untouched.

## Local event policy source follow-up (final service 147a808)

The bounded native invitation/progress follow-up is **source only and unvalidated**.
Actual config+event flags gate explicit deadline controls: omission keeps the
server's seven-day new-grant default or existing deadline/legacy null; an explicit
future UTC timestamp up to thirty days intentionally changes a grant. Receipts
display their actual expiry, never a locally invented default. Independent going/
organizer access is not removed simply because an invitation expires.

Event list/detail expiry uses the server clock and rechecks access. Inbox event
navigation revalidates the exact current notice and opaque grant reference through
the existing authorized page, not a suffix interpreted as event revision. If a
notice moved off its captured page, navigation fails closed and asks for a refresh;
it does not scan unrelated pages or substitute general event visibility. Card
foreground revalidation clears unverified references while existing reconciliation
continues. No new resolver endpoint or automatic RSVP is invented.

Event detail explains shared-progress retention (event end +24h or earlier
withdrawal), no silent extension or arrival certification, and separate private
badge policy. The next local source slice now links organizer tools to a current
participant/invitation roster with named current friends, bounded paging and
explicit invite/revoke versus owner-only participant-removal confirmation.
It is **not** a historical expired/revoked invitation ledger; the service exposes
current state only. Fresh captured role/revision checks do not invent unsupported
revision fields or claim atomic CAS for those endpoints.

The member progress screen displays latest self-reported claims and returned
retention deadlines, not a timeline, GPS or certified arrival. Published
optional/required/start/finish metadata is retained; the server enforces ordering,
actual event window and reviewed participation. Sharing defaults off, resets on
context/revision/account/access/lifecycle changes, and never queues a replay.
Local-only validation also withdraws prior shared state; its local checkpoint is
memory-only. Explicit own withdrawal does not require detail/board access and
remains available in the open screen after membership loss. Supplied permitted
avatar metadata is optional; the existing renderer/default does not fetch another
profile or widen permission.

The separate badge source slice now supplies explicit private collection and
owner inventory/profile-choice/hide/removal screens. Social/me and event settings
must actually advertise `accountAwardsEnabled`; the list uses bounded owner-only
24-row pages. Joined/checkpoint collection captures reviewed participation and
separate consent, never a progress-sharing choice. Optional/required/start/finish/
window/order enforcement remains server-authoritative. The UI distinguishes
sharing requested, currently visible, currently permitted and unavailable/null
revision. Showing requires a new captured current-version/participation-privacy
confirmation; hiding and deletion do not require event access. Server limits of
500 private records/12 requested profile badges are explicit, not local guesses.

Collection is private by default and self-reported/uncertified; names may reveal
participation or visits to known places. Old-version/rejoined records are never
automatically republished. Current profile/friend DTOs may supply minimal badges,
but normal profile AND current-event authorization remain required; friendship or
admin role does not unlock private badges. No artwork bytes, credentials, GPS or
arrival timeline are copied. Source consent resets and late-account guards prevent
automatic offline replay. Hunt-specific alternate collection flows and broader
parity remain out of scope.

Twelve focused badge fixtures and twelve prior roster/progress fixtures are
**prepared, not executed**. See [native TODO](TODO.md)
for exact source/remaining surfaces. No Swift tests, source
validation commands, builds or CI were executed for this source-only slice.
Production capabilities are not inferred from the final local backend source.

## Requirements

### Nearby friend discovery (local source-complete, not validated)

Friends > Add friends / Look for friends has independent default-off lookup and
discoverability. Prepare checks the existing Bluetooth usage declaration and
allows OS permission/state preparation only; another explicit Start arms one
five-minute foreground service session after checking its actual capability and
current account/control revision. No automatic relaunch, background, denied-state
or expiry restart. Global Stop all/friend/block/account hooks stop local peer work
before captured service withdrawal. Failed/ambiguous remote acknowledgments remain
explicitly unconfirmed, with deliberate reconciliation, not silent renewal.

A separate CoreBluetooth adapter advertises only a fixed application service
UUID, then serves the current short-lived opaque token through a read-only GATT
characteristic. It does not assume iOS arbitrary advertisement service-data
support, advertise names/email/account/hardware IDs, or modify backpack protocol.
Concurrent connections, read timeouts, observation count/age, duplicate tokens
and TTL are bounded. Transient peripheral object handles remain local; RSSI,
coordinates, exact peer distances and encounter history are not sent, shown,
logged or persisted. Copied fresh tokens can still be relayed: this is a hint,
not authenticated physical proximity or distance proof.

Only actually read fresh tokens are resolved through the authorized service into
minimal named/avatar/default cards; alphabetical ordering is not distance sorting.
An explicit request rechecks current token access and still needs recipient
acceptance, granting no location/game/library rights. Manual invite-token/friend
request controls remain available. The later separate QR source slice below now
adds local generation, explicit camera scanning and authenticated inviter preview.
Discovery does not start greetings, synchronized playback, pass-animation, UWB,
GIF swaps or geofence scenes. Twelve fixtures are prepared, all validation is
unexecuted; keep source status PURPLE, not green or beta-ready. Real radio,
background/OS behavior, compilation and consolidated acceptance remain pending.

### Local foreground location foundation (unvalidated source)

Friends > Location-powered consent & timed sessions separates independent/mutual
per-friend service permissions, the persisted global-stop revision, deliberate
volatile timed-session control and actual phone sensing. Capability absence is
unavailable. The service list/invite/accept/decline/stop controls do not establish
proximity or start playback, games, sensors, discovery or GIF exchanges. Explicit
Stop all first stops this foundation's local coordinator, then requests service
revocation; remote failure is shown. A legacy service without global revocation
can stop sessions but is not claimed to clear all per-friend flags.

An authorized event's foreground local checkpoint hint requests When-In-Use
permission only after explicit consent, and requires another explicit Start
against fresh fixed geometry/member/review/time/version state. Actual sensing
has a visible active/off state, a maximum sixty-second lease, no background
request and no automatic restart/renewal after expiry, background, account,
friend or permission changes. Reduced/denied/restricted/unavailable accuracy
uses manual fallback. Samples are discarded; only ephemeral dwell/cooldown/
eligibility state remains, with no coordinate storage, logs or network payload.

The local hint uses <=5s freshness, <=25m usable accuracy, confidence bounds
inside the configured radius, inner 2m entry margin, ten-second dwell and
sixty-second cooldown. It never enlarges a radius, certifies arrival, exposes a
peer distance/history or triggers progress/badges. Manual progress and private
collection remain separate deliberate actions. Later source-only sections add
phone greetings/palettes/duet/pass and the separate GIF game/recovery. Verified
BLE/UWB/ranging/sync, hardware interactions and geofence scenes remain pending.
Existing live-dashboard sensors are not activated by this
foundation. Global Stop all/consent withdrawal suspends location-dependent
dashboard sensing/rendering too, without a hardware write; its last frame may
remain until an ordinary explicit display action. Ten deterministic fixtures are prepared, not executed;
no build/test/grammar/CI, actual sensor/device or external operations occurred.

- iOS 17 or later.
- A compatible backpack only for Bluetooth controls; phone display works
  offline without a backpack or account.
- Location, Bluetooth and notification permissions for the features you enable.
- Optional camera permission only when scanning a trusted-device adoption QR.

This is an experimental app. Background behavior and optional live features
depend on iOS permissions, system scheduling and device compatibility.
See the [packet protocol reference](Protocol.md) for integration details.

The supplied firmware research adds conservative local protocol refinements:
live-drawing type/length semantics are explicit with unchanged bounded wire
bytes, and complete slot metadata distinguishes an absent resource from the
firmware's occupied-but-unavailable sentinel. Unavailable identifiers cannot
match cached thumbnails or now-playing artwork; acknowledged uploads warn
instead of associating an unknown key. Full metadata participates in overwrite/
erase confirmations. This does not add firmware flashing, readback or new
device commands. These new fixtures await resumed Swift/Mac validation; the
current backend-handoff/Mac-CI pause and production settings remain unchanged.

The full-report follow-up adds source-timing-preserving GIF previews/editor/export
(including pauses over ten seconds), immutable single/batch upload compatibility
review and explicit consent before overwrites, repeat-preserving batch fitting,
and optional 64/8-color live bandwidth modes with full RGB unchanged by default.
Firmware evidence is read-only and model/revision-specific; rotation displays
wire codes instead of guessed degrees. The [protocol coverage table](Protocol.md)
records every research area and why incomplete storage/update/GPIO findings are
not enabled as app controls. Focused fixtures are prepared; only offline
validation is authorized while Swift/Mac/device work remains paused.

The subsequent recovered OTA document now has a narrow offline inspection tool
under Backpack. It checks the whole MV container and hashes, model/revision
provenance and supplied decimal checksum, then displays a never-transmitted
packet plan. **It cannot flash.** The vendor ArrayBuffer/MD5 ambiguity, duplicate
handling, reboot/recovery and actual device acceptance are unresolved. No vendor
credential/download, BLE send, automatic downgrade or firmware image is bundled.

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
import a PNG/JPEG/WebP still/GIF original. Brightness stays unchanged unless the
separate phone-only override is explicitly enabled; it never uses panel controls.
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
idle-timer setting on background, picker entry, exit or disabling it. The optional
phone brightness lease separately captures/restores the prior screen value on
background/visibility loss, error or exit; it never forces maximum brightness.
No background playback task, account/network request or BLE packet is needed.
Imported files are copied byte-for-byte into the separate private local phone
originals library (100 files /100 MB, each <=5 MB), with distinct IDs even for
identical copies; source files are never rewritten. The original GIF library
remains selectable without conversion.

The current beta-critical source follow-up moves phone file reads, decoding and
library persistence to cancellable workers/actor storage. Selection is committed
only after validation, with generation/foreground/visibility guards; corrupt,
unsupported or resource-exhausting media leaves previous bytes/state retained.
Decoded previews are immutable, bounded and released offscreen. Two bounded
previews can coexist during an atomic selection; no unbounded phone cache is added.
Black aspect-fit portrait/landscape rendering offers optional nearest-neighbor
pixels and a bounded grid only when individual pixels are visible. Animation
allow/data-saving still controls stop play until another explicit Play; source
centiseconds/repeats remain unchanged. New selections and cold starts are paused.

Library's explicit Phone/Backpack target selector only changes local target
selection. Hardware staging and panel playback remain separate from retained phone
bytes/playhead; switching targets does not send anything. Without connection the
hardware UI says unavailable, while phone display still works. Backpack Bluetooth
manager creation is now lazy until an explicit hardware operation, without
changing framing, slots, caching, firmware or reserved55–59 semantics. Existing
separately opted-in account/cloud tools retain their own gates; opening/selecting/
playing phone originals never invokes them.

`PhoneDisplaySnapshot` retains original bytes/source ID, elapsed phase, play intent,
explicit motion override, awake/brightness and presentation policies. Restore
validates before replacing current artwork, so failed loads do not lose it.
The later recovery-first source now persists this snapshot through the separately
bounded journal below. It is not a swap wire protocol or automatic exchange;
phone snapshots do not contain or require a peripheral/slot.

Current changes are PURPLE/source-only: twelve new deterministic offline
decoder/state/target/brightness/import fixtures and adapted prior phone fixtures
are prepared, not executed. Prior Mac results apply only to prior source, not
this asynchronous player/library/target follow-up. Consolidated compilation,
physical orientation/accessibility/lock/file-picker/lease restoration and beta
rollout remain separate gates. Actual exchange/met-friend state and hardware recovery remain later scopes.

### Recovery-first local swap preparation — PURPLE/source only

Phone library > Recovery first / Received swaps has an actual local prepare and
**Restore my original phone artwork** action. Before anything could replace
artwork, preparation captures exact original still/GIF bytes, timing/repeats,
source ID/available attribution, monotonic playhead/frame, paused/play intent,
phone presentation/awake/brightness policies and explicit target association.
The owned app directory holds one schema-1 atomic file envelope with SHA-256
integrity, installation/account-or-local scope and bounded bytes. Integrity is
local corruption detection, not a peer signature or encrypted transfer protocol.
Preparation reads it back before confirming; it never alters displayed artwork.

Restart/disconnect does not auto-restore or start a game. The phone launcher
detects a retained original when opened, and recovery inspection shows exact
stage with explicit target/account checks. A corrupt/incomplete/version/identity/
target mismatch fails without resetting the file. Restore validates the original,
marks restoring durably, changes only the phone player, verifies the restored
bytes/frame/source/play intent, then acknowledges restoration atomically.
The original is **not deleted**, including after acknowledgment; a new prepared
record can replace only an acknowledged record after a local 60s cooldown.
Cancellation keeps recovery required. A newer manual phone choice is replaced
only by the explicit restore confirmation, never on a background/account callback.

Hardware automatic replacement is unavailable: staged selection, slot number,
hash or unknown/all-01 metadata alone cannot recover original bytes or scheduling.
No backpack protocol/cache/reserved55–59 change or physical command was added.
Future hardware exchange needs reliably recoverable original bytes/playback and
the actual matching device/full20 descriptor before it can even be considered.
No current screen claims that requirement is met.

The future-application policy requires one durable prepared original, complete
bounded validated incoming bytes, matching local transaction/session/account
epoch, unexpired state and **both peers' independent explicit game-enable and
ready acknowledgments**. Cancellation/expiry/cooldown cannot grant replacement.
The recovery tool itself models prerequisites and starts no peer transfer.
The later phone-only game source below now supplies separate operational game
consent, authenticated transfer, apply and local minimal Met cards. Synchronized
scenes and hardware exchange remain unavailable. Discovery/friendship/OS
permission cannot enable a game.

Received swaps is a separate owned local collection (20 originals/50MB, <=5MB
each) with immutable transaction-scoped receipts, payload validation and supplied
attribution. Preview is isolated from the live phone target, initially still,
foreground/reduced-motion aware; explicit Save creates an independent phone-library
copy and Remove touches only that received record. Manual import is clearly
labeled **not a verified peer transfer or encounter**. Exact receipt IDs dedupe
only their transaction; identical private images in other transactions remain
separate. No peer paths, cloud/private-library scan/upload, global content dedup,
location or encounter timeline is stored.

Fourteen deterministic recovery/restart/corruption/wrong-target/consent/readiness/
receipt/restore fixtures are prepared, all validation unexecuted. Source-complete
PURPLE does not mean safe automatic exchange, hardware recovery or beta readiness.

### Actual phone-only automatic GIF game — PURPLE/source only

The phone-library launcher now has a separately consented automatic game. Actual
`gifSwapPresenceEnabled` and current authenticated `/social/swap-presence` key/
consent state are mandatory; friend discoverability is never a fallback. Explicit
Enable registers a new volatile Curve25519 public key, captures Stop-all revision,
retains the initial exact original durably, and opens the phone canvas. The
explicit risk disclosure covers automatic display/sharing of the currently chosen
GIF (including private-origin artwork), minimal service name/card, retained
recipient copies and unexpected mature/offensive images. There is no per-encounter
popup; enabling the game, not friendship/discovery/OS permission, supplies consent.
Requests-disabled strangers may play without changing request preferences.

The implementation uses a purpose-separated fixed game service
`E28D4000-5B96-4B65-AD2E-E2156EA61621`, token read `.4001`, acknowledged-write
inbox `.4002` and notify outbox `.4003` with the same suffix. It reuses existing
bounded token-read/decoder policies but deliberately owns independent radio
managers from friend discovery and never touches backpack GATT. Advertising uses
only the fixed service UUID, no unsupported iOS service-data/name/stable IDs.
Friend/game stop controls remain independent; global stop, account, permission
loss and background close both as appropriate. Actual dual-manager coexistence/
advertising on iOS is unverified and errors are explicit, not silently merged.

Both sides independently read/resolve each other's **game** token before trusting
the service-returned account/key/card. A peer-supplied name, account claim or hello
token is not substituted for an observation. Deterministic initiator role and
fresh nonces bind origin, session, both accounts, token/key pairs and roles into
one transcript. X25519 possession proof, HKDF-SHA256 directional keys and AES-GCM
with transcript/role/counter AAD protect bounded application messages. Strict
counters reject reflection/replay/out-of-order frames; ephemeral private keys,
tokens and radio identifiers are never persisted. This trusts the service binding
and does **not** claim verified proximity, anti-relay or audited E2EE.

Current scope intentionally accepts GIFs <=128KiB, not covert still conversion.
A separately constructed outgoing copy strips comments/non-loop application/
trailing metadata while retaining compressed image blocks, graphic controls,
centiseconds/repeats. Unsupported rendering extensions fail rather than silently
alter the source. Safe author/license credit is retained; source/private URLs
and credentials are not transmitted. The original remains unchanged and is the
recovery source. Complete incoming bytes must pass length/hash/sanitized-GIF/
resource/composition validation. Malformed, duplicate/out-of-order chunks and
unavailable current authorization fail closed, never falling back to unverified
offline identity.

Actual GATT framing is versioned, bounded and backpressured: <=4096-byte outer
frames, <=512-byte media chunks, <=32 queued application frames, acknowledged
characteristic writes or ready-to-update notify flow. A 45-second exchange bound
and token expiry stop work. ATT success is **not** a ready acknowledgment.
Both peers send application payload-ready and matching ready-ack after full
validation; current service consent/key/access is rechecked before apply.
The shared owned recovery actor records the next replacement before only the
expected-generation phone canvas can change. Initial original bytes/playback
remain across consecutive swaps, with a 60-second cooldown and no same-account
ping-pong within an armed game. Other target/new manual selection invalidates
ownership. Paused/motion/data-saving/brightness/awake choices are not forced.

Final application receipts distinguish locally applied from peer-acknowledged
application; disconnect/lost acknowledgment is uncertain, not exactly-once.
Stopping/failure erases keys, stops local radio first, and retains explicit
original recovery. The phone control overlay exposes Stop/restore. Restore
requires the known original/current target/account and cannot automatically
overwrite a newer manual selection. Token rotation is only within the original
armed end/key, between exchanges; expiring transfers stop rather than mutate
their transcript or extend consent. Lost arm/rotation acknowledgment has explicit
current-login reconciliation/withdrawal, no automatic retry/restart.

Validated received GIFs use the separate Received swaps collection with normal
explicit Save/remove. Minimal account-scoped local Met cards persist only ID,
display name and request availability—not keys/tokens/peripheral IDs/RSSI,
meeting time, coordinates, distance or a synced encounter history. Cards say
**Not friends yet**, have default initials/no avatar/profile grant, and expose
explicit current-service request, local dismissal and block. Existing relationships
remain service-authoritative; games never create friendship automatically.
The later purpose-specific peer-incident source below now supplies deliberate
game/Met/owner/admin controls against the new private endpoint. Message/event/
catalog reports are not repurposed, no success is faked and no private artwork
is copied to administrators.

Friend-nearby start now consumes `nearbyDiscoveryControlRevisionEnabled` and
returned `locationControlsRevision`, sending the captured `expectedControlsRevision`.
Advertised revision control never silently defaults to zero. Omission retains
only genuinely pre-stop legacy behavior; stale/missing post-stop captures fail.

Eighteen new deterministic service/codec/crypto/transfer/consent/replay/bounds/
recovery/late-account fixtures are prepared; **all validation is unexecuted**.
No radio, physical peer transfer, cryptographic interoperability, consolidated
compile/test, background, signing or beta-readiness result is claimed. Hardware
exchange, UWB/ranging, synchronized scenes and production activation remain
unsupported/deferred. Peer reports are separately source-coded below, unvalidated.

### Private peer-incident controls — PURPLE/source only

The new purpose-specific backend source (`f485ee6` plus local documented
refinements, UNVALIDATED) enables deliberate report selection from an authenticated
game peer or retained minimal Met card. The selected ID/name is copied into an
immutable current reporter/catalog/account-epoch/role context before stopping
the game. Stop alone does not erase that explicit selection. Account/server/
role/view changes cancel drafts and reject late results. No untrusted peer-wire
name/ID or arbitrary target-profile lookup is used to substantiate an allegation.

The explanation starts blank, category is explicit and consent unchecked.
Only claimed UUID/category/trimmed1–1000UTF16 explanation/consent is submitted;
no automatic GIF/bytes/hash/screenshot/chat/URL/location/scan/encounter metadata
is copied. Unknown valid claimed identifiers are not confirmed as accounts.
All report/receipt/review DTOs require **claimVerified:false**; resolved/reopened
does not certify misconduct, identity, proximity, an encounter or account existence.
Create/review never takes an account action. Ordinary local Stop/block/remove
controls remain independent.

Account > My private peer incidents provides 24-row owned description pages and
an explicitly selected **metadata-only withdrawal mode**. The independent
`peerIncidentWithdrawalEnabled` route works without a usable description key,
game/friendship/event access or even the general social-feature flag. It only
authorizes peer-reports receipts/withdrawal, not another social/profile endpoint.
Expired rows awaiting cleanup can still be withdrawn at their exact captured
revision. `descriptionsIncluded:false` is required; receipts reject explanation/
category/ciphertext/review fields. Key loss disables description/create/review,
not a fake empty successful list. A conflict retains captured revision intent
until an explicit reload/reselection, never automatic retry or rebase.

Current global administrators have a separate retained-case pager and captured
revision resolve/reopen review with a deliberately typed1–1000UTF16 staff note.
Only staff receive reporterId/latest review; owner DTOs reject staff fields.
Notes and explanations render as literal text. Admin role/key loss discards
private visible data/drafts; no private target profile/media/general-chat or
ban/block grant is obtained. Staff review still requires accountActionTaken:false.

Server-relative read clocks only label case creation/retention, not arrival or
meeting time. Description reads stop at exactly30days; receipts/known withdrawals
remain independent while bounded500-case cleanup catches up. UI discloses100/account,
5000global,20write/120read quotas and by/about account erasure; no forensic
journal/backup erasure claim. Existing authenticated request-proof and expected-
account guards are reused; no key/provider is provisioned or bypassed.

Sixteen deterministic DTO/selection/consent/UTF16/revision/keyless/late-account/
ownership/current-role/expiry fixtures are prepared, all validation unexecuted.
These source screens and the new backend source are not covered by prior passing
test totals. Consolidated compilation/tests, actual privacy/role/key-loss/
retention/visual/device behavior and deployment remain separate acceptance gates.

### Friend invitation QR / camera parity — PURPLE/source only

Friends & profile and Add friends / Look for friends now link to **My friend QR /
Scan / Manual invite**. Explicit Create obtains a revocable 15-minute invite;
CoreImage renders its configured-origin `/social#invite=TOKEN` locally, never
through an external QR service. Only that fragment token is shared: no credentials,
private-library keys, coordinates or profile metadata. Deadlines use server time;
own Revoke hides the QR/link immediately and calls the owner endpoint. Creating
another invitation is not claimed to revoke older invitations automatically.

Explicit Scan is the only camera entry. The actual `Info.plist` camera description
was extended; the scanner checks it before requesting permission, handles
denied/restricted/unavailable states with meaningful errors and keeps manual
link/token input available. AVFoundation capture/setup/stop runs on an owned serial
queue, with a dismissal race guard; background, permission change, dismissal and
account change stop scanning without restart. No camera was initialized or used
while preparing this source/fixtures.

Scanned/pasted input accepts only a canonical token or exact configured catalog
HTTPS `/social#invite=TOKEN`, rejecting foreign origins, userinfo, query/path/
encoding tricks, other-purpose QR data and oversized input. Consumed fragments
are removed from native text/navigation state; tokens/previews remain memory-only,
never logs/backups. Authenticated preview returns only name/ID/expiry/eligibility.
It does not look up avatars, unlock profiles or send a request. Another explicit
confirmation rechecks exact inviter/expiry/revocation/account before consuming
the invite to request friendship. Recipient acceptance/existing friendship
remains separate; no automatic accept, location/discovery/game/library grant.
Cancellation invalidates late work. Native universal-link OS association/rollout
is not provisioned; camera/manual paste works without claiming that integration.

Twelve deterministic decoder/link-safety/preview/cancellation/camera-policy/
late-account/owned-revocation fixtures are prepared, not executed. Actual camera/
permission/readability/expired-link/physical workflow and consolidated compilation
remain pending. No peer transfer or new game API was started.

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
slice passed unsigned Mac compilation and all six replacement tests in
[42153544210](https://github.com/ErrantActions/-led-backpack/actions/runs/42153544210):
196 executed, zero failures and the exact one unsigned Keychain skip, at
`c9c9e23` / Xcode 27.1 / Swift 6.4 / simulator SDK 27.1.
Physical/deployment tests remain separate.

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
use a MapKit fixed-venue editor with explicit numeric alternatives in the new
PURPLE event source follow-up above. Place/address
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
That original checkpoint added no gallery upload/reordering or publication.
The new PURPLE event source follow-up above adds organizer gallery controls;
neither slice scans or publishes private-vault contents.

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
and SDK validation remain unproven and are not provisioned/activated here. The later
guest, fresh-auth key recovery, immutable upload snapshot and authenticated SSE
source slices close the original source gaps, but do not enable enforcement.
Their focused batch at `7012e79` / `42158810963` passed unsigned compilation and
153 tests, zero failures and the exact one unsigned Keychain skip, including
five recovery, five snapshot and three stream tests. Ordinary authenticated requests use official
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

### Guest native integrity checkpoint

The separate frozen HTTP-v1 guest source now obtains a real server anonymous
session, binds null user scope/token/body/query through the official SDK adapter,
uses only `X-Catalog-Integrity-Session` for guests and adopts the anonymous
enrolled key after successful primary login. Authenticated calls omit that header;
OFF/missing gates preserve legacy login without integrity Keychain calls.
Unsigned Mac run `42155215746` attempt 2 at `c748042` passed 199 tests, zero
failures and one exact unsigned Keychain skip, including three guest mocks.
This does not prove Apple device attestation or activate enforcement.

### Per-conversation alerts

Per-conversation notification mute is a separate frozen `f1005e1` source slice.
Messages > Alerts for this conversation appears only with the actual
`chatNotificationPreferencesEnabled` capability. Owner-only settings bind exactly
one direct thread, private organizer question or group/event room and the displayed
revision. A failed save retains its immutable intent; explicit reload may retain the
choice but never silently save against a new revision. Late account/origin/access
changes cannot apply a result. Mute suppresses only new message alerts, not messages,
history, unread counts, typing, memberships, invitations or existing inbox/activity
links. Backend producer/queued-delivery filtering remains server-owned. This source
passed its separate unsigned Mac checkpoint `42157183297` at `8d7e107`:
205 executed, zero failures and one exact unsigned Keychain skip, including six
conversation mute cases. No provider/enforcement activation occurs.

### Deliberate message incident reports

The separate frozen `357ecd0` source adds explicit incoming-message incident
explanations and owner-only retained report/withdrawal controls. No original
message text, media, place/event or neighboring history is automatically copied.
Only a deliberately entered category/explanation, consent and opaque identifiers
are submitted; literal/script-looking explanation text renders as text. The
existing original message remains unchanged. Identical retries preserve captured
bytes; conflicts require explicit review. Owner withdrawal and restricted admin
review bind displayed revisions, never unlock private chats, auto-block or delete
messages. Missing `chatReportsEnabled` hides controls. Focused report/auth Mac run
[42159868752](https://github.com/ErrantActions/-led-backpack/actions/runs/42159868752)
at `0c5850e` passed unsigned app/test compilation and 49 tests, zero failures/no
skips, including all six report cases. Provider/production/signing/device/release
remain unchanged.

### Batch send queue

Long-press a library GIF and choose **Add to send queue**, or open **Library >
Send queue > Add local GIFs** to select several artwork tiles. The queue retains
up to 60 entries in schema-1 local storage/backups; repeated source IDs and
byte-identical independent files are allowed. This is not content deduplication.
Reorder entries with Edit and assign distinct destination slots. Automatic
assignment uses empty ordinary slots (2–54); reserved slots 0/1 and future-feature
slots 55–59 require an
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
- Catalog sessions and account-deletion receipts stay in Keychain. The connected
  backpack ID is sent privately when checking/adopting that device; firmware,
  passwords and GPS are not included in that request.
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
