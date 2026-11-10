# Backend boundaries for the UI design

Coordination received November 10, 2026 from LED-Backpack-Backend.
This records that session's source/live verification; it is **not an independent
deployment check by the design pass**. Recheck current config and endpoint
authorization during implementation. No API edit or deployment is requested.

Use with the [design language](design-language.md) and
[native acceptance matrix](ios-duo-ux-research.md#9-native-acceptance-matrix).
Compact, expanded and Duo arrangements preserve exactly the same consent,
authorization, operation identity, error and state semantics.

## Source is not availability

The backend reports recovery v2 in local source `c115a1a`, with a passing strict
build and 653 backend tests. That source is **not deployed**.
Historical headings in its API documentation are not live feature detection.
All endpoint paths below are relative to `/api/v1`.

| Reported live config | Design consequence |
|---|---|
| `connectedDeviceRegistrationEnabled=true`; registration version absent | Do not infer the v2 adoption contract from the older registration flag |
| `deviceRecoveryEnabled` absent | No functional live recovery/adoption-v2 entry; a clearly labeled design study is not availability |
| Messaging, group/event chats, live chat, media, pins, references, requests and reports enabled | Still require the current context's authorization and capability checks |
| Event capabilities, playlists and managed cloud enabled | A public catalog, private storage and community submission remain distinct |
| Apple push, AI artwork redraw, user-held cloud encryption, cloud device adoption, ownership, password recovery and integrity enforcement/ready disabled | Do not present these as working capabilities or silently substitute another operation |

Use the actual current `/config` and endpoint authorization, never fixture
availability. A missing flag is not an implicit grant. In-app notifications
are not proof that APNs is enabled.

## Recovery v2: gated, revocable and text-only

- Connected lookup accepts `{consent:true,vendorDeviceId}` and returns
  `available`, `owned`, `registered-elsewhere` or `ambiguous`, with
  `recoveryEnabled` and `serverTimeISO`. An off/ambiguous result discloses no
  foreign name, avatar or contact grant. Never select an arbitrary owner.
- Foreign registration returns `409 device_registered_elsewhere`; a legacy
  multiple-account collision is `device_identity_ambiguous`.
- Per-device recovery opt-in uses `PATCH /devices/:id/recovery` with
  `expectedRevision`, `enabled`, and explicit `consent:true` when enabling.
  Default is off. Explain minimal name/avatar disclosure and nonfriend
  found-device contact; this is not global discovery or location consent.
- A permitted foreign lookup may supply a minimal owner and a contact grant.
  The grant lasts 120 seconds and is bound to viewer, login, device, owner and
  revision. Scoped avatar requests use `X-Catalog-Device-Recovery-Token`.
  Neither the token nor cached owner card grants permanent profile access.
- Initial contact uses `POST /devices/recovery/contacts` with `authorization`,
  `clientRequestId`, `text` and explicit consent. Retrying preserves the same
  request identity and intent.
- Inbox pagination is 24 conversations per page. Thread history uses
  `before=<sequence>` and `limit=1..50`, with `hasMore` and `nextBefore`.
- Conversation states are `pending`, `accepted`, `closed`; roles are `owner`
  and `finder`. Respond/decline/close use `expectedRevision`.
  The owner responds through `POST .../:id/respond`.
  Only accepted contexts permit `POST .../:id/messages`.
- A first-reply UX must preserve that acceptance transition before sending;
  collapsing the UI steps is not permission to bypass server acceptance.
- Reply text is trimmed, well-formed Unicode, 1..1,000 UTF-16 units.
  Recovery timestamps are ISO strings and contexts expire after 30 days.
- Report through existing message reports with `kind=device-recovery` and
  current message access. Close, block and report have different consequences.
- Opt-out, block, transfer, unlink, disable/deletion or collision changes revoke
  access. Re-enabling does not revive old grants or conversations.
- No friendship, ordinary DM history, location, library or device-control grant
  follows from recovery. No room attachments, typing/SSE or delivery/read receipt
  contract is implied by the text-only recovery API.

Native integration surfaces include [recovery views](../../ios/LEDBackpack/DeviceRecoveryViews.swift),
[thread state](../../ios/LEDBackpack/DeviceRecoveryStore.swift) and
[client requests](../../ios/LEDBackpack/DeviceRecoveryClient.swift).
These links identify integration surfaces, not a new completed alignment audit.

## Chat: acceptance is not recipient delivery

- Direct/private-organizer and group/event-room contexts remain separate.
  Membership, `canSend`, archived state, blocks and retained-history access win
  over cached content.
- A persisted `{message}` response establishes server acceptance/persistence,
  not recipient delivery or reading. No blue ticks or seen timestamps are
  inferred from typing, SSE, APNs or unread bookkeeping.
- `POST /social/chats/:id/read {throughSequence}` advances only the current
  user's unread position. It is not a peer receipt.
- A same-intent retry retains `clientMessageId` and bytes. Changed intent with
  that ID conflicts (`409 message_id_conflict`); do not silently replace its ID.
- Local queued/sending/failed/offline/uncertain states remain distinguishable
  from server DTO states and acknowledgements.
- `sse-v1` events invalidate state; reconnect and fetch authorized content.
  Polling is reconciliation/degraded operation, not a promise of live delivery.
  Typing expires after six seconds and carries no draft content.
- Room message timestamps are Unix milliseconds, unlike recovery ISO values.
  A `viewToken` is an invalidation marker, not a credential; discard stale cache.
- Thirty-day retained history is not deleted-message recovery or screenshot
  recall. Messaging and managed cloud are server-managed encryption, not E2EE.

## Community upload is not private backup or publication

- `POST /items` is deliberate community submission. Preserve normal auth/client
  headers and `X-Catalog-Upload-Policy: community-review`; multipart ordering is
  exactly metadata JSON first, then one file.
- A `201` initially establishes shared/pending submission, not approval.
  Owner status comes from `/me/items`. Existing private items enter review only
  through the separate owner submit action with explicit sharing attestation.
- DTO statuses are `pending`, `approved`, `rejected`, `deleted`.
  AI states are `disabled`, `queued`, `running`, `done`, `failed`.
  Keep `requiresAdminReview`, report holds and quarantine explicit; approval is
  not permanent availability. Do not invent server lifecycle states.
- AI processing has no fabricated percentage. Disabled AI remains manual
  pending; uncertain/flagged/failed review requires an administrator.
- GIF bounds: at most 5,000,000 bytes, 1..120 frames, sides at most 4,096,
  total decoded pixels at most 40,000,000. Single-frame GIFs are valid.
  No forced animation, silent frame truncation or success-shaped fallback.
- One processing upload at a time; surface `503 upload_busy` and backoff.
  Ordinary quotas are 100 active/10 daily; handle `409 duplicate_content`.
- Existing `DELETE /items/:id` is admin-only. Do not design it as a universal
  owner delete operation or infer one from a generic trash icon.

## Device association is not a hardware result

- The mutable/clonable vendor ID is exactly ten printable ASCII bytes 33..126,
  case-preserved and not trimmed. Factory/uniform placeholders are rejected.
  A phone-local peripheral UUID is not universal device identity.
- Bound connected-device edits allow nickname only. Send returned model/matrix
  unchanged; modifying them conflicts with `connected_device_metadata_read_only`.
  Missing readable identity remains local/unverified.
- Account association does not establish a BLE connection, physical ownership,
  panel transfer/playback completion, or firmware compatibility.
- Keep server catalog/download/upload outcomes separate from native transfer
  progress, cancellation, partial-write error and the actual supported receipt.
- Firmware catalog availability permits storage/download, not a compatibility
  guarantee or flashing authorization.
- Planning, nearby eligibility, BLE/RSSI, GPS, pairing and account association
  are separate evidence and consents. No precise range or ownership follows
  from labels or RSSI.

## Gap report, if one is established

No new API gap is established by this handoff. Existing recovery-v2 source/native
alignment and guarded deployment remain separate pending work, not authorization
to deploy or change semantics for a design.

Send LED-Backpack-Backend:

1. Affected screen, state and deliberate action.
2. Current endpoint/method, request shape and observed response/error.
3. Missing state or field, with a reproducible mismatch rather than a mock need.
4. Current config, authorization, consent and revocation implications.
5. Account/session/cache invalidation and retry identity implications.
6. Compatible acceptance criteria and affected existing clients.

Do not introduce a speculative send-job, delivery-receipt or telemetry API.
