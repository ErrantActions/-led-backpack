# Native TODO

Status tracks source and explicitly identified Mac validation checkpoints.
Neither source nor simulator success proves device behavior, TestFlight
availability or that the product backlog is finished.

## Authorized unsigned Mac validation

- [x] Owner authorized completed native source commit/push and GitHub-hosted Mac
  unsigned compilation/focused testing. Signing, TestFlight, live operations and
  production key/model/APNs provisioning remain outside this permission.
- [x] Actions enabled; existing `xcode-27` runner recently passed exact Xcode 27.1
  preflight. The new manual validation rechecks actual installed Xcode/SDK/device.
- [x] Complete unsigned app/test compilation and focused native tests; record the
  actual run/toolchain/result. Do not count parsing as compilation.
- First actual run `42135859007` at source `6f13b25` verified Xcode 27.1
  (`27A9275`), Swift 6.4 and simulator SDK 27.1. Compilation failed with exit65:
  a local `state` binding shadowed the vault store property. Tests did not run.
  The member assignment is corrected; another authorized run must verify it.
- Run `42136200430` at `b998c5e` compiled and executed 149 focused native tests.
  Overall result failed: nine assertions/failures across copy-fixture selection,
  signature-byte comparison and unsigned-host Keychain entitlement. MapKit and
  phone classes passed; this is not an overall validation pass or device proof.
  Fixture/interop assertions are corrected; only exact unsigned-simulator
  `errSecMissingEntitlement` skips the signed-host Keychain integration test.
- Run [42138289158](https://github.com/ErrantActions/-led-backpack/actions/runs/42138289158)
  at `2e8fee2` **passed** unsigned app/test compilation and 155 tests: zero
  failures, one exact missing-entitlement Keychain integration skip.
  Xcode 27.1/build `27A9275`, Swift 6.4, simulator SDK 27.1, iPhone Duo,
  macOS 27.0.1. This includes six AI-avatar tests, 16 MapKit and 11 phone tests.
  Real signed-host Keychain policy remains unverified.
- [ ] Physical-device/network/provider and visual validations remain separate.

The manual `native-compile.yml` workflow is intentionally separate from
`ios.yml` and the TestFlight validation gate. Focused/compile-only success must
not silently become release approval.

## Phone-only local display

- [x] Independent Library > Phone display entry with no account, cloud, panel,
  slot selection or Bluetooth connection requirement.
- [x] Explicit Display on phone versus Send to backpack actions; phone actions
  have no peripheral writes and do not replace the hardware target's artwork.
- [x] Full-screen black aspect-fit, nearest-neighbor still/GIF rendering and
  local library plus bounded local image/GIF file selection.
- [x] Reuse Aurora headings, mint/lavender/rose accents, glass surfaces and
  primary playback controls; controls fade without tinting the artwork.
- [x] Play/pause with preserved playhead, GIF timing/repeat metadata and still
  images without artificial frame duplication.
- [x] Reduced Motion defaults to a still frame until explicit Play; offscreen/
  inactive playback pauses, decoded frames release, and optional keep-awake
  restores the previous idle-timer value. Brightness is never modified.
- [x] Self-contained Codable artwork/playback snapshots can restore original
  bytes, source ID and pause/playhead intent without requiring a device slot.
- [x] Focused source test fixtures and source-only documentation/grammar checks.
- [x] Authorized unsigned Mac compilation and 11 focused phone tests passed.
- [ ] Portrait/landscape visual review.
- [ ] Inspect Dynamic Type, VoiceOver, Reduce Transparency/contrast and reduced
  motion on-device; source styling alone is not proof of visual quality.
- [ ] Real-device cold start/offline use with Bluetooth denied/no backpack.
- [ ] Validate GIF disposal/repeat timing, Reduce Motion, background/lock, file
  picker return, accessibility and idle-timer restoration on actual iOS.

## Future automatic GIF Swap (not implemented)

- [ ] Do not implement/enable swaps or discovery as part of phone playback.
- [ ] Define consented/authorized exchange and validate received media first.
- [ ] Journal the original phone snapshot safely before replacing artwork, then
  prove crash/restart/disconnect recovery before enabling automatic swaps.
- [ ] Generation-bind automatic restoration so a newer explicit phone choice is
  never silently replaced by an old checkpoint.
- [ ] Preserve independent phone versus hardware playback; no slot requirement.
- [ ] Keep received artwork in a separate received-swaps collection.
- [ ] Games, nearby discovery, GPS/UWB/NFC flows remain separate future work.

Full product/backend backlog is maintained by its parent implementation task;
source-only availability must remain capability-gated.

## Eligible Apple Maps organizer slice

Backend eligibility: verified platform-v2/source `6bed90c`. Later private-account
badges, gallery ordering and chat source are not included in this native slice.

- [x] Typed fixed venue/route/checkpoint/live finish-reward models, canonical
  lowercased wire UUIDs and the exact `startsAtISO`/`endsAtISO`/`serverTime` keys.
- [x] Purpose-built MapKit venue search/placement, radius circles, draggable fixed
  pins, start/intermediate/finish editing, intermediate ordering and guide shape
  editing/fit-all. No user-authored JSON or normal numeric-coordinate workflow.
- [x] Per-page Apple Maps/search opt-in, no user-location annotation/manager,
  participant map, directions request, tile URL/key or navigation/safety claim.
- [x] Aurora layout/controls, named community versus same-event protected artwork,
  explicit unavailable references and no cross-source substitution.
- [x] Immutable captured revisions, preflight owner/access check, retained drafts
  on 409, server-plan inspection and reviewed-version-only discard/reload.
- [x] Shared-progress structural lock; explicit fixed-geometry restoration while
  keeping artwork/finish rewards, with no automatic retry/rebase.
- [x] Participation revision-bound going confirmation and material-review state;
  no automatic progress re-sharing; decline remains available after cancellation.
- [x] 16 targeted model/mock tests passed on authorized Xcode 27.1 Mac CI;
  source grammar/privacy/control-isolation and whitespace checks also passed.
- [x] Unsigned app/test compilation and MapKit XCTest checkpoint passed in
  run `42138289158`. Source parsing was not counted as compilation.
- [ ] Real iOS MapKit search/tap/drag/circle/reorder/fit interactions, network loss,
  private-event/member/owner revocation and concurrent 409 recovery.
- [ ] Visual/VoiceOver/Dynamic Type/Reduce Motion/contrast/transparent-material
  review, map attribution, foreground lifecycle and no-location-permission proof.
- [x] Verified native gate: actual `eventsEnabled`, explicit Maps/search consent
  and current owner/access/revision checks. Web `eventMapPlanningEnabled` is not
  a MapKit dependency; false/missing/changed web configuration retains drafts.
  MapKit never consumes the web tile URL or asks users for a map key.

## Eligible source slice: automated avatars

Backend source handoff: `6d4f56b`; production remains `6bed90c`.
Frozen native contract read at `bfdd5ef`. This slice is independent of MapKit.

- [x] Read the frozen automated-avatar contract before native work; do not infer
  source-only capabilities on the live service.
- [x] Gate new upload/retry UI on actual AI approval/upload availability, preserve
  authenticated canonical media resolution, and bind retries to the displayed
  version. Do not retain a manual-approval workflow for the automated contract.
- [x] Handle allowed/mature/blocked/failed/pending states and mature-preference
  changes without stale media, including owner/admin contexts.
- [x] Six focused AI-avatar model/mock cases passed; prior avatar fixtures
  updated to the frozen AI contract.
- [x] Execute native mocks through authorized unsigned Mac CI and report exact
  compilation/test evidence. Real model/device validation remains separate;
  production/provider/key/push provisioning and live operations stay unmodified.

## Next completed backend source slices

### Immutable event image replacement (`e64affb`)

- [x] Narrow organizer-only existing-image listing/replace entry; no broader gallery,
  badge, publication/reorder controls or admin bypass.
- [x] Metadata-first raster request captures asset revision, complete displayed
  order, selected immutable bytes, descriptions and explicit permission.
- [x] Refresh/conflict retain draft/file and never rebase expected revision/order.
  Cancel/reload is explicit. Lost access removes editing controls.
- [x] New immutable ID/retired ID receipt and post-publication exact order/cover/
  reset approval verification; acknowledged work is verified, never resubmitted.
- [x] Separate unsigned Mac compile and six replacement tests passed in
  [42153544210](https://github.com/ErrantActions/-led-backpack/actions/runs/42153544210)
  at `c9c9e23`: 196 executed, zero failures, one exact unsigned Keychain skip.
- [ ] Physical visual/file-picker/conflict/lifecycle and authorized deployment checks.
- Actual frozen API has no replacement-specific capability flag. The source uses
  `eventsEnabled` plus current organizer access/`canReorder`; unavailable routes
  fail explicitly, not via an invented flag or production availability assertion.

### Frozen App Attest HTTP-v1 source gap checkpoints

- [x] Guest server-session bootstrap, independently reconstructed null user scope,
  guest-only header, qualified login request and guest key adoption to account
  storage after successful primary login; no anonymous header on authenticated calls.
- [x] Separate guest Mac mock/compile checkpoint passed in
  [42155215746](https://github.com/ErrantActions/-led-backpack/actions/runs/42155215746)
  attempt 2 at `c748042`: 199 executed, zero failures, one exact unsigned
  Keychain skip; all three guest tests. Attempt 1 had GitHub's internal
  runner error with no steps/log; retried without settings changes.
- [x] Fresh-auth owned-key recovery source: standard-base64 path encoding, explicit
  REVOKE, owned/current-account/fresh-auth exception, exact receipt and only matching
  local-key clearing; separate integrity epoch, no account/vault identity rewrite.
- [x] Five recovery mocks/compile passed in the focused batch below.
- [x] Protected owned immutable upload stream snapshot/hash source: bounded incremental
  SHA256, source change/link checks, read-only protected snapshot, exact content length
  and stream signed from its bytes; originals are untouched and owned cleanup is explicit.
- [x] Five file snapshot tests passed in the focused batch below.
- [x] Authenticated SSE opening proof source signs the exact GET/query/bodyless
  request through the official adapter, serializes through actual response-header
  acceptance, then retains existing lease/parser/redirect/account cancellation.
- [x] Three stream opening/late-scope/exact upload-wire fixtures passed in the batch.
- Enforcement stays OFF; source/mock compilation does not validate Apple proofs,
  entitlements, signed devices, provider environment or production enforcement.
- Recovery/file/SSE source were validated together after the owner requested batched
  validation. Run `42158810963` at `7012e79` passed unsigned compilation and
  **153 focused tests, zero failures, one exact unsigned Keychain skip**; new
  recovery/file/stream fixture counts are 5/5/3. No broad/editor/phone test reruns.

### Deliberate message incident reporting (`357ecd0`)

- [x] Actual report capability, selected incoming-message action, empty typed
  explanation and explicit consent. Wire data never auto-copies original text,
  media, places, event details or neighboring history.
- [x] Owned bounded reports/revision-bound withdrawal after chat access loss;
  restricted admin report review only, no private-chat/evidence unlock.
- [x] Literal explanation text, captured revisions/intent, conflict retention,
  account/access guards, no automatic block/deletion/punishment or plaintext fallback.
- [x] Focused report/auth Mac checkpoint
  [42159868752](https://github.com/ErrantActions/-led-backpack/actions/runs/42159868752)
  at `0c5850e` passed unsigned app/test compilation and **49 tests, zero
  failures, no skips**; all six report cases passed.
- [ ] Physical/visual/real transport/release remain separate and unclaimed.

### Per-conversation notification mute (`f1005e1`, separate slice)

- [x] Actual `chatNotificationPreferencesEnabled` gate hides missing/false controls.
  Owner/current-access read/write for exactly one room or direct/question context.
- [x] Captured revision/choice bytes, explicit save/reload, retained conflict intent,
  no silent retry/overwrite. Account/origin/feature guards apply after I/O.
- [x] Alerts-only disclosure: no history/message/unread/membership/typing/invitation/
  old inbox/activity deletion or navigation changes.
- [x] Separate unsigned Mac compile and six scoped mute tests passed in
  [42157183297](https://github.com/ErrantActions/-led-backpack/actions/runs/42157183297)
  at `8d7e107`: 205 executed, zero failures, one exact unsigned Keychain skip.
- [ ] Authorized physical/visual/provider/queued-delivery validation remains separate.

- [x] Frozen direct/group/event chat and separate organizer questions, scoped
  history/revisions, live hints/typing and private image/GIF attachments.
- [x] Manual Apple Maps fixed chat pins, no device GPS/tracking.
- [x] Owner notification global/category/channel preferences and activity links.
- [x] Bounded actual SDK/proof-bound APNs registration/token lifecycle source.
- [x] Default-off event reminders.
- [x] Shared community/event cards: frozen backend `8697481`, separate native
  source/Mac checkpoint, not part of `6c2883b`.

Chat/pin source checkpoint: frozen `bfdd5ef`, explicit capability gates;
Account > Messages, friends/recent/group invitations, owner revision-bound
management, explicit event-wide join vs private organizer question, immutable
exact-byte retry intents, paired direct cursors/room view-token invalidation,
authenticated hint-only SSE and explicitly degraded polling, opt-in memory-only
typing, private staged image/GIF attachments, hover/tap deletion, and consented
manual fixed pins. No E2EE/GPS/shared-card/role bypass. Thirteen focused tests are
passed in [42140284682](https://github.com/ErrantActions/-led-backpack/actions/runs/42140284682)
at `6c2883b`: unsigned app/test compilation, 168 tests, zero failures and the
one exact unsigned Keychain skip. Background/permission/gesture/
screenreader/visual and authorized real transport/device checks remain pending.

Notification/reminder source checkpoint: frozen `bfdd5ef`, owner-only
capability-gated private generic activity, global/channel/eight category
preferences with captured revision/account, explicit conflict retention/discard,
unavailable Apple push blocked, and actual default-off event-reminder opt-in.
No automatic RSVP, location or APNs registration is performed. Six focused
fixtures passed in [42141398919](https://github.com/ErrantActions/-led-backpack/actions/runs/42141398919)
at `f34c254`: unsigned compilation, 174 executed, zero failures, one exact
unsigned Keychain skip, including all six notification tests. Actual proof-bound
native APNs remains the next separate slice.

### Native HTTP-v1 App Attest / Apple push source checkpoint

- [x] Actual DeviceCheck key/attestation/assertion adapter, independent ordered
  challenge reconstruction, exact bearer/body/query binding, serial assertions,
  account/origin scope guards and uncertain enrollment rejection.
- [x] Gated Apple-device metadata/register/revoke and opaque activity resolution;
  local acknowledged ID scoped to account/origin/attestation key, never first-device
  guessing. Captured revisions; no blind conflict retry.
- [x] Explicit OS permission and actual token callbacks; supported server permission
  states, bounded variable-length token, foreground/token reconciliation for an
  acknowledged device, logout revocation and remote callback alongside unchanged
  local disconnect notification presentation.
- [x] Activity payload only contributes an opaque UUID; authorized server destination
  opens current feature reads. Phone artwork/playback is not replaced.
- [x] Unsigned Mac app/test compilation and eight codec/mock tests passed in
  [42144043428](https://github.com/ErrantActions/-led-backpack/actions/runs/42144043428)
  at `d51512c`: 182 executed, zero failures, one exact unsigned Keychain skip.
- [ ] Authorized signed physical App Attest/provider/token/delivery/visual checks.
- No credentials, capabilities/profiles/entitlements or production flags are
  provisioned. Missing App Attest/provider flags and unsupported SDK remain blocked.
- The original checkpoint's guest/recovery/file/SSE gaps are now completed source
  slices with the later focused Mac evidence above. Signed Apple/provider, real
  account/token/recovery/lifecycle verification still blocks activation. Lost
  acknowledgments require explicit recovery, not guessed IDs or replay. Provider
  acceptance is not delivery; none of these checkpoints enables enforcement.

### Protected shared reference cards: separate `8697481` slice

- [x] Actual `chatReferencesEnabled` gates, bounded current-conversation community
  GIF/event pickers and strictly scoped authenticated media (no public/cloud fallback).
- [x] Reference-only/exact-retry intents, displayed private-event and participation
  revisions, separate current event review/RSVP path, no invitation/access/progress/GPS.
- [x] Current-viewer unavailable hydration discards private metadata, explicit event
  material/plan changes, IANA timezone dates and approved-only supplied cover paths.
- [x] Direct/room opaque token invalidation, independent five-second reconciliation
  even with live hints, stable message IDs, older-page discard on token changes and
  immediate picker/history/media-policy clearing on mature preference changes.
- [x] Mac unsigned app/test compilation and all eight reference tests passed in
  [42146109178](https://github.com/ErrantActions/-led-backpack/actions/runs/42146109178)
  at `357cba1`: **190 executed, zero failures, one exact unsigned Keychain skip**.
  Xcode 27.1/build `27A9275`, Swift 6.4, simulator SDK 27.1/iPhone Duo. Source
  grammar/static checks also passed, but are not the compilation evidence.
- Failed/uncertain access refresh hides reference metadata until successful
  revalidation; media rechecks policy after I/O. Normal message identity remains
  independent of card reconciliation. Native remote activity hops to MainActor.
- [ ] Authorized native visual/pointer/lifecycle/real transport/revocation validation;
  new source capability remains unavailable on production `6bed90c`.
