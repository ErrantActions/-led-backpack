# Native TODO

Status is **source implementation**, not native compilation, device validation,
TestFlight availability or a claim that the product backlog is finished.

## Authorized unsigned Mac validation

- [x] Owner authorized completed native source commit/push and GitHub-hosted Mac
  unsigned compilation/focused testing. Signing, TestFlight, live operations and
  production key/model/APNs provisioning remain outside this permission.
- [x] Actions enabled; existing `xcode-27` runner recently passed exact Xcode 27.1
  preflight. The new manual validation rechecks actual installed Xcode/SDK/device.
- [ ] Complete unsigned app/test compilation and focused native tests; record the
  actual run/toolchain/result. Do not count parsing as compilation.
- First actual run `42135859007` at source `6f13b25` verified Xcode 27.1
  (`27A9275`), Swift 6.4 and simulator SDK 27.1. Compilation failed with exit65:
  a local `state` binding shadowed the vault store property. Tests did not run.
  The member assignment is corrected; another authorized run must verify it.
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
- [ ] Authorized Swift type-check/XCTest and portrait/landscape visual review.
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
- [x] 16 targeted model/mock tests prepared (not executed); source grammar,
  method/type-scope, privacy/control-isolation and whitespace checks only.
- [ ] Authorized Xcode 27.1 Mac compile/type-check/XCTest. No such environment is
  available in this Windows session; grammar parsing is not compilation.
- [ ] Real iOS MapKit search/tap/drag/circle/reorder/fit interactions, network loss,
  private-event/member/owner revocation and concurrent 409 recovery.
- [ ] Visual/VoiceOver/Dynamic Type/Reduce Motion/contrast/transparent-material
  review, map attribution, foreground lifecycle and no-location-permission proof.
- [x] Verified native gate: actual `eventsEnabled`, explicit Maps/search consent
  and current owner/access/revision checks. Web `eventMapPlanningEnabled` is not
  a MapKit dependency; false/missing/changed web configuration retains drafts.
  MapKit never consumes the web tile URL or asks users for a map key.

## Next eligible source slice: automated avatars

Backend source handoff: `6d4f56b`; production remains `6bed90c`.
This is not implemented by the MapKit gate correction.

- [ ] Read the frozen automated-avatar contract before native work; do not infer
  source-only capabilities on the live service.
- [ ] Gate new upload/retry UI on actual AI approval/upload availability, preserve
  authenticated canonical media resolution, and bind retries to the displayed
  version. Do not retain a manual-approval workflow for the automated contract.
- [ ] Handle allowed/mature/blocked/failed/pending states and mature-preference
  changes without stale media, including owner/admin contexts.
- [ ] Native mocks, authorized compilation and real model/device validation remain
  separate; no provider/model/key activation, CI or live operations is authorized.
