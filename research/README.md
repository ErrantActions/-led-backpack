# LED Backpack design research

Rebuilt November 10, 2026 after the original scratch research was excluded from
migration. This directory is intentionally allowed by the root Git ignore rules.
It is not bundled as app artwork. Do not put keys, private messages, production
captures, or personal location data here.

## Start here

- [Aurora Fieldwork design atlas](layouts/design-atlas.html):
  five newly composed tabs and the complete 202-study editable inventory, with
  compact/Duo variants and per-surface intent. Components and fixtures are
  distinguished from production pages.
- [Design language](documentation/design-language.md) and
  [coverage ledger](layouts/page-coverage.md): what changed, what is preserved,
  and what still requires native implementation/acceptance.
- [Backend contract boundaries](documentation/backend-contract-boundaries.md):
  live versus undeployed capabilities, consent/revocation, truthful status and
  the required format for reporting an actual API gap.
- [Motion](documentation/motion-language.md) and
  [simpler interactions](documentation/interaction-language.md): flowing Aurora
  pixel light, accessible still mode, caption-free artwork and scoped toggles.
- [Messaging redesign](layouts/messaging.html): a working, fictional
  inbox/thread prototype with familiar Messenger-style behavior and
  [explicit native integration boundaries](documentation/messaging-design.md).
- [Visual app comparison board](screenshots/app-reference-board.html):
  44 apps / 312 published screenshot references, including messaging, social,
  seven motorcycle apps and nine mainstream/premium product references.
- [iPhone Duo app examples](screenshots/iphone-duo-examples.html):
  ten additional official Apple-published app compositions, separately labeled.
- [App-specific pattern analysis](documentation/app-ui-patterns.md):
  what to learn, what not to copy, and proposed native/Duo design actions.
- [iOS, iPhone Duo and workflow research](documentation/ios-duo-ux-research.md):
  source-backed findings, design decisions, implementation priorities, and tests.
- [Screenshots](screenshots/README.md): actual historical native simulator captures
  with provenance. Not new captures and not proof of the current native build.
- [Layouts](layouts/README.md): original studies and a source-preserving Forma
  layout export, separate from screenshots and executable production SwiftUI.

## Evidence rules

1. Prefer Apple's current HIG and API documentation for native behavior. Competitor
   examples are inspiration, not API contracts or permission to copy artwork.
2. Record source URL, access date, observed behavior, interpretation, and limits.
3. Keep actual screenshots, browser approximations, and proposed layouts labeled.
4. Record source commit and capture environment for every native screenshot.
5. Link third-party visual references at their source; do not copy their images
   into the repository without appropriate permission.
6. Forma previews help explore relationships; they do not prove native folding,
   keyboard behavior, permission handling, or hardware operation.

The original 41-image reference collection has **not** been recovered or recreated
one-for-one. The new reference collection prioritizes attributable, useful
examples over matching the old image count. Third-party images remain externally
hosted; only our historical native captures and original diagrams are local.
