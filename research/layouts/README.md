# Layout studies

## Aurora Fieldwork design pass

- [Interactive messaging redesign](messaging.html): familiar Messenger-style
  inbox/thread behavior in Aurora; search, scoped drafts, composer, requests,
  private artwork, compact/Duo layout and explicit failure/retry previews.
  See its [native wiring and contract notes](../documentation/messaging-design.md).

- [Interactive all-surface atlas](design-atlas.html): searchable page/component
  inventory, ten geometry variants, related-study navigation and design intent.
- [Design language](../documentation/design-language.md): tokens, typography,
  task compositions, Duo behavior and honest state/consent boundaries.
- [Per-surface coverage ledger](page-coverage.md) and
  [machine-readable specifications](page-designs.json).
- [Editable Forma layout](led-backpack.layout.json): stable original IDs,
  source mappings, action/native notes and adaptive rules. This is project JSON,
  **not a portable asset-bundled workspace** or a patch for production Swift.
- [Validation record](design-validation.json): 2,020 numeric geometry cases and
  the measured text/color contrast pairs; no native certification.
- [Current-source refresh](native-source-refresh.json): all 196 views recognized
  by the current static importer are represented. Thirteen changed source
  inventories were refreshed; curated drafts are matched separately from their
  source counterparts. One legacy firmware study is explicitly retained.

The inventory contains **202 editable studies**, not 202 independent production
pages: five newly composed tab drafts, 193 retained source-derived surfaces
(including shared components), and four newly documented native surfaces.
The 42 historical image-only reference screens remain unchanged in the export.

The original Aurora mint/lavender/rose theme is restored across editable studies.
The five tab drafts add original spectrum/pixel illustrations, richer feature
surfaces and a Create tool grid, while retaining the clearer task structure.
Atlas ambient light/panel sheen are CSS approximations; editable Forma controls
use solid tokens with embedded raster illustrations, not native shader output.
The [motion direction](../documentation/motion-language.md) is demonstrated by
the atlas's traveling pixel light, interactive wake and tactile feature tiles.
Pause/system Reduce Motion preserve complete still artwork. Forma is the static
keyframe/layout export, not an export of the browser canvas animation.
The [interaction revision](../documentation/interaction-language.md) replaces
five destructive typing fields with scoped toggles, removes GIF captions and
shortens 75 long explanations with full context still available through Details.
These are design proposals, not changes to production controller/API behavior.

The live editor was observed read-only during this revision. The atlas and local
portable proposal contain the changes; consult `liveSynchronization` in the
validation record before assuming the live Forma workspace matches them.

The source-derived views receive a shared adaptive visual pass and individual
design intent. Imports can include mutually exclusive branches and unbound
values. They have **not** been hand-validated as every actual runtime state.
The atlas labels this boundary instead of pretending static fixtures execute
SwiftUI. Native controls perform no API, sensor, radio or account operation.

The atlas embeds its own preview data and original illustrative pixel patterns;
it needs no server or third-party image download. The separate
`design-atlas-data.json` is the matching geometry snapshot. Historical reference
asset paths in the editable layout require the original Forma asset bundle.
Keep the original baseline and asset-bundled workspace backup when importing.
The local [portable workspace](../../.migration/design-exports/led-backpack.forma.json)
and [before-design backup](../../.migration/design-exports/led-backpack-original.forma.json)
are saved in the ignored migration directory. They bundle all 42 historical
reference images; those unreviewed archive images are deliberately not copied
into the tracked public research collection. These local links require the
migration files and are not assets supplied by a fresh Git clone.

No native Swift, backend contract, recovery deployment or beta build is changed
by these files. Apply intended changes surgically to the original app, preserve
bindings/controllers and run native acceptance before release.

Run `node research\validate-research.mjs` from the repository root to validate
the embedded/external data, coverage records, browser script syntax and local
documentation links. Geometry was measured with the local Forma layout engine,
not inferred from screenshot sizes.

## Original relationship schematic

[Duo task relationships](duo-task-relationships.svg) is an original schematic:

1. Compact primary surface with optional details reachable on demand.
2. Expanded split arrangement for related primary/secondary task content.
3. Tabletop overlay relationship with visual content above task controls.

The diagram is **not a screenshot**, a device-size specification, executable
SwiftUI, a Forma workspace export, or an approved replacement design. Rectangles
and gaps are illustrative; native geometry and reserved regions determine layout.

## Visual inputs for the next layout pass

- [App comparison board](../screenshots/app-reference-board.html): 44 apps /
  312 references, including motorcycle, messaging, social, LED, media and
  mainstream/premium product references.
- [Explicit iPhone Duo examples](../screenshots/iphone-duo-examples.html):
  ten Apple-published compositions; ordinary iPad screenshots are not Duo proof.
- [App-specific lessons and proposed coding slices](../documentation/app-ui-patterns.md):
  preview plus tools, inbox plus thread, art-first discovery, route review and
  honest device/session state.

Use those task relationships, not copied branding or screenshot pixel dimensions.
For example, compare GIF Studio with Edits/VLLO, recovery messaging with
Slack/Signal, and stationary route review with Lyft/REVER.

For actual implementation:

- Decide what primary and secondary mean for the task before selecting a style.
- Essential actions must remain accessible when secondary is not shown.
- Keep navigation outside the arrangement; verify container composition.
- Preserve operation/draft ownership outside geometry-dependent branches.
- Use native rails, safe areas, overflow and accessibility behavior.
- Validate the [native acceptance matrix](../documentation/ios-duo-ux-research.md#9-native-acceptance-matrix).

Store future reviewed layout JSON/workspace exports here with baseline/source
commit and source mappings. Never overwrite the live Forma project or native
Swift source with a generated viewport prototype without review.
