# Aurora in motion

November 10, 2026. **Working browser motion study and native implementation
direction, not shipped SwiftUI motion.** Open the
[interactive atlas](../layouts/design-atlas.html) and choose a curated tab.
Use with the [visual language](design-language.md) and
[backend boundaries](backend-contract-boundaries.md).

## Signature: light that behaves like pixels

Keep the original mint-lavender-rose spectrum. Instead of arbitrary bouncing
controls, give the artwork a recognizable, coherent material:

| Moment | Motion | Purpose |
|---|---|---|
| Library | Two traveling pixel-light ribbons; pointer/touch adds a local light wake | Make the collection feel expressive before opening artwork |
| Social | Orbiting light and restrained constellation points | Creative community, not fabricated accounts/activity |
| Backpack | Light travels inside an illustrated panel; the silhouette stays grounded | Express the product without pretending it is connected |
| Create | A slowly turning six-lobed pixel bloom | Show creative possibility around a stable tool grid |
| Live demo | Continuous spectrum wave inside the explicitly labeled demo preview | Demonstrate expression, not GPS, BLE or playback telemetry |
| Enter a destination | Artwork and heading settle over 600 ms, not the entire form | Establish hierarchy without delaying interaction |
| Press a feature tile | 180 ms response, scale to 0.97; fine-pointer hover lifts 2 points | Tactility with a stable target and normal keyboard activation |

The browser uses one animation clock for visible decorative canvases, capped
pixel density, no external imagery and no new motion package. Pointer/touch
light is a transient visual response: it never submits, pairs, sends or changes
the selected account/device. There is no gyro permission or device-motion
tracking. Ordinary focus, consent, error and status text remain steady.

## Motion has an off switch

- **Pause motion** is always reachable outside the preview. It replaces moving
  artwork with the original complete raster composition, not a blank frame.
- Respect system Reduce Motion at startup and when it changes. Disable ambient
  animation, entrance transforms, hover travel and spring/press scaling; retain
  the same information, contrast, controls and full-color static artwork.
- Stop the frame loop when the document is hidden or no animated artwork is
  visible. Tear down the previous observer, event handlers and animation frame
  on navigation, fold/viewport changes and motion preference changes.
- Changing Duo geometry does not replay the destination entrance. Keep the same
  clock/selected content; native implementation must also preserve draft,
  recipient, operation ownership and actual playback state.
- No flashes, strobing, simulated haptics, infinitely spinning success badges,
  mandatory shimmer or decorative movement over message bodies and warnings.
- Respect Increase Contrast and Reduce Transparency separately from motion.
  Accessibility preferences do not remove a warning, consent or status cue.

## Native implementation contract

This study does not implement these effects in the production app. Forma
preserves editable static controls and embedded raster keyframes; the animated
atlas is the motion reference, not a shader export.

Use the existing Aurora colors, backgrounds and surfaces rather than adding a
second theme. Prefer SwiftUI `Canvas`/a paused `TimelineView` for this small
decorative pixel field; use native bounded animations for press/selection.
Keep the clock above layout-dependent branches. Pause offscreen/inactive work,
honor accessibility motion/transparency/contrast settings, and profile on actual
supported devices before choosing a frame-rate or energy claim.

Related artwork can later use a native matched transition from tile to preview,
but do not animate across a system reserved region, fabricate a second output
display or change navigation/operation identity to produce that effect.
The current browser does **not** claim a matched-geometry/native fold transition.

Hardware transfer progress follows real native progress; publication follows
current moderation state; chat acknowledgement follows server persistence.
Decorative motion must never imply any of those operations succeeded.
Keep Stop, retry and required review available during every transition.

## Acceptance before shipping

1. Inspect each curated tab with motion on, paused and system Reduce Motion.
2. Verify visible frame changes, no frame changes while paused, static images
   loaded, and old canvas instances stop after navigation.
3. Check keyboard focus, readable labels, clipping and page overflow at compact,
   short-window and Duo variants. Scrolling must work during animation.
4. Verify offscreen/background suspension and preference changes without a new
   render loop leak. Native tests must cover scene inactivity and actual energy.
5. On native hardware, validate Dynamic Type, VoiceOver, Reduce Transparency,
   Increase Contrast, thermal/low-power behavior and the full Duo acceptance
   matrix. Browser geometry and frame checks do not certify these.
