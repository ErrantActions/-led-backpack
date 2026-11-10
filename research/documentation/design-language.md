# Aurora Fieldwork

Design direction, November 10, 2026. **A design specification, not a shipped app.**
Use with the [research](ios-duo-ux-research.md), [reference analysis](app-ui-patterns.md)
and [page inventory](../layouts/README.md).

## Position

**Make something expressive. Know exactly where it goes.**

Keep the **original Aurora theme**, including its mint-lavender-rose spectrum,
deep ink background, luminous pixel artwork and glass-panel character. The
first Fieldwork pass became too muted: restore expression without undoing
clearer task hierarchy, generous reading space or explicit operation states.
Premium means personality **and** clarity. Do not copy competitors' artwork or
distinctive layouts.

The five destinations remain **Library, Social, Backpack, Create, Live**.
Local creation and playback do not require a community account. Settings and
account management are contextual destinations, not additional permanent tabs.

## Visual tokens

The [interaction direction](interaction-language.md) makes artwork caption-free,
replaces destructive typing tests with deliberate scoped toggles, and moves
long technical explanations behind concise context summaries.

| Role | Dark study | Light implementation target |
|---|---|---|
| Background | `#06090E` | `#F6F7F9` |
| Group surface | `#141725` | `#FFFFFF` |
| Raised/control surface | `#252239` | `#E9EEF4` |
| Primary text | `#F4F7FB` | `#14212D` |
| Supporting text | `#C5C6E4` | `#47586C` |
| Deliberate action | `#9EFFE6` | `#006B58` |
| On action | `#09201E` | `#FFFFFF` |
| Optional creative accent | `#BDB8FF` | `#5744A5` |
| Rose creative accent | `#FFA3D9` | `#8B275F` |
| Mint feature surface | `#14352F` | `#E3F8EF` |
| Lavender feature surface | `#292142` | `#F0ECFF` |
| Rose feature surface | `#381D32` | `#FDEAF4` |
| Warning / uncertain | `#FFD18A` | `#784700` |
| Destructive | `#FFB4B4` | `#9D222A` |

These are opaque reference pairs, not a substitute for measuring the rendered
native control. The Forma study uses the dark palette. Production must support
system appearance, Increase Contrast and Reduce Transparency; light appearance
is specified here, not claimed as rendered or tested in Forma.

- Use system semantic fonts: large title 34, title 28, section/headline 20/17,
  body 17, supporting 15, caption 13 at the default size. These are starting
  points, **not fixed native heights**. Reflow with Dynamic Type.
- Spacing rhythm: 4, 8, 12, 16, 24, 32 points. Compact side gutters 20;
  dense supporting groups 12-16. Use container width, not device-name checks.
- Radius: controls 14, grouped surfaces 20, large preview 24. Avoid nesting
  several large rounded surfaces around one form.
- Body/form reading measure: about 680 points; visual workspaces can use
  1,280 points. Do not stretch chat bubbles across an entire open display.
- Mint, lavender and rose form the original creative spectrum. Use tinted
  feature tiles and expressive artwork in discovery/creation; keep forms,
  message bodies and technical reviews quieter. Color is never a capability
  indicator without its actual state text.
- Group borders and materials must not be the only indication of interaction.
  Native system controls retain their platform behavior.
- Glass belongs to navigation/control layers where supported, not every card.
  Keep decorative motion inside expressive artwork, not behind reading/forms.
  No mandatory shimmer or motion over operation status.

### Restored pop, not a new theme

The original [Aurora components](../../ios/LEDBackpack/DesignSystem.swift) remain
the native visual reference. The revised studies bring back:

- Mint-to-lavender-to-rose pixel waves and richer original artwork.
- Subtle static ambient color, edged glass-style navigation and rounded display
  headings, with opaque readable content/control surfaces.
- An expressive Library opener and richer artwork tiles; a pixel-backpack
  illustration; a colorful Create tool grid; Social constellation artwork;
  and an explicitly labeled Live demo preview.
- Strong primary actions and recognizable tool symbols rather than a stack of
  interchangeable gray buttons.

The atlas approximates ambient light and panel sheen with CSS. Forma retains
editable solid-color controls and embedded raster illustrations: it cannot
encode native material/gradient shaders. Do not flatten native text, controls or
glass into screenshots during implementation. Increase Contrast and Reduce
Transparency remove decorative light/translucency without removing state cues;
Reduce Motion never hides content. The [motion study](motion-language.md) adds
flowing pixel light, a local interaction wake and bounded tactile transitions;
Pause and system Reduce Motion restore the complete static composition.
All new illustrations are original design samples, not connected hardware,
live output, another person's profile, or a feature-availability promise.

## Component grammar

| Component | Required hierarchy |
|---|---|
| Page heading | Native title; one short explanation only when needed; no duplicate oversized title |
| Artwork tile | Artwork only, no visible GIF name; accessible action label; attribution/license and actual availability remain reachable |
| Destination summary | Backpack name/model/panel, connection freshness, operation owner |
| Primary action | One per current task state; verb describes its actual effect |
| Secondary action | Quiet grouped row or secondary control; never a competing mint block |
| Status | Text + symbol + optional color; current state, freshness and relevant next step |
| Warning | Inline near the affected action; never only in a collapsed disclosure |
| Details disclosure | Technical facts, optional timing and diagnostic history |
| Composer | Visible recipient/scope, editable draft, deliberate Send, inline pending/error state |
| Destructive review | Clear object/consequence; default-off scoped toggle plus final action; separate Cancel; no typed keyword or unrelated consent |
| Empty state | What is absent, why if known, and one useful next action |
| Error state | What failed, retained state, recovery action; never success-shaped fallback content |

The full source-derived Forma inventory can contain mutually exclusive branches
and unbound expressions. Those controls are design inventory, **not simultaneous
runtime states**. An all-page style/layout pass must not be represented as proof
that these branches, native pickers or controllers execute.

## Task compositions

### Library and discovery

Library starts with personal artwork, then small Discover / Play / Games entries.
Keep local, private cloud and public discovery distinct. The expanded layout
adds selected-artwork detail; compact navigation opens that same detail.
Source availability, moderation and download state are not one generic badge.
Save locally, Save a copy, Publish and Send & Play keep different meanings.

### Creation and editing

Create is a tool chooser: text, pixels, image/GIF import, animation and timing.
The editor gives priority to the canvas, then the current tool and frames.
Expanded or tabletop layouts expose related tools without changing selected
frame, draft or undo ownership. Compact layout retains Save a copy and Cancel.
System media pickers remain native; imports may fail or require a download.

### Backpack and transfer

Anchor controls to one selected physical backpack. Connection, storage,
maintenance and account adoption are separate tasks. Scanning is explicit
and bounded. A visible connected state is not ownership proof.

The transfer review places destination, fitted copy dimensions, required empty
slots and current preparation state above Send & Play. Progress and Stop remain
visible during transfer. Put optional timing and technical receipts in Details,
not required review information. A protocol receipt is not physical playback
verification. Preserve partial-write warnings, original media and no-auto-resend.

### Live and stationary riding setup

Show preview, current mode, session state and Start/Stop before optional presets.
Label phone preview versus backpack output and demo versus live measurements.
Stale GPS is not zero speed; experimental slowdown is not a brake sensor.
Setup, route planning, messaging and manual changes are stationary tasks.
No emergency-response, road-safety or vehicle-telemetry claim is added.

### Messages and recovery

The [interactive messaging design](../layouts/messaging.html) now provides a
bespoke, familiar inbox/thread composition instead of just the source-inventory
visual pass. Use the [wiring notes](messaging-design.md); it is not shipped native
chat, a Messenger clone, or permission to add unsupported calls/read receipts.

Conversation content and composer dominate. Privacy/history and account tools
are secondary; failure/retry information stays adjacent to the affected message.
Do not add read ticks, E2EE claims or automatic retries without their contracts.
An uncertain send retains its exact operation identity and immutable payload.

Recovery is a distinct, backpack-scoped inbox and thread, not friendship.
Represent empty, loading, failed, owner pending, finder pending, accepted,
uncertain-send and closed states separately. The owner's first reply accepts
where that is the contract; do not add a redundant acceptance step.
Close conversation, Block person and Report message remain separate.
Drafts belong to the same account, server and conversation during resizing.

### Social, events and routes

Make public/private audience and creator attribution visible. Event detail
leads with title, date/time, participation status and place/route context.
Editing, reviewing, joining, inviting and publishing remain different actions.
Maps are related context, not a replacement for accessible route/venue facts.
Moderation/reporting remain reachable without dominating ordinary browsing.

### Account, privacy and administration

Use readable grouped forms and progressive disclosure. Feature-gated content
shows unavailable rather than a pretend empty/successful response. Consent is
specific and default-off where the current contract requires it.
Account deletion, device removal, media deletion and cache clearing are different
operations. Preserve actual consequences, retention wording and confirmation.
Administration emphasizes selection scope and review before bulk changes.

## iPhone Duo contract

1. A compact page is a complete task. Send, Stop, Save, recipient/destination,
   required notices and error recovery must not exist only in secondary content.
2. Derive layout from current container geometry, safe areas and active reserved
   regions. Do not cache screen bounds or infer layout from device model.
3. Use native list/detail navigation for collections/inboxes. Use arrangements
   only for related primary/secondary task content, outside unsupported nesting.
4. System bars can become vertical and use either outside edge in multitasking.
   Preserve semantic title+symbol items and platform overflow. Forma's rail is
   an approximation, not the native edge-selection contract.
5. Active fold divisions separate meaningful units, not half a tile or input.
   Fully open does not require a permanent hinge gap. Camera occlusion is dynamic.
6. Preserve navigation, selected artwork/frame, draft, focus and in-flight
   operation identity through folding, keyboard and window changes.
7. Tabletop/stand is a stationary related-task composition, not arbitrary
   dual-display output. Tent presets do not establish native support.
8. Keep iOS 17 fallbacks. Guard newer APIs individually; do not raise the minimum
   deployment target for a visual redesign.

## Backend coordination

The iOS session contacted **LED-Backpack-Backend** before proposing API changes.
The backend session reported that current capabilities and undeployed recovery
v2 must be distinguished. Chat acceptance is not a read/device-delivery receipt;
upload moderation and device-status limitations remain explicit.
The [contract handoff](backend-contract-boundaries.md) records the source/live
distinction, current gates, revocable recovery grants, actual DTO states and
precise gap-report requirements. It is a dated coordination record, not a
substitute for fetching current config and enforcing endpoint authorization.

No backend change is authorized by this visual specification. Drive features
from actual config/authorization and keep unsupported/unavailable states.
Send the backend session a concrete existing endpoint, missing field/state,
client use case and compatible acceptance criteria before requesting a change.
Do not invent read receipts, deployment status, live device telemetry or a
successful upload simply to fill a design.

## Verification gates

Browser/Forma geometry checks establish prototype layout only. Native acceptance
still requires the [A01-A20 matrix](ios-duo-ux-research.md#9-native-acceptance-matrix),
Mac compilation, native accessibility checks and relevant hardware acceptance.
The research and design export do not deploy recovery v2 or change Swift source.
