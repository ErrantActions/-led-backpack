# Aurora Messages

November 10, 2026. **Interactive design prototype, not a native app change.**
Open [Aurora Messages](../layouts/messaging.html).

## Familiar behavior, original identity

Use the familiar Messenger interaction vocabulary already reviewed on the
[app reference board](../screenshots/app-reference-board.html#app-454638411):
avatar-led recent conversations, search, simple filters, a focused bubble thread,
an anchored composer and contextual secondary tools. Keep Aurora's original
mint/lavender/rose spectrum; no Meta artwork, logos, exact screen reproduction,
or product-feature promises.

The prototype implements:

- Search of loaded conversation names/context; separate Chats, Groups, Requests.
- Compact list-to-thread navigation with focus returning to the selected row.
- A useful inbox/thread split on a wide container. The book study leaves an
  illustrative fold band; narrow windows fall back to the complete compact task.
- Draft and unsent attachment retention per conversation while folding, changing
  layout, searching, navigating back, or opening another conversation.
- Incoming/outgoing bubbles, group sender labels and room unread counts.
- New-message selection from eligible sample contacts, not address-book access.
- Multiline composer, explicit Send, and Ctrl/Cmd+Enter without breaking IME.
- Private artwork choice and removable unsent preview: no visible GIF names.
- Explicit request acceptance/decline and group invitation history review.
- Offline/read-only/revoked access states and immutable failed/uncertain retries.
- Optional six-second **sample** typing indication; restrained bubble entrance.
- Reduce Motion, contrast/transparency preferences, accessible controls and
  keyboard-dismissable dialogs.

All names and conversations are fictional. Sending adds only a local preview.
There is no network, server mutation, GPS, BLE, push registration or sensor call.
Reload resets this prototype; it is not durable message/draft storage.

## Preserve the real contracts

See [backend boundaries](backend-contract-boundaries.md).

| Surface | Required distinction |
|---|---|
| Ordinary DM / private organizer question | Same person can have separate histories; never merge by display name or peer alone |
| Group / event-wide room | Membership, `canSend`, archive state and authorized history win over cached rows |
| Requests | Acceptance is conversation permission, not friendship or library/location consent |
| Group invitation | Show the owner's history choice; do not silently override it on acceptance |
| Recovery | Separate text-only, revocable contract; absent live v2 gates mean no working recovery entry here |
| Outgoing status | Server persistence is not delivery or peer reading; no seen ticks, online dots or calls |
| Retry | Keep the exact intent ID and bytes; do not recompose an uncertain send |
| Offline | Retain draft; do not silently queue or replay a send on reconnection |
| Revoked access | Remove visible history/identity, attachment previews and open private dialogs; re-fetch authorized state before restoration |
| Typing | Explicit opt-in before transmitting; expire at six seconds, no draft content |

The current native `RecentChatContact` DTO has profile, event context and last
message timestamp, **not an aggregate snippet or direct-message unread count**.
The design uses a context subtitle until currently authorized history is loaded;
room unread counts use the room contract only. No new aggregate endpoint is
assumed. Search is local to loaded conversations, not a promise of global
message search. A future query must not bypass context/history authorization.

The prototype's access/result controls simulate states, never fetch config or
certify live availability. Returning the selector to Available is an explicit
fixture reset/recheck demonstration, not production cache reauthorization.
Local preview results are labeled **Preview only**, not sent/delivered.
The sample saved bubbles illustrate server persistence, not recipient receipts.

## Native wiring

- [Inbox](../../ios/LEDBackpack/CommunityChatViews.swift): replace visual list
  composition without moving authorization/session lifecycle into layout branches.
- [Context, DTOs and send intent](../../ios/LEDBackpack/CommunityChatModels.swift):
  retain opaque IDs, room/direct/event scopes, immutable UUID/body and the
  4,000-UTF-16-unit message bound.
- [Conversation implementation](../../ios/LEDBackpack/CommunityChatViews.swift):
  preserve outbox reconciliation, live invalidations, view-token invalidation,
  permissions, typed errors, attachment authorization and history retention.
- Existing fixed-place, event/playlist reference, reporting, blocking, room-info
  and notification controllers remain separate native destinations. The prototype
  shows artwork selection and explanatory action previews, not replacement API
  implementations. Do not remove existing supported native actions on integration.

The standalone prototype added no API, native Swift changes or deployment.
The subsequent native integration now uses these interactions in the existing
SwiftUI inbox/conversation controllers, plus scoped process-memory drafts and
local typing expiry. The exact native candidate has separate Mac CI and UI
screenshot gates; the browser proof below does not certify it. Actual keyboard,
Dynamic Type, VoiceOver and native Duo regions still need supported Apple
hardware acceptance. Wide flat windows show both panes; active native divisions
retain the complete navigation task rather than copying the prototype fold band.

## Browser verification

[Recorded proof](../layouts/messaging-validation.json): 50 behavior checks and
90 layout cases across five widths, two heights, three layouts and three views.
No horizontal overflow, clipped structural containers, displaced composer or
visible controls smaller than 44 pixels. Inbox previews intentionally truncate.
Compact inbox/thread and Duo book layouts were also reviewed visually.

Draft focus, caret and a scrolled history position survived folding. Failed and
uncertain retries retained their exact intent. Revocation cleared private
surfaces; stale request/attachment actions rechecked access. Typing expired after
six seconds, and Reduce Motion disabled typing and bubble animation.

`node research\validate-research.mjs` checks script syntax, documentation links,
proof consistency and the tested prototype's SHA-256 fingerprint. It does **not**
rerun the browser interactions. Repeat those checks when changing the prototype.
