# iOS layout, iPhone Duo and LED-backpack UX research

Research date: November 10, 2026.

## 1. Scope and evidence

This is a new synthesis, not a reconstruction of missing private research.
Its primary focus is native iOS layout and UX, specifically iPhone Duo. Messaging,
GPS/riding, LED content, privacy, and recovery are evaluated as app workflows.

Labels used here:

- **Verified guidance:** directly read in the primary source listed in section 12.
- **Recommendation:** a design inference for this app, not an Apple requirement.
- **Observed source:** behavior found in the restored code; not a new runtime test.
- **Needs validation:** a hypothesis or acceptance target, not a confirmed bug.

Apple's current pages explicitly document iPhone Duo, ArrangementView and
ReservedRegion. Their API pages list iOS27.1+ availability. This research does not
rely on historical device rumors or a generic foldable-browser mockup.
Deployment target and build SDK are different: keep the existing iOS17 fallback,
guard newer APIs, and compile with the documented SDK before claiming support.
[S01-S05]

No product changes, deployment, radio operations, private API calls, or fresh
native simulator runs were performed for this research. The passing native gate
atbd1cf7d is historical evidence, not validation of proposed changes.

## 2. Design position: native first, artwork first, honest state

**Recommendation:** retain the five familiar top-level destinations rather than
redesigning navigation for every pose. Library is for owned artwork; discovery is
for finding content; Create is for making copies; Backpack is for hardware state;
Live is for an explicitly started session. Messaging and account features remain
contextual rather than becoming prerequisites for local use.

- Use native navigation, toolbars, sheets, lists and menus before custom chrome.
- Put primary content and the next meaningful action before diagnostics.
- Use progressive disclosure for optional settings, not for safety-critical
  warnings, current errors, Stop, or required review information.
- Keep cloud sync, public publication, phone display and backpack transfer as
  distinct destinations with distinct outcomes.
- Never label a local preview as actual device output. A protocol acknowledgement
  is not proof of physical animation, brightness, timing, or visibility.
- Keep form state and operation identity stable across layout changes; layout
  transitions must not send messages, start scans, publish, or restart hardware.

Basis: hierarchy/progressive disclosure [S06], stable tab navigation [S07],
privacy [S17], actionable rather than repetitive alerts [S32], and upload/
hardware contracts in the inspected source.

## 3. iPhone Duo: the actual interaction model

### 3.1 Resize the experience; do not swap applications

Apple describes a compact outer display, a larger inner display, partial folds,
and multitasking windows. Layout should derive from current container geometry,
size classes, safe areas and reserved regions, not device names, hardcoded
screen sizes, or physical orientation alone. Regular width does not mean iPad.
Avoid reading screen bounds once and caching them for the session. [S01-S03]

**Recommendation:** preserve selection, navigation path, draft, scroll position
where practical, playback clock and in-flight operation across resizing. Add
information on the larger display; do not change the meaning of controls.

### 3.2 Vertical navigation is a first-class native pattern

Apple places system bars vertically on the outer display and inner landscape;
inner portrait generally keeps horizontal bars. Multitasking can put bars on the
outer edge of each app, including the left side for the left app. Hardware-aligned
bar placement must not be inferred simply from a mirrored RTL content layout.
Use current environment/safe-area information rather than a hardcoded trailing
strip. `toolbarVerticalEdge` reports the system's preferred edge, even if a bar is
not currently visible. [S01, S03, S11]

Consequences:

1. Keep Back/Close and Done in semantic system placements. Do not duplicate them
   with an always-bottom custom bar.
2. Provide an appropriate symbol and title for adaptive toolbar actions; text-only
   and arbitrary custom-view items do not participate in vertical presentation
   the same way as titled symbol items.
3. Group related actions semantically; avoid fixed manual toolbar spacing.
4. Keep local pane actions close to the content they affect. Not every action
   belongs on the outer rail.
5. Prioritize frequently used actions before diagnostics in overflow. Use system
   overflow instead of a competing second ellipsis menu.
6. Prefer navigation access in browsing contexts; consider preserving task toolbar
   actions during editing. Choose compression deliberately, not globally.

Relevant APIs: `ToolbarItemVisibilityPriority` and `ToolbarOverflowMenu` list
iOS27+ availability; `ToolbarVerticalCompressionBehavior` and
`toolbarVerticalEdge` list iOS27.1+. Verify guards individually. [S08-S11]

### 3.3 Reserved regions are geometry, not a fixed hinge spacer

`ReservedRegion` distinguishes **occlusion** from **division**. Queries default to
active regions intersecting the queried view. Frames use that view's coordinates
and already include margins. They can partially extend beyond its bounds.
Do not add region margins a second time or mix screen and local coordinates.
The fold division is inactive when fully open; camera activity can change
occlusion. Inactive regions can be queried deliberately to reduce disruptive
layout jumps, not to impose a permanent empty strip everywhere. [S05]

**Important distinction:** system presentation components accommodate reserved
regions, but a List or ScrollView does not automatically divide its rows/items
around a fold. A large scrolling view can still put meaningful content across
the division. Check custom cards, artwork grids, canvases and floating controls.
[S05]

For an active division, keep interactive artwork/control units on one side;
do not split a text field or a single artwork tile through the fold. Apple
recommends even grid column counts when adapting a grid at an active fold.
That is not a mandate to force every grid to two columns at every width.

### 3.4 ArrangementView is for two related content surfaces

- **Split:** separates primary and secondary content; layout adapts to available
  shape and reserved regions. Closed landscape can show only primary.
- **Overlay:** layers primary above secondary on a flat display; separates them
  when a division is active. Its primary goes to the trailing/bottom part in the
  folded configuration, unlike split's leading/top primary.
- Axis constraints can hide secondary content in unsupported arrangements.
  Essential controls therefore cannot live exclusively in secondary.
- An arrangement is not a navigation container. Keep navigation outside it.
  Do not casually embed arrangements in a ScrollView, List, grid, navigation
  split view or other container that could leave content inaccessible.
  A NavigationStack can own the content scene; navigation-container composition
  still needs a native check rather than a universal nesting recipe. [S03-S05]

**Recommendation:** choose based on content relationship, not novelty:

| Workflow | Recommended starting point | Must remain available in compact form |
|---|---|---|
| Live preview + controls | Evaluate split or overlay; preserve current proven split until compared | Mode, required notices, Start/Stop and editing |
| GIF timing/editing | Canvas + editing controls as related surfaces | Save a copy, Cancel, selected tool and timing |
| Library item detail | Native navigation plus optional detail/inspector; do not nest containers blindly | Selection, source status and intended action |
| Message list + thread | Native navigation split structure where appropriate, not an arrangement pretending to navigate | Thread, draft, Send/Retry, Back |
| Plain account/consent form | Native form that scrolls; do not split individual fields for visual symmetry | Consent, errors, Submit and dismissal |
| GPS game | Adaptive content with stable session owner | Eligibility explanation, Stop and manual alternative where valid |

### 3.5 Poses are test scenarios, not automatic features

Test closed, fully open, book, tabletop/laptop, stand/propped, intermediate folds
and supported rotations. Derive layout from runtime geometry, not a hinge-angle
lookup table. A Forma tent/outer-display preset does not grant arbitrary native
dual-display output. Apple's documented open-device outer-display support is
camera-specific; do not promise a general second backpack-control screen. [S03]

## 4. General iOS UI/UX criteria

### Hierarchy and visual language

**Recommendation:** artwork is the content layer; navigation and controls should
remain visually distinct. Keep one clear primary action per task state, with
destructive actions separated. Use system text styles and restrained emphasis;
avoid making every nested section a large, equally prominent glass card.

Apple reserves Liquid Glass primarily for navigation/control layers and advises
using it sparingly; it is not a reason to glass-coat every artwork tile or form.
Respect Reduce Transparency, Increase Contrast and light/dark appearance. The
name of a custom `glassPanel` helper alone does not establish whether it uses
actual Liquid Glass; inspect implementation and runtime appearance first.
[S06, S12, S13]

### Accessibility is a layout input

- Use Dynamic Type and test accessibility sizes, not just larger default fonts.
  Reflow controls vertically before shrinking text or clipping labels.
- Keep meaningful control hit areas at least44x44points as this project's target.
  Apple's current table distinguishes a44-point default from a28-point minimum;
  do not misquote44as an absolute platform rule for every context.
- Measure contrast on the rendered surface, including glass/background artwork.
  Use the relevant Apple/WCAG criteria rather than assuming mint-on-black passes.
- Provide labels, values, selected states and understandable reading order.
  Color, animation and icon shape must not be the only state indicators.
- Provide an explicit action alternative to a long press, swipe or drag.
- Test VoiceOver, Voice Control, Reduce Motion and Full Keyboard Access.
- Put Stop in the active task, not behind a time-limited banner or obscure menu.

Basis: accessibility guidance [S12]. Specific acceptance targets are project
recommendations; they have not been measured across this application yet.

### Keyboard and forms

Choose input semantics and appropriate keyboards; keep native keyboard avoidance.
Long messages, hardware keyboards and increased text size can radically reduce
usable height on Duo's outer display. A composer must remain visible and editable
without covering the last message or placing Send beyond the available region.
Preserve focus and draft across folding; a rotation is not a send gesture.
The system picker and keyboard should not be replaced just to mimic a browser
mockup. [S14-S16]

## 5. Messaging, social discovery and lost-device recovery

Signal documents request-based contact controls as a useful comparative pattern:
accept/block/delete, with blocking/reporting available in its support material.
Direct retrieval returned403; these comparisons were checked through indexed
official support results only, not a fresh app interaction. Do not claim precise
current screen appearance or copy Signal's encryption promises. [S26-S27]

**Recommendations for this app:**

1. Keep recent conversations separate from people available to start a new one.
   Empty, loading, unavailable and failed states need different explanations.
2. First contact should have an understandable purpose and recipient. Recovery
   is about returning one backpack, not automatic friendship or general DM.
3. Owner acceptance can be the clearly labeled first reply if the contract says
   so; do not add another identical confirmation. Keep Block, Close and Report
   distinct because they have different effects.
4. Keep typed text local to its account/server/conversation. Never transplant
   drafts or retry payloads into a newly selected account/recipient.
5. Retry an uncertain send using the existing immutable request identity. Do not
   make a visually convenient Retry create a new logical message.
6. Distinguish pending, acknowledged, failed and uncertain delivery. Do not infer
   "read" or "delivered to device" from an HTTP success or local outbox state.
7. Prefer inline delivery detail and recovery actions to repeated modal prompts.
8. Default-off owner contact and ambiguity rejection must survive simplification.
   A mutable device identifier is an association key, not ownership proof.

Source observations: chat and recovery use bottom safe-area composers; recovery
has pending-owner/finder states and separate close/block dialogs. These are
preservation constraints, not evidence that every keyboard/fold combination works.
Inspect [chat](../../ios/LEDBackpack/CommunityChatViews.swift) and
[recovery](../../ios/LEDBackpack/DeviceRecoveryViews.swift) before editing.

## 6. GPS, riding and nearby interactions

Strava Beacon separates deliberate sharing from recording and documents the
cellular-connectivity dependency. A shared link grants location visibility to
its recipients; it is not emergency response. Flyby independently controls
crossed-path visibility. These are useful patterns for separating recording,
sharing and discovery, not features to copy wholesale. [S23-S24]

**Recommendations:**

- Configure while stationary. Never frame phone UI interaction, flashing artwork,
  speed, or phone-motion estimates as a certified riding safety system.
- Show freshness and unavailable states. Negative `speedAccuracy` means the speed
  value is invalid; stale or invalid readings must not look like live zero. [S21]
- Keep raw measurement separate from optional display caps or smoothing.
- Treat GPS area eligibility, authenticated BLE peer exchange and UWB ranging as
  different evidence. Do not convert an RSSI value into claimed precise meters.
- Nearby Interaction requires compatible hardware/session support; check actual
  capabilities and session state. Offer a valid alternative where possible.
  Nearby Interaction's portrait-use guidance can conflict with a freely rotating
  UI: provide capability/orientation feedback without restarting the task. [S22]
- Request sensors only for an explicitly entered feature and current consent.
  No ambient nearby discovery merely because a person opens a list.
- Background location is a separately justified capability with authorization and
  lifecycle requirements. Always authorization is not a universal prerequisite
  for every background-location design; current APIs include when-in-use
  sessions. The existing app's own stricter policy remains unchanged. [S20]
- Service loss, locking, backgrounding and permission revocation need visible
  outcomes and truthful recovery rather than a promise of permanent execution.

## 7. Bluetooth and LED content workflow

Divoom's official guide separates device connection, gallery content, animation/
text creation and display controls. Functions vary by model and app version.
Use this as evidence for task-oriented structure, not proof of compatibility
with our hardware or an invitation to copy its visual assets. [S25]

**Recommended flow:** choose artwork -> preview/fit a copy -> review meaningful
destination information -> Send & Play -> verify the supported receipt.

- Never force a public upload or cloud save to send a locally available GIF.
- Keep originals intact. Distinguish sending copies from changing source timing.
- Show selected device, fitted dimensions and destination slots at the review
  point. Required destination information must not be only in collapsed details.
- Show transfer progress outside optional disclosure; keep Stop reachable.
- Never overwrite unknown originals to make a one-tap path appear successful.
- Keep uncertain writes explicit; disconnect may prevent restoration. Do not
  automatically resend or claim rollback when the protocol cannot establish it.
- Scan only for a current intent; stop when the task no longer needs it. Prefer
  the required services/characteristics and avoid unnecessary duplicate scanning.
  Bluetooth state restoration is not permission to revive a canceled UI task.
  [S18-S19, S33]
- Current Core Bluetooth docs describe additional iOS26+ Live Activity background
  privileges. Do not apply older blanket scanning limitations to all modern
  configurations, or enable Live Activities merely to bypass an intentional
  foreground-only product policy. Older supported runtimes still need fallbacks.
  [S18-S19]

Observed source: [direct send](../../ios/LEDBackpack/BackpackDirectSendView.swift)
puts status in Preparation details while its final action references slots
"shown above"; the store formats slot information in its status text. This is a
specific **review candidate**, not a proven runtime defect. Reproduce in a safe
fixture before changing the review layout or write-authorization boundary.

## 8. Photos, uploads, private storage and account lifecycle

Use the system photo picker for deliberate asset selection rather than requesting
broad photo-library access solely to import one GIF. Selection is not loaded data:
loading may fail, including when an iCloud asset is unavailable offline.
SwiftUI Image's Transferable conformance does not handle arbitrary GIF originals;
use an appropriate data/custom representation when preserving animation.
[S28-S29]

Keep public community review explicitly separate from private storage. Clearly
explain publication and any AI review before submission, retain attribution and
permissions, and preserve the original artwork.

OWASP recommends defense in depth: allowlisted types, actual content validation,
size limits, generated server filenames, authorization, appropriate storage and
request protections. Decode/frame/pixel budgets must be enforced independently
from compressed size. The current native upload validator contains explicit GIF
budgets; client checks do not replace server validation. [S30]

Apple requires in-app initiation of account deletion for apps offering account
creation, with appropriate identity confirmation but no needless barriers.
Its guidance includes deletion of associated user-generated content unless a
legal requirement justifies retention. [S31]

**Needs policy review:** restored documentation mentions configurable retention
of approved shared GIFs after account deletion. A retained-artwork label does not
by itself establish App Review compliance. Reconcile actual data, attribution,
legal requirements and deletion semantics before the next submission. This is
not a concluded legal finding or authorization to change production retention.

## 9. Native acceptance matrix

These are proposed checks, **not newly passed tests**.

| ID | Scenario | Required evidence |
|---|---|---|
| A01 | Closed outer display, both supported rotations | Back/Close, current tab and main action usable; no camera/rail overlap |
| A02 | Inner portrait and landscape, fully open | Natural expansion; no unnecessary permanent fold gap |
| A03 | Book and tabletop partial folds | Meaningful units avoid active division; both panes scroll independently where intended |
| A04 | Stand/propped and intermediate fold transitions | Stable navigation and task identity; no automatic sensor or send restart |
| A05 | Narrow/tall and wide/short multitasking windows | No device-idiom assumptions or essential secondary-only controls |
| A06 | Left and right multitasking positions | Correct asymmetric safe areas and system rail edge |
| A07 | Inner camera activation during a task | Occlusion accommodated without lost draft/selection |
| A08 | Accessibility Dynamic Type | Labels/actions reflow; no hidden consent, warning, Stop or Save |
| A09 | VoiceOver and RTL | Logical traversal, correct labels, region coordinates and bar behavior |
| A10 | Light/dark, Increase Contrast, Reduce Transparency | Measured readable controls over actual content backgrounds |
| A11 | Reduce Motion | Usable static previews; motion not required to understand progress/state |
| A12 | Software keyboard, long draft, short outer window | Composer and Send/Retry visible; last message reachable |
| A13 | Hardware keyboard and Full Keyboard Access | Navigate, edit, dismiss and complete without touch-only gestures |
| A14 | Fold while editing Live text or timing | Exact authored values preserved; no duplicated operations |
| A15 | Sheet/popover/overflow while folding | Anchor and dismissal remain reachable; parent state retained |
| A16 | Offline/timeout/uncertain send followed by account switch | No false success, stale delivery mutation or cross-account draft/retry |
| A17 | Cancel scan, leave tab, background, return | Canceled scan never restarts implicitly |
| A18 | Transfer disconnect and Stop | Truthful partial-write state; no overwrite, auto-resend or fictitious rollback |
| A19 | GPS denial/reduced accuracy/stale fix/UWB unavailable | Explicit unavailable state and valid fallback; no invented proximity |
| A20 | Limited Photos/iCloud asset offline/corrupt or oversized GIF | Safe explicit import failure, original retained, retry remains deliberate |

For each native capture record commit, SDK, simulator/device, actual geometry,
pose/region state, appearance, text-size category and test action. A test name
containing "landscape request" is not evidence that captured geometry is landscape.

## 10. Implementation priorities for the next coding slice

1. **Visible transfer review and progress.** Reproduce the direct-send candidate;
   show destination/fit/progress inline without adding another generic confirmation.
   Preserve captured inventory, empty-slot validation, cancellation and receipts.
2. **Duo toolbar pass.** Check actual compact/outer controls, title+symbol items,
   semantic grouping, overflow, Close/Done and task-vs-navigation compression.
3. **Chat list and composer pass.** Inspect start-conversation hierarchy separately
   from recent contacts; test empty recent lists, keyboard and account transitions.
   Do not assume a source assertion substitutes for the visible regression.
4. **Fold-aware Library/editor review.** Reproduce rows or tiles crossing active
   divisions before adding custom region handling. Avoid wrapping every screen
   in ArrangementView; prefer the container appropriate for the relationship.
5. **Accessibility and failure-state sweep.** Run A08-A13 and A16-A20 before
   cosmetic polish or beta promotion.

These are bounded opportunities, not a claim that the whole app was audited.
Existing full native proof covers the previous source; every implementation slice
requires relevant fixtures plus Mac compilation/UI evidence. Hardware and public
rollout remain separate gates.

## 11. Visual evidence and Forma boundaries

See [screenshot provenance](../screenshots/README.md) and
[layout studies](../layouts/README.md).

The replacement [app comparison board](../screenshots/app-reference-board.html)
now includes 44 apps / 312 published references, including messaging, social,
motorcycle and mainstream/premium products. A separate [Duo gallery](../screenshots/iphone-duo-examples.html)
contains ten Apple-published app compositions explicitly presented on iPhone Duo.
See [pattern analysis](app-ui-patterns.md) for per-app evidence, design lessons and
the distinction between promotional stills, described behavior and native tests.

The archived build10 screenshots demonstrate real historical native UI. They
are not the latest source, not a current screenshot baseline, and not hardware
proof. The layout SVG is an original relationship study without device metrics.
It is neither native output nor a production-ready visual specification.

Forma's live project reported240screens/3,779elements during reconnection.
Counts do not establish that missing browser edits were recovered. Preserve
stable IDs, source mapping and baseline; export a reviewed workspace/update
package before integration. The initial research pass did not mutate Forma.
The subsequent [Aurora Fieldwork design pass](design-language.md) is documented
in the [coverage ledger](../layouts/page-coverage.md), with an editable export,
preserved original IDs/baseline and separately labeled prototype validation.
It does not change or certify production SwiftUI.

## 12. Primary-source register

All sources accessed2026-11-10. "Direct" means substantive primary-source text was
retrieved, not that the app/product was manually operated. Apple documentation
was read using its published Markdown alternates where necessary. Product pages
can change; archive a new access date when recommendations are revisited.

| ID | Source | Evidence used / retrieval |
|---|---|---|
| S01 | [Apple: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) | Direct; poses, vertical bars, continuity, controls, reserved regions |
| S02 | [Apple: Three steps for iPhone Duo](https://developer.apple.com/iphone-duo/prepare/) | Direct; SDK differences, resizability, geometry and simulator tools |
| S03 | [Apple: Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo) | Direct; bars, sheets, container composition, camera-specific outer display |
| S04 | [Apple: ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview) | Direct; split/overlay, primary/secondary, axes, availability |
| S05 | [Apple: ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion) | Direct; region kinds, local frames/margins, active state, scrolling and RTL |
| S06 | [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Direct; hierarchy, progressive disclosure and adaptable layout |
| S07 | [Apple HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) | Direct; stable destinations, labels, navigation not actions |
| S08 | [Apple: ToolbarItemVisibilityPriority](https://developer.apple.com/documentation/swiftui/toolbaritemvisibilitypriority) | Direct; overflow order, iOS27+ |
| S09 | [Apple: ToolbarOverflowMenu](https://developer.apple.com/documentation/swiftui/toolbaroverflowmenu) | Direct; system overflow, iOS27+ |
| S10 | [Apple: ToolbarVerticalCompressionBehavior](https://developer.apple.com/documentation/swiftui/toolbarverticalcompressionbehavior) | Direct; tab-vs-toolbar priority, iOS27.1+ |
| S11 | [Apple: toolbarVerticalEdge](https://developer.apple.com/documentation/swiftui/environmentvalues/toolbarverticaledge) | Direct; preferred edge, context, iOS27.1+ |
| S12 | [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Direct; text, contrast, control sizes, gestures, keyboard access |
| S13 | [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Direct; control/content distinction, restraint, material variants |
| S14 | [Apple HIG: Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards) | Direct; semantic input and keyboard selection |
| S15 | [Apple HIG: Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards) | Direct; physical keyboard and Full Keyboard Access |
| S16 | [Apple: ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits) | Direct; ordered ideal-size fitting, not a device-width switch |
| S17 | [Apple HIG: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy) | Direct; contextual permission requests and data minimization |
| S18 | [Apple: Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) | Direct; permissions and modern Live Activity background behavior |
| S19 | [Apple: Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) | Direct archival guide; lifecycle/restoration, read alongside S18 |
| S20 | [Apple: Background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background) | Direct; capabilities, sessions, authorization, termination |
| S21 | [Apple: speedAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/speedaccuracy) | Direct; units and invalid-negative-value semantics |
| S22 | [Apple: Nearby Interaction](https://developer.apple.com/documentation/nearbyinteraction) and [Nearby interactions HIG](https://developer.apple.com/design/human-interface-guidelines/nearby-interactions) | Direct; capabilities, session tokens, feedback, alternatives and orientation |
| S23 | [Strava: Beacon](https://support.strava.com/en-us/articles/15401829-strava-beacon) | Direct FAQ plus official indexed setup; deliberate sharing and cellular dependency |
| S24 | [Strava: Flyby privacy](https://support.strava.com/en-us/articles/15401996-how-do-flyby-privacy-controls-work-on-strava) | Direct plus official indexed detail; independent crossed-path visibility |
| S25 | [Divoom app guide](https://divoom.com/blogs/app-guide/divoom-app-guide-pixel-art-widgets-smart-displays) and [community](https://divoom.com/pages/divoom-community) | Direct vendor documentation; workflows/model differences, not independent usability proof |
| S26 | [Signal: Profiles and Message Requests](https://support.signal.org/hc/en-us/articles/360007459591-Signal-Profiles-and-Message-Requests) | Official indexed result only; direct403; comparative request pattern |
| S27 | [Signal: Blocking](https://support.signal.org/hc/en-us/articles/360007060072-Block-numbers-usernames-or-groups) | Official indexed result only; comparative block/report/accept pattern |
| S28 | [Apple: PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker) | Direct; selection/loading failure and Transferable representation limits |
| S29 | [Apple: Enhanced Photos privacy](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app) | Direct; picker vs broad PhotoKit authorization, contextual requests |
| S30 | [OWASP: File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html) | Direct; defense-in-depth upload guidance, not an audit of this server |
| S31 | [Apple: Account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion) | Direct; in-app initiation, confirmation and associated UGC |
| S32 | [Apple HIG: Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) | Direct; sparse actionable alerts, meaningful labels, irreversible actions |
| S33 | [Apple: Peripheral best practices](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html) | Direct archival guide; bounded scanning and radio use |

### External visual-reference index

These are links to the original publishers' illustrated pages, not downloaded
assets or a claim that their artwork may be redistributed.

| Reference | What to inspect | How to use it |
|---|---|---|
| V01: S01, Anatomy | Outer/inner displays and camera positions | Distinguish safe-area/occlusion needs |
| V02: S01, Device poses | Book, stand, tabletop and other poses | Native test checklist, not per-pose hardcoded layouts |
| V03: S01, Mail comparison | Compact detail vs expanded list/detail | Preserve selection while adding hierarchy |
| V04: S01, Notes fold comparison | Pane proportions when partially folded | Compare native split behavior |
| V05: S01, Arrangement views | Split vs overlay relationship | Decide primary/secondary meaning before styling |
| V06: S01, Vertical controls | Rail component order | Review Back, Done, overflow and tabs |
| V07: S01, Multitasking | Bars at each app's outside edge | Check asymmetric safe areas |
| V08: S01, Compression examples | Toolbar vs tab-bar compression | Choose task-specific priority |
| V09: S03, Reserved-region diagrams | Fold and camera occlusions | Review custom overlays and canvases |
| V10: S02, SDK comparison | Different SDK-linked behavior | Separate build SDK from deployment target |
| V11: S12, Accessibility examples | Contrast, spacing, gesture alternatives | Measure actual UI rather than imitate appearance |
| V12: S13, Materials | Regular/clear material contrast | Keep artwork and controls distinct |
| V13: S25, Divoom guide | Content creation and device-specific controls | Task organization only; do not copy assets |

## 13. Research limitations and next validation

- The old41images and original notes remain missing; this document replaces the
  working guidance, not their provenance.
- Competitor flows were researched from official material, not hands-on accounts.
- Signal's primary pages were blocked on direct fetch; indexed evidence is marked.
- No accessibility measurements or new native pose screenshots have been taken.
- No claim is made that every existing screen conforms or that a suggested API
  is a drop-in fix for the current SwiftUI hierarchy.
- No live production policy or hardware behavior was reverified.
- Implement one bounded workflow change, run its exact tests, capture native
  evidence, then update this research with observed results rather than silently
  promoting recommendations into proven behavior.
