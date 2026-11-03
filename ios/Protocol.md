# Packet protocol used by LED Backpack

This is an independently implemented interoperability codec, not vendor
firmware or copied application source. Device behavior can vary by model.

## BLE characteristics

| Family | Service | Write | Notify |
|---|---|---|---|
| Primary | FFF0 | FFF2 | FFF1 |
| Legacy | FF00 | FF02 | FF01 |

Short UUIDs expand using the standard Bluetooth base UUID. Subscribe before
querying. Use Core Bluetooth's write limits and WWR readiness rather than an
assumed Android MTU.

## Envelope

| Bytes | Field |
|---|---|
| `AA 55` | Header |
| `FF FF` on commands | Envelope field |
| u16 little-endian | Body length plus four |
| u16 little-endian | Sequence |
| variable | Body |
| u16 little-endian | Sum of all preceding packet bytes modulo 65536 |

Notifications can be fragmented or coalesced. Validate framing/checksum before
parsing. Status families are `81 82` and legacy `81 84`; nonzero status is an
error. Data families are `81 83` and legacy `81 85`.

Identity and dimensions are queried with `C1 03 0A ...` and `C1 03 1B 00`.
The parser handles a captured 22-byte parameter layout with a leading zero
before the two little-endian dimensions. Storage uses six pages of ten slot
records; each record includes an ID and a 16-byte identifier used for
occupancy/cache matching. Its size-like field is not assumed to be a GIF length.

## Upload and live display

The codec preserves correctly sized GIF bytes and uploads 960-byte application
chunks inside separately framed packets, followed by a content identifier and
playback selection. Begin-upload can erase the target slot: confirmation and
an original local copy are important.

Live display uses RGB-colored one-bit bitmap masks, packed row-major/MSB-first,
in bands of at most 112 mask bytes. The app sends changed-color groups with
black last. BLE submission and a local preview do not constitute pixel readback
or atomic frame presentation.

The optional stored-dwell field and some controls remain hardware-dependent;
see the acceptance checklist before relying on them.

## Tests

[Wire.swift](Packages/BackpackProtocol/Sources/BackpackProtocol/Wire.swift)
contains the typed codec. The committed
[test vectors](Packages/BackpackProtocol/Tests/BackpackProtocolTests/Fixtures/wire-vectors.json)
were generated from an independently hardware-exercised implementation using
synthetic media and non-personal parameter records. They require no Windows
tooling to run:

```sh
swift test --package-path Packages/BackpackProtocol
```

No firmware image, firmware readback implementation, private API key or device
password is included.
