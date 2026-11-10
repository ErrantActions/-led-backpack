# App UI/UX reference patterns

Reviewed November 10, 2026. This is design research, not a feature specification
or a claim that the native app has changed.

## Open the visual evidence

- [Searchable app comparison board](../screenshots/app-reference-board.html):
  **44 apps / 312 published screenshot references**, including seven motorcycle
  apps, six messaging apps, five social/community apps and nine mainstream/premium
  product references.
- [iPhone Duo examples](../screenshots/iphone-duo-examples.html):
  **10 additional Apple-published device compositions** specifically identifying
  Duo experiences. Do not treat ordinary iPad screenshots as Duo evidence.
- [Machine-readable source register](../screenshots/app-references.json):
  publisher, official listing, retrieval timestamp, listing version/date, image
  device and publisher ordering.
- [Native behavior and acceptance matrix](ios-duo-ux-research.md) and
  [original layout studies](../layouts/README.md).

The board selects up to six iPhone and two iPad images per US listing. Image
numbers below mean **publisher ordering within the labeled device family**,
not app screen numbers. A cover, award or illustration is not proof of controls.
Some apps have fewer images. Store version dates are not image capture dates.
The images remain on publisher/Apple hosts; they have not been copied into this
repository or licensed for reuse. An internet connection is required.

These are screenshot inspections and primary-source descriptions, **not hands-on
tests**. Availability, subscriptions, hardware compatibility, accessibility,
privacy guarantees and released behavior need independent verification.

## LED, hardware and device management

| App / board evidence | Useful visible pattern | Transfer to LED Backpack | Do not copy or infer |
|---|---|---|---|
| [Divoom](../screenshots/app-reference-board.html#app-1237452417), iPhone 1-3 | Pixel canvas, animation tools and visual gallery | Distinguish creating, browsing and sending; let artwork dominate | Busy decoration, hardware compatibility or community moderation quality |
| [iPixel Color](../screenshots/app-reference-board.html#app-1562961996), iPhone 1-3 | Dark canvas/palette, frame strip and playback/music context | Keep current frame, preview and device destination understandable | Tiny tools as accessibility precedent; unsupported LED protocols |
| [WLED Official](../screenshots/app-reference-board.html#app-6446207239), iPhone 1-3 | Device rows with direct controls, color surface, separate device-edit form | Make live control direct; separate configuration from operation | Successful radio delivery from a slider's appearance |
| [Nanoleaf](../screenshots/app-reference-board.html#app-1049333656), iPhone 1-3 | Control sliders, scene creation and schedules | Separate immediate control from saved scenes | Scheduling complexity in every first-level screen |
| [Philips Hue](../screenshots/app-reference-board.html#app-1055281310), iPhone 2-3; 1 is promotional | Room/device cards and contextual controls | Cards should carry meaningful identity and state | A colored card as the only connected/error indication |
| [Apple Home](../screenshots/app-reference-board.html#app-1110145103), iPhone 1-3 | Overview, activity log and focused category view | Progressive hierarchy instead of one large device form | Apple ecosystem integration or security guarantees |
| [Apple Find My](../screenshots/app-reference-board.html#app-1514844621), iPhone 1-3 | Map/sheet, finding direction and device context | Put identity, location freshness and recovery actions together | Precision finding without supported ranging hardware; RSSI as distance |

**Direction:** one clear destination and one honest operation state. Distinguish
selected, connecting, connected, transferring, confirmed and unavailable rather
than displaying a generic green success pill. Keep destructive replacement and
device reassignment separate from normal playback.

## Messaging apps

| App / board evidence | Useful visible pattern | Transfer to LED Backpack | Do not copy or infer |
|---|---|---|---|
| [Signal](../screenshots/app-reference-board.html#app-874139669), iPhone 1-6 | Conversation list, recognizable bubble/composer hierarchy, contextual media/group tools | Keep recipient, thread and composer primary; secondary media tools on demand | End-to-end encryption, retention behavior or a need for calls |
| [Telegram](../screenshots/app-reference-board.html#app-686449807), iPhone 1-6 | Rich conversation tools and separate shared-media surface | Keep attachments discoverable without a permanent toolbar wall | That every chat is end-to-end encrypted; decorative complexity |
| [WhatsApp](../screenshots/app-reference-board.html#app-310633997), iPhone 1-5 and iPad 1 | Recognizable thread/media/group context; expanded list/detail | Preserve selected thread and draft through compact/expanded changes | Stories/status features merely because they exist in a peer |
| [Discord](../screenshots/app-reference-board.html#app-985746746), iPhone 1-6 | Community/channel hierarchy and voice/activity panels | Make group and audience explicit before composing | Server/channel complexity in a one-purpose recovery thread |
| [Messenger](../screenshots/app-reference-board.html#app-454638411), iPhone 1-6 | Recent chats/people, conversation, calls and promotional surfaces | Clear entry into a conversation; recognizable sending affordance | Unrequested AI, creator content or contact exposure |
| [Slack](../screenshots/app-reference-board.html#app-618783545), iPhone 2-6; 1 is promotional | Workspace/channel context, threads, file cards and contextual reactions | Maintain conversation context; separate attachment details | A work-platform information architecture for simple contact |

### Messaging design decisions to carry forward

1. A recovery inbox is not a public community feed. Show the related backpack,
   sender context and current consent/contact state without leaking owner identity.
2. Keep draft text, recipient and selected thread stable when the keyboard appears,
   a secondary pane disappears, or the device folds.
3. Keep sending, pending, failed and retry states distinct. Do not imply delivered
   or read unless the actual transport supplies that evidence.
4. Close/resolve, block and report are separate operations with different effects.
   Avoid a single ambiguous destructive menu action.
5. On an expanded display, inbox plus thread can help. On compact displays, the
   thread must remain usable without a permanently visible inbox.
6. Media and reactions are secondary to the contact task. Do not add them simply
   to resemble a general messenger.

## Social and community apps

| App / board evidence | Useful visible pattern | Transfer to LED Backpack | Do not copy or infer |
|---|---|---|---|
| [Instagram](../screenshots/app-reference-board.html#app-389801252), iPhone 1-6 | Media-first view, contextual action rail, comments sheet and sharing context | Separate viewing, commenting, saving and choosing an audience | Infinite-reel engagement loops; icon-only controls as universal best practice |
| [Pinterest](../screenshots/app-reference-board.html#app-429047995), iPhone 1-6 | Visual grid, refinement/palette context and item detail with Save | Artwork discovery, collections and clear item actions | Shopping funnels, image reuse rights or mixed-ratio grids for every LED format |
| [Reddit](../screenshots/app-reference-board.html#app-1064216828), iPhone 2-6; 1 is promotional | Community identity, post/reply context, profile and voting | Preserve creator attribution and community/report context | Popularity ranking for safety, recovery or device trust |
| [Bluesky](../screenshots/app-reference-board.html#app-6444370199), iPhone 1-5 and iPad 1 | Feed/topic choice, conversation/compose context and expanded feed | Explicit discovery scope and visible public/private distinctions | People recommendations as consent to access contacts |
| [Mastodon](../screenshots/app-reference-board.html#app-1571998974), iPhone 3-6; 1-2 are brand art | Feed, profile, compose and server rules | Make account/community identity and rules explicit | Brand illustrations as evidence of actual controls; federated features by default |

**Direction:** separate a private local library from public discovery. An artwork
detail should explain creator, format, local/cloud availability and the next
action. Uploading, publishing, saving locally and sending to a backpack must not
be interchangeable verbs. Keep reporting reachable without making the whole
library a moderation dashboard.

## Motorcycle apps

| App / board evidence | Useful visible pattern | Transfer to LED Backpack | Do not copy or infer |
|---|---|---|---|
| [REVER](../screenshots/app-reference-board.html#app-975571447), iPhone 2-3; 1 is a cover | Route-discovery map and separate recording/sharing presentation | Distinguish route selection, active session and post-ride sharing | A handlebar marketing image as evidence that phone interaction is safe |
| [calimoto](../screenshots/app-reference-board.html#app-1209129603), iPhone 2-3; 1 is promotional | Large turn/distance information; route choices with map context | Clear route review and a small set of primary session facts | That our backpack is road-certified navigation or a turn-signal substitute |
| [Detecht](../screenshots/app-reference-board.html#app-1373032762), iPhone 2-3; 1 is a cover | Curvy-route planning and round-trip choice with a map | Make planning choices understandable before Start | Crash detection, emergency response or safety-service reliability from screenshots |
| [Cardo Ride](../screenshots/app-reference-board.html#app-1087005682), iPhone 2-3; 1 is promotional | Ride tracking map and navigation status | Differentiate route progress from recording state | Headset interoperability or live group tracking from a store image |
| [Scenic](../screenshots/app-reference-board.html#app-1089668246), iPhone 2-3; 1 is a cover | Route planning and map-dominant navigation with visible status | Keep route context visible during stationary review | Tiny map tools as adequate glove controls; unsupported offline operation |
| [BMW Motorrad Connected](../screenshots/app-reference-board.html#app-1250173746), iPhone 1-3 | Vehicle identity, current vehicle facts and separate service detail | Anchor controls to the selected physical backpack; separate maintenance/settings | Compatibility with arbitrary motorcycles, cradle or vehicle telemetry |
| [Yamaha MyRide](../screenshots/app-reference-board.html#app-1255766787), iPhone 1-3 | Active ride metrics, Go Ride entry and recorded-route list | Separate current session from history; show elapsed/session state clearly | Lean-angle/speed scores as desirable incentives or certified measurement |

The current US listing for App Store ID `1087005682` is **Cardo Ride - Motorcycle
App**, published by **RISER GmbH**. The board uses that returned name rather than
silently labeling its current images as the old RISER product.
Yamaha MyRide here is the routes app, not the separate MyRide - Link listing.

### Riding constraints

- Design configuration, route review, messaging and sharing for **stationary use**.
  Do not introduce phone tasks, competitive speed goals or attention-demanding
  games while riding.
- A ride/session surface should make recording, paused, ended, GPS unavailable
  and stale data explicit. A large number alone can be misleading.
- Larger controls and strong contrast are useful starting points, not proof of
  sunlight legibility, glove usability, mounting suitability or road safety.
- Location/route history is sensitive. Use fixture routes for research; do not
  publish a person's home/start/end point or enable live group location by default.
- Do not add emergency, collision-detection, navigation or regulatory claims
  because another publisher advertises them.
- For a concrete connected-motorcycle limitation, [BMW's official
  FAQ](https://faq.bmw-motorrad.co.uk/s/article/Is-there-info-on-the-Motorrad-Connected-app-E23lC?language=en_GB)
  ties functionality to supported vehicle/TFT or ConnectedRide equipment.
  Hardware-specific UI is inspiration, not transferable capability.

## Outdoor, activity and media tools

| App / board evidence | Useful visible pattern | Transfer / limit |
|---|---|---|
| [Strava](../screenshots/app-reference-board.html#app-426826309), iPhone 1-3 | Activity feed and chart/statistics hierarchy | Separate session history from live status; no dangerous competition incentives |
| [komoot](../screenshots/app-reference-board.html#app-447374873), iPhone 2-3; 1 is promotional | Discovery/detail card and navigation map with key facts | Review context before starting; no implied navigation implementation |
| [Ride with GPS](../screenshots/app-reference-board.html#app-893687399), iPhone 2-3; 1 is a cover | Navigation map/elevation and route-planning metrics | Separate planning from active operation; do not encourage adjustment while riding |
| [AllTrails](../screenshots/app-reference-board.html#app-405075943), iPhone 2-3; 1 is a cover | Discovery cards and trail facts before a map action | Show eligibility and context before Start; hiking UI is not motorcycle safety evidence |
| [Garmin Connect](../screenshots/app-reference-board.html#app-583446403), iPhone 1-3 | Summary dashboard and focused metric detail | Clear summary-to-detail hierarchy; do not import irrelevant health data |
| [Gentler Streak](../screenshots/app-reference-board.html#app-1576857102), iPhone 1-3 | Explainable headline status and supporting chart | One understandable state story rather than a wall of metrics; no gamified riding pressure |
| [Apple Photos](../screenshots/app-reference-board.html#app-1584215428), iPhone 1-3 | Art-first collections, editing around a preview, video timeline | Keep media dominant and editing contextual; availability still needs honest labels |
| [Darkroom](../screenshots/app-reference-board.html#app-953286746), iPhone 1 and 3; 2 is an award slide | Preview with editing slider and preset gallery | Preview plus focused tools; award art is not interaction evidence |
| [Procreate Pocket](../screenshots/app-reference-board.html#app-916366645), iPhone 1-3 | Canvas, contextual tools and brush chooser | Pixel/GIF editing without permanent forms; provide accessible alternatives to gestures |
| [Overcast](../screenshots/app-reference-board.html#app-888422857), iPhone 1 and iPad 1 | Collection/playlist hierarchy and expanded playback detail | Distinguish queue, collection and current playback; only one phone image was available |

## Mainstream and premium product references

These are widely recognizable products and deliberately selected premium-product
references, not a verified popularity ranking or a claim that every listing is
paid. Free download, subscriptions, an award slide and good UX are different things.
The first three iPhone images per app were visually compared on the board.

| App / board evidence | Visible pattern | Transfer / limit |
|---|---|---|
| [Spotify](../screenshots/app-reference-board.html#app-324684580), iPhone 1-3 | Collection browsing, a distinct player and playlist detail | Keep artwork collections separate from current playback; no recommendation or subscription requirement for local use |
| [Netflix](../screenshots/app-reference-board.html#app-363590051), iPhone 1-3 | Selected media with Play, discovery clips and media shelves | A focused artwork review before an explicit action; do not copy autoplay or introduce a clip feed |
| [YouTube](../screenshots/app-reference-board.html#app-544007664), iPhone 1-3 | Creation sheet, short-form viewer and conventional watch detail | Creation, consumption and creator context are different tasks; engagement loops are not a design requirement |
| [Notion](../screenshots/app-reference-board.html#app-1232780281), iPhone 2-3; 1 is brand art | Quiet workspace/page lists with current page context | Predictable collection and settings hierarchy; do not import work-platform complexity or AI |
| [Things 3](../screenshots/app-reference-board.html#app-904237743), iPhone 1-3 | Inbox hierarchy, Today grouping and dated Upcoming list | Group preparation into understandable steps with restrained emphasis, rather than a dashboard of equally bright cards |
| [Fantastical](../screenshots/app-reference-board.html#app-718043190), iPhone 1 and 3; 2 promotes integrations | Calendar/agenda hierarchy and alternate calendar views | Events need dates, current selection and a readable agenda; integration/award claims are not evidence of our capabilities |
| [Flighty](../screenshots/app-reference-board.html#app-1358823008), iPhone 2-3; 1 is a cover | Flight-list sheet over map; lock-screen activity/status compositions | Give one operation a clear state, freshness and next step; do not imply a Live Activity or transport receipt exists here |
| [Bear](../screenshots/app-reference-board.html#app-1016366447), iPhone 2-3; 1 is brand/award art | Note content above contextual editing controls, light and dark examples | Draft content should dominate its tools; preserve account-bound drafts, not the peer's branding or artwork |
| [Halide](../screenshots/app-reference-board.html#app-885697368), iPhone 1 and 3; 2 is promotional | Camera preview with controls close to the active image | Keep canvas and relevant editing tools related; listing name Mark III does not make the older Mark II marketing slide current UI evidence |

**Synthesis:** premium here means calm hierarchy, predictable state, careful
typography and fewer competing controls, not more gradients or glass. Keep the
existing Aurora identity, but reserve mint for a deliberate next action and use
quiet surfaces for optional tools. Preserve native navigation and accessibility.

## iPhone Duo-specific examples

Primary evidence: [Apple's October 22, 2026 app
showcase](https://www.apple.com/ca/newsroom/2026/10/developers-bring-incredible-new-app-experiences-to-iphone-duo/).
The [dedicated gallery](../screenshots/iphone-duo-examples.html) links ten original
Apple image URLs and labels the difference between a still and article-described
behavior. These are promotional compositions, not our native screenshots.

| Specific Duo example | Apple's described behavior / visual role | Proposed application here |
|---|---|---|
| [Netflix](../screenshots/iphone-duo-examples.html#netflix) | Outer-to-inner content continuity; partial-fold viewing composition | Preserve the current artwork/playback session, rather than resetting on resize |
| [Prime Video](../screenshots/iphone-duo-examples.html#prime-video) | Article describes video above X-Ray context; the composition visibly shows a partially folded device, despite source alt text calling it fully open | Preview plus optional information; essential controls cannot depend on the secondary region |
| [Zoom](../screenshots/iphone-duo-examples.html#zoom) | Shared content and participants together on the inner display | Related content and context, not unrelated dashboard panels |
| [Slack](../screenshots/iphone-duo-examples.html#slack) | Workspace/channels and thread context on the larger display | Inbox/thread hierarchy with a usable compact conversation |
| [Fantastical](../screenshots/iphone-duo-examples.html#fantastical) | Calendar, tasks and menus visible together | Event overview and selected route/detail with clear selection ownership |
| [Detail](../screenshots/iphone-duo-examples.html#detail) | Video and transcript side by side | GIF preview and frame/timing tools; not a requirement for AI or transcripts |
| [Instagram Edits](../screenshots/iphone-duo-examples.html#edits) | Article describes preview/timeline/tools; the selected still shows preview beside clip/media thumbnails | Persistent selected frame, draft and edit state across arrangements |
| [VLLO](../screenshots/iphone-duo-examples.html#vllo) | More footage and controls visible on the inner display | Use room to reduce tool switching, not just enlarge every control |
| [NYT Cooking](../screenshots/iphone-duo-examples.html#nyt-cooking) | Article describes steps/timers/video during propped use; selected still is fully open | Glanceable stationary setup, never a justification for interacting while riding |
| [Lyft](../screenshots/iphone-duo-examples.html#lyft) | Map and ride choices visible together | Map plus route/session review without unnecessary back-and-forth |

Apple also names Instagram, Bear, Things, Flighty and other apps. Their mention
is not a separately inspected screenshot in this gallery. Word/Outlook were
described as forthcoming in that article; do not turn an announcement into a
verified shipped-state claim. No ordinary App Store image in the 44-app board
has been relabeled as Duo output.

### Native translation, not screenshot imitation

Follow [Apple's preparation
guide](https://developer.apple.com/iphone-duo/prepare/) and
[adaptive-layout talk](https://developer.apple.com/videos/play/tech-talks/111463/),
plus the [native acceptance matrix](ios-duo-ux-research.md#9-native-acceptance-matrix).

- **Navigation:** system-managed bars can become vertical. Respect native safe
  areas and the system's preferred edge; do not bake a trailing rail into art.
- **Task structure:** use ordinary list/detail navigation for inboxes and
  collections. Use arrangements for related primary/secondary task content.
  Keep navigation outside arrangements and respect container restrictions.
- **Compact/outer:** maintain a complete useful task. Secondary content can
  disappear; Send, Stop, recipient context and error recovery remain reachable.
- **Expanded/fully open:** exploit room for preview/context, but do not assume an
  active fold division when the device is fully open.
- **Partial fold:** protect important content and controls from current division
  and camera-occlusion regions. The chosen app still does not determine geometry.
- **Keyboard:** preserve draft, selection and operation state; keep the composer
  and pending/error status reachable when available height changes.
- **Versioning:** preserve the existing iOS 17 fallback. Availability-gate newer
  APIs; a new SDK requirement is not permission to raise deployment targets.
- **Validation:** test actual container geometry, Dynamic Type, VoiceOver,
  reduced motion, keyboard and both bar edges in native output. Marketing stills
  and Forma layouts cannot prove these behaviors.

## Prioritized future coding slices

These are proposed follow-ups, not changes made by this research:

1. **Send & Play review:** make destination, prepared content/slot outcome,
   transport and the final action clear together. Reproduce current behavior
   before changing it; preserve inventory/empty-slot and receipt protections.
2. **Recovery contact:** test consent states, composer/draft preservation,
   pending/retry and distinct close/block/report actions across geometry changes.
3. **Library/detail:** retain art-first browsing, explicit local/cloud/processing
   states, creator attribution and predictable Save/Send/Publish verbs.
4. **GIF Studio:** stable preview/frame selection with contextual timing tools;
   compare compact editing against Duo preview-plus-tools.
5. **Stationary ride setup:** simple device/GPS readiness and honest session
   state. Do not expand into navigation or emergency services as a side effect.

For each slice, capture the same fixture task in compact, expanded, partial-fold
and keyboard states. Record source commit and environment as required by the
[screenshot checklist](../screenshots/README.md#new-capture-checklist). Compare
completion, recoverability and accessible reachability, not resemblance alone.
