# LED text sizing

The LED pixel typeface has a **5 x 7 LED cell**, including intentional empty
rows/columns in narrow letters and punctuation. It includes all 95 printable
ASCII characters: uppercase, lowercase, digits, punctuation and space.
Case is preserved. Other scripts use a system typeface.

Scaling repeats complete pixels; there is no fractional stretching. The gap
between characters is one base pixel, also scaled. An `n`-character line is
`(6n - 1) * scale` LEDs wide. Lines have a one-base-pixel gap.

## 64 x 64 backpack

The artwork editor reserves two LEDs at each edge, leaving 60 x 60.

| Scale | Glyph cell | Character gap | Characters per line | Maximum lines |
|---|---|---|---|---|
| 1 | 5 x 7 | 1 | 10 | 7 |
| 2 | 10 x 14 | 2 | 5 | 3 |
| 3 | 15 x 21 | 3 | 3 | 2 |
| 4 | 20 x 28 | 4 | 2 | 2 |
| 5 | 25 x 35 | 5 | 2 | 1 |
| 6 | 30 x 42 | 6 | 1 | 1 |
| 7 | 35 x 49 | 7 | 1 | 1 |
| 8 | 40 x 56 | 8 | 1 | 1 |

These are geometric limits, not guarantees of readability at a riding
distance. Start with **10 x 14** for short words, **15 x 21** for three
characters, or **20 x 28** for two digits. Judge the physical display while
stationary, at the intended viewing distance.

Auto fit keeps words intact when a whole word can fit at the base size.
For example, `HELLO` remains one line at 10 x 14, rather than becoming
`HEL` / `LO` merely to make letters larger. Explicit letter sizes never
silently shrink. If a fixed-size message does not fit, shorten it, choose a
smaller size, insert deliberate line breaks, or use scrolling.

A 16 x 16 panel supports cells up to 10 x 14, but only two 5 x 7
characters fit across at base size. A 96 x 128 panel supports larger cells;
the in-app sizing table uses the selected panel's actual bounds.

## Inspect and test on the backpack

In **Studio > Text to GIF**, select **Pixel**, then
**Inspect every letter and size**. The inspector shows each glyph using the
same pixels as saved artwork, its exact LED dimensions, and line capacities.

**Save all-character test GIF** saves 94 non-space characters at the selected
size, one per frame at half-second intervals. Preview it in Library first.
Sending it to the backpack requires an explicit slot upload and can replace
that slot; choose expendable artwork. No upload happens merely by saving the
proof GIF.

## Live text

New live themes default to **LED pixel**. Saved themes keep their chosen
typeface; change an older theme under **Live > theme editor > Typeface**.
Live text uses the same glyph masks with whole-pixel sizing. Above/below
labels wrap at base size instead of being cropped. If a pixel line cannot fit,
the app reports it rather than silently dropping letters; use shorter text
or marquee. International text and very small live layouts retain the system
font path. Gauges and labels reduce the space available to the main value.

Previously exported GIFs contain their old rendered pixels. Updating the app
does not repair those files or rewrite backpack storage; regenerate the text.
