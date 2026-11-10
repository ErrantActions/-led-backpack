# Less reading, fewer steps

November 10, 2026. **Design proposal; native controllers are not rewritten.**
See the [atlas](../layouts/design-atlas.html) and
[recorded changes](../layouts/interaction-simplification.json).

## Artwork, not filenames

- Artwork collections show the artwork, without a visible GIF name/caption.
  The whole artwork is the tap target; keep an accessible action label.
- Creation/import does not ask for a GIF name. Eight name/title fields are
  removed from the proposed surfaces. Native integration must keep existing
  metadata internally (or generate a valid stable internal value for a new
  asset), without a naming step or a changed API contract.
- Do not remove media IDs, attribution, license records or server-required
  metadata to achieve this appearance. Credit/license details remain reachable.
- People, events, playlists and device names are not GIF captions and must still
  identify the recipient, destination or object being changed.
- The new design uses **LED Backpack**, not the previous editor seed branding.
  Original archive captures and the original baseline remain historical evidence,
  not the new app's branding.

## Short first, complete when needed

The revised study replaces 75 long text blocks with concise summaries
(at most 180 characters each), with full original explanations behind Details.
These are deliberate summaries, not silent string truncation.

Keep the consequence, scope, current state, privacy boundary and actionable
failure visible where the decision happens. Put protocol internals, long quota
lists, migration mechanics and diagnostics in context sheets. Do not hide a
required warning or consent simply because the copy is lengthy. Actual runtime
states should show their relevant branch, not the combined static inventory.

## Confirmation, not a typing test

Five typed keyword controls become explicit default-off confirmations:

1. Replace the reviewed backpack slots.
2. Delete private cloud copies only.
3. Permanently delete the account.
4. Apply the reviewed community moderation action.
5. Revoke the reviewed app key.

The toggle **only enables the separate final action**. It never performs deletion,
overwrite, moderation or revocation itself. Password/passkey reauthentication
and genuine passphrase confirmation stay intact. Reasons for moderation and
incident reports remain real text inputs.

The atlas demonstrates disabled-before-confirmation, enabled-after-confirmation
and a separate design-only action. Changing geometry retains the local choice;
leaving/reopening the destination resets it. It makes no API call.

Native integration must reset confirmation on changes to captured target,
account/server, selection, operation/revision, authorization or retry intent.
Recheck existing authorization and stale-state guards at submission. Where a
client contract requires a confirmation keyword, derive that existing literal
only after explicit scoped confirmation and the final button; do not remove or
weaken the protocol's validation. A toggle is not authentication or ownership.

## Boundaries and verification

Stable source/element IDs and original controller code remain in the design
archive. Intentional hidden captions are recorded as `designHidden` in the
source-refresh map; they are not missing source coverage.
The [backend boundaries](backend-contract-boundaries.md) still apply unchanged.
Native UI integration, tests and actual hardware/state acceptance remain pending.
