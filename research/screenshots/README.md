# Screenshot evidence

## Current-listing visual references

- [Searchable app board](app-reference-board.html): **44 apps / 312 images**,
  including six messaging, five social/community, seven motorcycle apps and
  nine mainstream/premium product references.
- [iPhone Duo gallery](iphone-duo-examples.html): **10 additional official
  Apple-published device compositions**, not inferred from iPad screenshots.
- [Pattern analysis](../documentation/app-ui-patterns.md): app-by-app observations,
  limitations and Duo implications.
- [Source register](app-references.json): exact listing/image URLs, attribution,
  retrieval timestamp and device-specific publisher ordering.

Open the HTML files in a browser. Their metadata/layout work locally; the
publisher-hosted images require internet access. Images and brands belong to their
owners; links are not reuse permission. Marketing images may predate the current
listing version and do not establish hands-on behavior or accessibility.

Refresh listing metadata and embedded board data from this directory with
`node refresh-app-references.mjs`. It requests Apple's public US lookup API,
selects at most six iPhone and two iPad images per app, and fails if a selected
app is missing or has no images. It does not refresh the separately curated Duo
gallery or download image binaries. Review changed ordering before relying on
the image ordinals in the analysis. The Duo gallery cites Apple's October 22
showcase; its source date is not a claim about a currently installed app version.

## Historical native captures

The `native-build-10` captures are real historical native simulator output copied
byte-for-byte from the verified migration archive. They are **not new screenshots**
and do not represent current sourcebd1cf7d or prove physical fold behavior.

- Capture source: `0772fd9`.
- Validation run: [42502718422](https://github.com/ErrantActions/-led-backpack/actions/runs/42502718422).
- Archive labels: build10 / native simulator.
- Detailed provenance, dimensions, hashes and original attachment names:
  [provenance.json](provenance.json).

| Capture | Review purpose | Interpretation limit |
|---|---|---|
| [Library](native-build-10/library-orientation-request.png) | Artwork hierarchy, clipping and vertical navigation | Original name records a landscape **request**; capture pixels alone do not prove pose or final orientation |
| [Live](native-build-10/live-preview.png) | Preview labeling, control/content hierarchy and vertical-space pressure | Demo speed, not real GPS or backpack readback; older than current Live arrangements |

These selected fixture screens were inspected before copying. Do not add private
messages, device identifiers, credentials, personal photos or real location data.
Keep unrelated archived captures in the private migration directory until reviewed.

## New capture checklist

Record source commit, run/test, simulator or physical device, SDK/OS, actual
window geometry, pose/active reserved regions, appearance, Dynamic Type size,
keyboard state and whether data is fixture/demo/live. Store unaltered captures.
Put annotations in a separate file rather than modifying the evidence image.

Third-party visuals remain at their linked sources in the boards and
[research reference index](../documentation/ios-duo-ux-research.md); their image
binaries are not copied here.
