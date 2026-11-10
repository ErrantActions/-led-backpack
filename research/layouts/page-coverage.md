# Aurora Fieldwork page coverage

Design study, November 10, 2026. **Not a production implementation or native test result.**

Open the [interactive atlas](design-atlas.html), [design language](../documentation/design-language.md),
[editable layout](led-backpack.layout.json) or [validation record](design-validation.json).

## What is covered

- 198 existing editable studies retained: five curated tab compositions and 193 source-derived surfaces.
- Four missing native-surface studies added: connected-backpack adoption, recovery inbox, recovery thread, and the development-only erase fixture.
- 42 historical image-only reference screens remain unchanged.
- Original screen/element IDs, source mappings, source fingerprints, native code, action targets and authored source text are retained.
- Thirteen current-source inventories were refreshed separately from the curated drafts; archived elements remain hidden rather than losing their IDs. The current static import recognizes 196 covered views and one retained legacy firmware study.
- Every editable study has shared typography/control treatment, a compact layout and ten measured geometry variants.
- The five tabs have new task compositions. Source-derived surfaces have an adaptive visual pass and individual design specifications; they are not hand-validated runtime state compositions.
- Source components and fixtures are listed explicitly: **202 studies are not 202 independent production pages**.

## What is not established

Source imports may flatten conditional branches and leave values unbound. Native controllers, system pickers,
keyboard behavior, native light appearance, VoiceOver/Dynamic Type, real reserved regions and actual
radio/backend outcomes are not executed or certified by these studies. Use the native acceptance matrix
before calling the app redesign implemented. No backend semantics, deployment or Swift source changed.

## Per-surface design ledger

| Study | Family | Native source | Design treatment |
|---|---|---|---|
| [Library · visual draft](design-atlas.html#1393bc4c-2dae-4fb3-b5c2-a502eea0e85d) | Library and playback | Curated tab draft | Curated task composition |
| [Social · visual draft](design-atlas.html#2b96a6ae-1c43-4a2e-a264-9b9741630475) | Community and moderation | [SocialTabView](../../ios/LEDBackpack/SocialTabView.swift#L104) | Curated task composition |
| [Backpack · visual draft](design-atlas.html#dc9aa37c-28c8-4cb5-9a72-46d4b9440d0a) | Backpack and hardware | [DeviceView](../../ios/LEDBackpack/Views.swift#L104) | Curated task composition |
| [Create · visual draft](design-atlas.html#cb3e1e7d-87a1-4779-a0f3-39a2d255d2f0) | Creation and editing | [CreateView](../../ios/LEDBackpack/CreateView.swift#L4) | Curated task composition |
| [Live · visual draft](design-atlas.html#7657db0b-48c5-4c19-8f0c-a67192fa9bc4) | Live and nearby | [LiveView](../../ios/LEDBackpack/StudioAndSettings.swift#L7) | Curated task composition |
| [LibraryView](design-atlas.html#623d88b0-2b3c-4411-8d5c-8ea660932bc3) | Library and playback | [LibraryView](../../ios/LEDBackpack/Views.swift#L244) | Source-derived adaptive visual study |
| [DeviceResearchView](design-atlas.html#0807d3b7-c891-406e-b6c4-56b2805153b2) | Backpack and hardware | [DeviceResearchView](../../ios/LEDBackpack/AccountDeviceResearch.swift#L72) | Source-derived adaptive visual study |
| [AccountDevicesView](design-atlas.html#1d1c2b9a-f7fd-4e73-a0e6-6927f2c76e6f) | Account and preferences | [AccountDevicesView](../../ios/LEDBackpack/AccountDevices.swift#L199) | Current-source refreshed adaptive study |
| [AccountDeviceEditView](design-atlas.html#3237c509-e24a-4817-a89d-ba59752300fd) | Account and preferences | [AccountDeviceEditView](../../ios/LEDBackpack/AccountDevices.swift#L364) | Current-source refreshed adaptive study |
| [AccountDeviceCardView](design-atlas.html#73dfa1af-7b43-486a-8aa0-ae7e00078d72) | Shared components | [AccountDeviceCardView](../../ios/LEDBackpack/AccountDevices.swift#L380) | Source-derived adaptive visual study |
| [FirmwareLibraryView](design-atlas.html#b35739d1-cf45-49aa-b4a8-f09ef43d999f) | Backpack and hardware | [FirmwareLibraryView](../../ios/LEDBackpack/AccountFirmwareLibrary.swift#L145) | Source-derived adaptive visual study |
| [FirmwareDraftUploadView](design-atlas.html#feff669c-6677-4f00-9369-52ab348e2980) | Backpack and hardware | [FirmwareDraftUploadView](../../ios/LEDBackpack/AccountFirmwareLibrary.swift#L250) | Source-derived adaptive visual study |
| [ViewerMediaPreferencesView](design-atlas.html#83da60f4-4670-4a1b-a8a6-d396c911852f) | Library and playback | [ViewerMediaPreferencesView](../../ios/LEDBackpack/AccountMediaPreferences.swift#L110) | Source-derived adaptive visual study |
| [AccountApprovedProfileAvatar](design-atlas.html#b58f820a-4d1b-4732-a964-dc296e957221) | Shared components | [AccountApprovedProfileAvatar](../../ios/LEDBackpack/AccountMediaPreferences.swift#L159) | Source-derived adaptive visual study |
| [AdminArtworkView](design-atlas.html#d6222d22-6adf-45be-ac5b-7ae4f61f8a92) | Community and moderation | [AdminArtworkView](../../ios/LEDBackpack/AdminArtworkViews.swift#L5) | Source-derived adaptive visual study |
| [ArtworkComparison](design-atlas.html#3261ee06-ec11-4901-bd90-b8c661e7f6f7) | Library and playback | [ArtworkComparison](../../ios/LEDBackpack/AdminArtworkViews.swift#L147) | Source-derived adaptive visual study |
| [AppleLinkAccountView](design-atlas.html#ab5b35bb-ce53-4ca1-b445-68fa38ed5f87) | Account and preferences | [AppleLinkAccountView](../../ios/LEDBackpack/AppleLinkAccountView.swift#L4) | Source-derived adaptive visual study |
| [AppleSystemButton](design-atlas.html#dae8e14e-bdf7-414b-9fe6-e297a86112c9) | Shared components | [AppleSystemButton](../../ios/LEDBackpack/AppleSignIn.swift#L144) | Source-derived adaptive visual study |
| [AppleWindowReader](design-atlas.html#94363686-efc6-4980-be99-6f0493a98eb9) | Shared components | [AppleWindowReader](../../ios/LEDBackpack/AppleSignIn.swift#L170) | Source-derived adaptive visual study |
| [AppleSignInControl](design-atlas.html#53746361-9086-4358-b418-db88d4529928) | Shared components | [AppleSignInControl](../../ios/LEDBackpack/AppleSignIn.swift#L211) | Source-derived adaptive visual study |
| [ScopedPhoneCanvasControls](design-atlas.html#5dd21d4b-117a-4813-bdd9-be682ec024b7) | Shared components | [ScopedPhoneCanvasControls](../../ios/LEDBackpack/AutomaticPhoneSession.swift#L122) | Source-derived adaptive visual study |
| [BackpackDirectSendView](design-atlas.html#00178280-dd3a-4c23-ba11-fe5b32f0b8ef) | Backpack and hardware | [BackpackDirectSendView](../../ios/LEDBackpack/BackpackDirectSendView.swift#L4) | Source-derived adaptive visual study |
| [DirectSendPreview](design-atlas.html#816653e0-401f-4bf5-827f-b1456d348867) | Shared components | [DirectSendPreview](../../ios/LEDBackpack/BackpackDirectSendView.swift#L83) | Source-derived adaptive visual study |
| [BackpackStorageView](design-atlas.html#0413ca16-0d25-442a-8cdf-1b002f84ab72) | Backpack and hardware | [BackpackStorageView](../../ios/LEDBackpack/BackpackStorageViews.swift#L5) | Source-derived adaptive visual study |
| [StoredSlotThumbnail](design-atlas.html#c138a8de-4474-401b-b315-b3865dc4f273) | Shared components | [StoredSlotThumbnail](../../ios/LEDBackpack/BackpackStorageViews.swift#L52) | Source-derived adaptive visual study |
| [StoredSlotDetail](design-atlas.html#27457346-641f-4d64-a41b-8d40ee50210c) | Backpack and hardware | [StoredSlotDetail](../../ios/LEDBackpack/BackpackStorageViews.swift#L84) | Source-derived adaptive visual study |
| [EraseBackpackView](design-atlas.html#16da140f-6901-4b3c-b44a-f2476b4657cf) | Backpack and hardware | [EraseBackpackView](../../ios/LEDBackpack/BackpackStorageViews.swift#L123) | Current-source refreshed adaptive study |
| [BatchTransferView](design-atlas.html#5dfd9dc5-ef87-4d17-bb18-dc295eb7aafc) | Backpack and hardware | [BatchTransferView](../../ios/LEDBackpack/BatchTransferViews.swift#L5) | Source-derived adaptive visual study |
| [BatchSendConfirmation](design-atlas.html#f3394de7-dd8e-4c31-97b5-487fab5f8b3e) | Library and playback | [BatchSendConfirmation](../../ios/LEDBackpack/BatchTransferViews.swift#L97) | Source-derived adaptive visual study |
| [BatchMediaPicker](design-atlas.html#23d014b2-090d-42da-886b-d73510a0b41d) | Library and playback | [BatchMediaPicker](../../ios/LEDBackpack/BatchTransferViews.swift#L157) | Source-derived adaptive visual study |
| [ChatFixedPinPicker](design-atlas.html#dc0cc88d-c3ef-495a-be06-b87687591260) | Messaging | [ChatFixedPinPicker](../../ios/LEDBackpack/ChatFixedPins.swift#L6) | Source-derived adaptive visual study |
| [ChatFixedPinCard](design-atlas.html#e53300ff-fc1b-4340-acfe-fd4951fb285d) | Shared components | [ChatFixedPinCard](../../ios/LEDBackpack/ChatFixedPins.swift#L45) | Source-derived adaptive visual study |
| [ChatReferenceCardView](design-atlas.html#10a53d76-f966-4a1e-8133-1c91cae93312) | Shared components | [ChatReferenceCardView](../../ios/LEDBackpack/ChatReferences.swift#L154) | Source-derived adaptive visual study |
| [SharedChatEventDateView](design-atlas.html#8fff9eeb-a06e-4fa3-804e-34f8e1c9ed43) | Events and routes | [SharedChatEventDateView](../../ios/LEDBackpack/ChatReferences.swift#L192) | Source-derived adaptive visual study |
| [ChatReferencePicker](design-atlas.html#eec6d569-5624-4e40-afd4-104c18eda6f1) | Messaging | [ChatReferencePicker](../../ios/LEDBackpack/ChatReferences.swift#L202) | Source-derived adaptive visual study |
| [CloudArtworkRow](design-atlas.html#0bfb0b99-78af-439f-861d-5834107736af) | Shared components | [CloudArtworkRow](../../ios/LEDBackpack/CloudLibrary.swift#L202) | Source-derived adaptive visual study |
| [CloudArtworkDetail](design-atlas.html#9ec94967-1e94-4f88-96ab-ece7e3d37eef) | Library and playback | [CloudArtworkDetail](../../ios/LEDBackpack/CloudLibrary.swift#L218) | Source-derived adaptive visual study |
| [CloudVaultAdoptionView](design-atlas.html#b9817fc8-8c17-419c-b0a8-0af50215f7e4) | Library and playback | [CloudVaultAdoptionView](../../ios/LEDBackpack/CloudVaultAdoptionViews.swift#L7) | Source-derived adaptive visual study |
| [CloudVaultAdoptionApprovalView](design-atlas.html#cfd3aa2a-a7f8-4be1-a227-97aad2c09020) | Library and playback | [CloudVaultAdoptionApprovalView](../../ios/LEDBackpack/CloudVaultAdoptionViews.swift#L64) | Source-derived adaptive visual study |
| [CloudVaultQRScanner](design-atlas.html#0773eb77-e3c7-4d08-b69c-eb7110bee103) | Library and playback | [CloudVaultQRScanner](../../ios/LEDBackpack/CloudVaultAdoptionViews.swift#L111) | Source-derived adaptive visual study |
| [CloudVaultWindowReader](design-atlas.html#0e9e7130-8156-4345-a265-14b3758460ed) | Shared components | [CloudVaultWindowReader](../../ios/LEDBackpack/CloudVaultPasskeys.swift#L10) | Source-derived adaptive visual study |
| [CloudVaultSettingsView](design-atlas.html#d0ccd8f8-4894-49cf-853f-a194bae084ed) | Account and preferences | [CloudVaultSettingsView](../../ios/LEDBackpack/CloudVaultViews.swift#L5) | Current-source refreshed adaptive study |
| [CloudVaultPasswordView](design-atlas.html#47efd079-d855-4e6d-b98c-bd347ee63c81) | Account and preferences | [CloudVaultPasswordView](../../ios/LEDBackpack/CloudVaultViews.swift#L148) | Source-derived adaptive visual study |
| [CloudVaultArtworkRow](design-atlas.html#68971277-6ab2-43b2-ac10-c9b53299417a) | Shared components | [CloudVaultArtworkRow](../../ios/LEDBackpack/CloudVaultViews.swift#L198) | Source-derived adaptive visual study |
| [CloudVaultArtworkDetail](design-atlas.html#b644b0f8-18fb-4a92-a87a-6e4c068b8ae3) | Library and playback | [CloudVaultArtworkDetail](../../ios/LEDBackpack/CloudVaultViews.swift#L225) | Source-derived adaptive visual study |
| [CommunitySettingsView](design-atlas.html#0e9f84c4-8184-4904-8b99-0ca9adff05e6) | Account and preferences | [CommunitySettingsView](../../ios/LEDBackpack/CommunityAccounts.swift#L4) | Source-derived adaptive visual study |
| [CommunityAccountView](design-atlas.html#4cfed8d6-c6a7-4a7c-912c-a57c3608778f) | Account and preferences | [CommunityAccountView](../../ios/LEDBackpack/CommunityAccounts.swift#L45) | Source-derived adaptive visual study |
| [CommunityDeletionStatus](design-atlas.html#64cc73e9-47d1-4875-bc02-0a4ab40935ee) | Shared components | [CommunityDeletionStatus](../../ios/LEDBackpack/CommunityAccounts.swift#L227) | Source-derived adaptive visual study |
| [CommunityDeleteAccountView](design-atlas.html#b225ab55-09ca-4573-ae7d-e64b97575310) | Account and preferences | [CommunityDeleteAccountView](../../ios/LEDBackpack/CommunityAccounts.swift#L265) | Source-derived adaptive visual study |
| [CommunityAdminView](design-atlas.html#ffc7f151-6520-4f75-a57c-4c78ef6c0496) | Community and moderation | [CommunityAdminView](../../ios/LEDBackpack/CommunityAdminViews.swift#L5) | Source-derived adaptive visual study |
| [CommunityAdminItemEditor](design-atlas.html#e3f8647a-2b3f-4ca7-94be-391135d988d4) | Community and moderation | [CommunityAdminItemEditor](../../ios/LEDBackpack/CommunityAdminViews.swift#L350) | Source-derived adaptive visual study |
| [CommunityBlocksView](design-atlas.html#96430b6e-08ad-46d0-ad4b-064f2c6b40e7) | Recovery and safety | [CommunityBlocksView](../../ios/LEDBackpack/CommunityBlocks.swift#L37) | Source-derived adaptive visual study |
| [CommunityBulkModerationView](design-atlas.html#74a0b570-6117-456b-bec1-982b75f29c55) | Community and moderation | [CommunityBulkModerationView](../../ios/LEDBackpack/CommunityBulkModeration.swift#L61) | Source-derived adaptive visual study |
| [CommunityMessageRequestsView](design-atlas.html#ececf4b6-865b-4f16-bb7f-c0b2554db176) | Messaging | [CommunityMessageRequestsView](../../ios/LEDBackpack/CommunityChatRequests.swift#L139) | Source-derived adaptive visual study |
| [CommunityMessagesView](design-atlas.html#eb78d868-793a-44a5-9016-4bb054421f4d) | Messaging | [CommunityMessagesView](../../ios/LEDBackpack/CommunityChatViews.swift#L12) | Current-source refreshed adaptive study |
| [CommunityConversationView](design-atlas.html#880b5147-17e9-45de-a18e-8da463d1216b) | Messaging | [CommunityConversationView](../../ios/LEDBackpack/CommunityChatViews.swift#L136) | Current-source refreshed adaptive study |
| [PrivateChatImage](design-atlas.html#4dcd6bd5-aa9f-4861-928c-9454ee91ecfa) | Shared components | [PrivateChatImage](../../ios/LEDBackpack/CommunityChatViews.swift#L487) | Source-derived adaptive visual study |
| [NativeChatBubble](design-atlas.html#d435ae32-22f7-4219-8bee-c3c5a417acf6) | Shared components | [NativeChatBubble](../../ios/LEDBackpack/CommunityChatViews.swift#L508) | Source-derived adaptive visual study |
| [EventInvitationDeadlineView](design-atlas.html#f108b268-4997-4354-96a4-eef2c313c605) | Events and routes | [EventInvitationDeadlineView](../../ios/LEDBackpack/CommunityEventViews.swift#L10) | Source-derived adaptive visual study |
| [CommunityEventsView](design-atlas.html#f7a26a29-adf5-4327-a55e-81aa69adf254) | Events and routes | [CommunityEventsView](../../ios/LEDBackpack/CommunityEventViews.swift#L23) | Source-derived adaptive visual study |
| [EventCountdownView](design-atlas.html#926e47ae-3e48-4834-9a9e-35d89637f344) | Events and routes | [EventCountdownView](../../ios/LEDBackpack/CommunityEventViews.swift#L123) | Source-derived adaptive visual study |
| [CommunityEventDetailView](design-atlas.html#3cc62357-d090-4fde-b01f-3fd7eac39188) | Events and routes | [CommunityEventDetailView](../../ios/LEDBackpack/CommunityEventViews.swift#L142) | Source-derived adaptive visual study |
| [CommunityEventEditor](design-atlas.html#46aaaa7e-bdae-46a0-b5af-33aaf70c6600) | Events and routes | [CommunityEventEditor](../../ios/LEDBackpack/CommunityEventViews.swift#L466) | Source-derived adaptive visual study |
| [CommunityFavoritesView](design-atlas.html#d174fee4-0230-434c-85da-6406b46f58f8) | Community and moderation | [CommunityFavoritesView](../../ios/LEDBackpack/CommunityFavoritesView.swift#L5) | Source-derived adaptive visual study |
| [CommunityGallery](design-atlas.html#4af0d439-b1fd-4070-800a-dfe0a82e9895) | Community and moderation | [CommunityGallery](../../ios/LEDBackpack/CommunityGallery.swift#L11) | Source-derived adaptive visual study |
| [CommunityDetail](design-atlas.html#9286e1bc-5235-4ff7-b013-9991435c7e19) | Community and moderation | [CommunityDetail](../../ios/LEDBackpack/CommunityGallery.swift#L161) | Source-derived adaptive visual study |
| [NativeGroupCreateView](design-atlas.html#4dfcef35-e7ca-4512-834b-c1240efea842) | Messaging | [NativeGroupCreateView](../../ios/LEDBackpack/CommunityGroupViews.swift#L5) | Source-derived adaptive visual study |
| [NativeRoomInfoView](design-atlas.html#711e159d-a1cf-49d6-8410-6e13a954fa8f) | Messaging | [NativeRoomInfoView](../../ios/LEDBackpack/CommunityGroupViews.swift#L59) | Source-derived adaptive visual study |
| [CommunityNotificationSettingsView](design-atlas.html#24128c23-c420-426f-8373-a359f0fa37c8) | Account and preferences | [CommunityNotificationSettingsView](../../ios/LEDBackpack/CommunityNotificationViews.swift#L4) | Source-derived adaptive visual study |
| [CommunityActivityView](design-atlas.html#5ae143bb-9b27-400f-a1c5-74886c7aff01) | Community and moderation | [CommunityActivityView](../../ios/LEDBackpack/CommunityNotificationViews.swift#L67) | Source-derived adaptive visual study |
| [CommunitySelectionControls](design-atlas.html#999f2767-07d7-4c3b-8cfb-163b4812884a) | Shared components | [CommunitySelectionControls](../../ios/LEDBackpack/CommunitySelectionControls.swift#L4) | Source-derived adaptive visual study |
| [CommunitySocialView](design-atlas.html#3bb04ed3-ed34-4203-9939-eb1dfd3edaf0) | Community and moderation | [CommunitySocialView](../../ios/LEDBackpack/CommunitySocialViews.swift#L6) | Source-derived adaptive visual study |
| [CommunityProfileAvatar](design-atlas.html#0a07debc-a861-418b-a91a-56ee580b6bb8) | Shared components | [CommunityProfileAvatar](../../ios/LEDBackpack/CommunitySocialViews.swift#L188) | Source-derived adaptive visual study |
| [CommunityAvatarView](design-atlas.html#7e587304-5e5a-49dc-8bb6-95fc6fab27ca) | Community and moderation | [CommunityAvatarView](../../ios/LEDBackpack/CommunitySocialViews.swift#L213) | Source-derived adaptive visual study |
| [CommunityUploadView](design-atlas.html#8300694d-8370-447e-a7d6-45f3b2d83d3f) | Community and moderation | [CommunityUploadView](../../ios/LEDBackpack/CommunityUpload.swift#L112) | Source-derived adaptive visual study |
| [CommunityUploadsView](design-atlas.html#3a7d0b4c-09be-4a2d-a820-5d23e5c428c2) | Community and moderation | [CommunityUploadsView](../../ios/LEDBackpack/CommunityUpload.swift#L199) | Source-derived adaptive visual study |
| [CommunityUploadAlertsView](design-atlas.html#4366cc03-2847-4136-9271-2e916ec094a8) | Community and moderation | [CommunityUploadAlertsView](../../ios/LEDBackpack/CommunityUploadAlerts.swift#L34) | Source-derived adaptive visual study |
| [ConversationNotificationView](design-atlas.html#5c3dbf02-7a82-474e-86b8-01504a1c581c) | Messaging | [ConversationNotificationView](../../ios/LEDBackpack/ConversationNotifications.swift#L56) | Source-derived adaptive visual study |
| [CreateView](design-atlas.html#69587c09-4346-44f9-92a7-230f42d0788e) | Creation and editing | [CreateView](../../ios/LEDBackpack/CreateView.swift#L4) | Current-source refreshed adaptive study |
| [AuroraBackground](design-atlas.html#2a119b74-b5b2-4f2e-9704-4a806b70a260) | Shared components | [AuroraBackground](../../ios/LEDBackpack/DesignSystem.swift#L11) | Source-derived adaptive visual study |
| [AuroraSurface](design-atlas.html#e1b143ea-29c2-45a5-af6a-89657b8aded7) | Shared components | [AuroraSurface](../../ios/LEDBackpack/DesignSystem.swift#L30) | Source-derived adaptive visual study |
| [AuroraHeading](design-atlas.html#deb7a4cf-b66d-407d-9cc5-924a03644830) | Shared components | [AuroraHeading](../../ios/LEDBackpack/DesignSystem.swift#L67) | Source-derived adaptive visual study |
| [FeatureCardLabel](design-atlas.html#08283e82-5b99-4fea-a92f-144f0cbdd5a7) | Shared components | [FeatureCardLabel](../../ios/LEDBackpack/DesignSystem.swift#L100) | Source-derived adaptive visual study |
| [FeatureRowLabel](design-atlas.html#4de80aa6-fbaa-49bc-b281-a2ced6acf9f0) | Shared components | [FeatureRowLabel](../../ios/LEDBackpack/DesignSystem.swift#L130) | Source-derived adaptive visual study |
| [FeatureDetails](design-atlas.html#19bb3cc0-40e3-44d6-b830-562ae4816b71) | Shared components | [FeatureDetails](../../ios/LEDBackpack/DesignSystem.swift#L149) | Source-derived adaptive visual study |
| [StatusPill](design-atlas.html#26b1739d-d597-45b6-b575-4e3440a4431b) | Shared components | [StatusPill](../../ios/LEDBackpack/DesignSystem.swift#L167) | Source-derived adaptive visual study |
| [PixelArtwork](design-atlas.html#04223bdc-8c87-4413-b716-e9f55e9f57cb) | Shared components | [PixelArtwork](../../ios/LEDBackpack/DesignSystem.swift#L180) | Source-derived adaptive visual study |
| [BackpackHero](design-atlas.html#ffa0bb76-8555-4bb1-a18f-34ccdbed32aa) | Shared components | [BackpackHero](../../ios/LEDBackpack/DesignSystem.swift#L200) | Source-derived adaptive visual study |
| [EventAwardListView](design-atlas.html#75932f67-8ef9-4401-ab7e-5e9db631a4bb) | Events and routes | [EventAwardListView](../../ios/LEDBackpack/EventAwardViews.swift#L5) | Source-derived adaptive visual study |
| [EventAwardCollectionView](design-atlas.html#a91e0879-d270-493d-97eb-ef21ab0d1a09) | Events and routes | [EventAwardCollectionView](../../ios/LEDBackpack/EventAwardViews.swift#L115) | Source-derived adaptive visual study |
| [AuthorizedProfileEventBadges](design-atlas.html#077cf79c-569e-4475-94b1-b8ec67665236) | Shared components | [AuthorizedProfileEventBadges](../../ios/LEDBackpack/EventAwardViews.swift#L191) | Source-derived adaptive visual study |
| [EventCreationNextSteps](design-atlas.html#018883ef-9ce4-4803-a663-b1f5e6ae6384) | Shared components | [EventCreationNextSteps](../../ios/LEDBackpack/EventCreationSteps.swift#L19) | Source-derived adaptive visual study |
| [EventGPSHuntView](design-atlas.html#ef7809a5-f7de-4dde-bac3-88ac52771161) | Events and routes | [EventGPSHuntView](../../ios/LEDBackpack/EventGPSHuntView.swift#L5) | Source-derived adaptive visual study |
| [EventGPSHuntContent](design-atlas.html#8d26400b-f71c-42b8-84e7-30fd5ec8cd3f) | Events and routes | [EventGPSHuntContent](../../ios/LEDBackpack/EventGPSHuntView.swift#L15) | Source-derived adaptive visual study |
| [EventGalleryView](design-atlas.html#717bb151-cb37-4d4c-b2c2-6dfc4baa3231) | Events and routes | [EventGalleryView](../../ios/LEDBackpack/EventGalleryViews.swift#L5) | Source-derived adaptive visual study |
| [EventGalleryContent](design-atlas.html#a0de6aea-bdfe-42ee-aa9b-5c21f1068ffe) | Events and routes | [EventGalleryContent](../../ios/LEDBackpack/EventGalleryViews.swift#L13) | Source-derived adaptive visual study |
| [EventAuthorizedCoverView](design-atlas.html#948b624b-9694-47a5-bf0d-a116b4046e6c) | Events and routes | [EventAuthorizedCoverView](../../ios/LEDBackpack/EventGalleryViews.swift#L169) | Source-derived adaptive visual study |
| [EventOwnerToolsView](design-atlas.html#39c6589a-1fc1-4699-a3b5-82c9537d308b) | Events and routes | [EventOwnerToolsView](../../ios/LEDBackpack/EventGovernanceViews.swift#L5) | Source-derived adaptive visual study |
| [EventReportComposerView](design-atlas.html#47aa7ef1-ac6f-418b-a8c0-696a3d467edb) | Events and routes | [EventReportComposerView](../../ios/LEDBackpack/EventGovernanceViews.swift#L161) | Source-derived adaptive visual study |
| [OwnEventReportsView](design-atlas.html#4fb2cff6-9067-496f-b4f6-e853bec04ecc) | Events and routes | [OwnEventReportsView](../../ios/LEDBackpack/EventGovernanceViews.swift#L218) | Source-derived adaptive visual study |
| [EventModerationView](design-atlas.html#2b29767c-5501-4079-a5f9-5db260b59582) | Events and routes | [EventModerationView](../../ios/LEDBackpack/EventGovernanceViews.swift#L280) | Source-derived adaptive visual study |
| [EventImageReplacementView](design-atlas.html#bdb0689c-a9cc-4251-85e2-5eab697679b4) | Events and routes | [EventImageReplacementView](../../ios/LEDBackpack/EventImageReplacement.swift#L128) | Source-derived adaptive visual study |
| [EventProgressView](design-atlas.html#a1f92d23-af01-46b0-b389-03e07de7746b) | Events and routes | [EventProgressView](../../ios/LEDBackpack/EventProgressView.swift#L5) | Source-derived adaptive visual study |
| [EventRosterView](design-atlas.html#6c69c5f2-8b2b-409a-9a25-3ccc3eae379e) | Events and routes | [EventRosterView](../../ios/LEDBackpack/EventRosterView.swift#L5) | Source-derived adaptive visual study |
| [EventRoutePlannerView](design-atlas.html#4e6e23f3-7a9a-4613-9f3f-7953ecb902b9) | Events and routes | [EventRoutePlannerView](../../ios/LEDBackpack/EventRoutePlannerView.swift#L18) | Source-derived adaptive visual study |
| [EventRoutePlannerContent](design-atlas.html#8cc187b9-b085-4da8-b497-3c3e059b03a4) | Events and routes | [EventRoutePlannerContent](../../ios/LEDBackpack/EventRoutePlannerView.swift#L26) | Source-derived adaptive visual study |
| [EventDefinitionReviewView](design-atlas.html#b3038a0d-7930-433b-ac72-ef72ac3d5fdc) | Events and routes | [EventDefinitionReviewView](../../ios/LEDBackpack/EventSaveReview.swift#L67) | Source-derived adaptive visual study |
| [EventRouteReviewView](design-atlas.html#a5bdd745-e1ca-4918-af3d-8d3def95c991) | Events and routes | [EventRouteReviewView](../../ios/LEDBackpack/EventSaveReview.swift#L108) | Source-derived adaptive visual study |
| [EventSocialView](design-atlas.html#672ce90d-b842-451a-883a-0c03197ed9c2) | Events and routes | [EventSocialView](../../ios/LEDBackpack/EventSocialViews.swift#L254) | Source-derived adaptive visual study |
| [GentleColorsEditor](design-atlas.html#cc03da2b-d5d2-4e1e-b4e1-e9264fa3b69b) | Creation and editing | [GentleColorsEditor](../../ios/LEDBackpack/EventSocialViews.swift#L630) | Source-derived adaptive visual study |
| [NativeDisplaySceneEditor](design-atlas.html#9c5d3e89-8c55-4ca9-8d34-6ca6b3d6f261) | Creation and editing | [NativeDisplaySceneEditor](../../ios/LEDBackpack/EventSocialViews.swift#L650) | Source-derived adaptive visual study |
| [OwnedGuestbookPostsView](design-atlas.html#62d06362-4de1-419f-bb8a-ebf04e016489) | Community and moderation | [OwnedGuestbookPostsView](../../ios/LEDBackpack/EventSocialViews.swift#L678) | Source-derived adaptive visual study |
| [FirmwareOTAInspectionView](design-atlas.html#e4021ecb-8802-4727-80c1-9b92e01a7acf) | Backpack and hardware | Archived mapping: FirmwareOTAInspectionView | Retained legacy import |
| [FriendArtworkPreview](design-atlas.html#99b8ad53-d0ee-4748-9b22-31c9897a81eb) | Shared components | [FriendArtworkPreview](../../ios/LEDBackpack/FriendArtworkSelection.swift#L99) | Source-derived adaptive visual study |
| [FriendArtworkPicker](design-atlas.html#f432c32e-57e7-475c-9dca-1792a74225d8) | Live and nearby | [FriendArtworkPicker](../../ios/LEDBackpack/FriendArtworkSelection.swift#L134) | Source-derived adaptive visual study |
| [FriendInviteCamera](design-atlas.html#58b34069-1648-4be4-967b-e1067a80e845) | Live and nearby | [FriendInviteCamera](../../ios/LEDBackpack/FriendInviteCamera.swift#L58) | Source-derived adaptive visual study |
| [FriendInviteQRView](design-atlas.html#f032bff0-0dc3-448b-8976-84e4e3b24481) | Live and nearby | [FriendInviteQRView](../../ios/LEDBackpack/FriendInviteQR.swift#L90) | Current-source refreshed adaptive study |
| [FriendPlaybackView](design-atlas.html#c56fced3-f08f-40b3-8f59-75ec1004ccbe) | Live and nearby | [FriendPlaybackView](../../ios/LEDBackpack/FriendPlaybackViews.swift#L64) | Source-derived adaptive visual study |
| [FriendArmButton](design-atlas.html#95a69f44-e616-4a21-83af-e833b71d870b) | Shared components | [FriendArmButton](../../ios/LEDBackpack/FriendPlaybackViews.swift#L171) | Source-derived adaptive visual study |
| [FriendPlaybackStatus](design-atlas.html#19f5dc8e-b6cc-416b-9ae6-258cbb43c86f) | Shared components | [FriendPlaybackStatus](../../ios/LEDBackpack/FriendPlaybackViews.swift#L182) | Source-derived adaptive visual study |
| [FriendRadioReadiness](design-atlas.html#27a62eef-6163-4d5d-807b-3af670b8bf35) | Shared components | [FriendRadioReadiness](../../ios/LEDBackpack/FriendPlaybackViews.swift#L194) | Source-derived adaptive visual study |
| [FriendPhoneCanvasControls](design-atlas.html#15e69776-738d-4682-ba05-e0270e03397c) | Shared components | [FriendPhoneCanvasControls](../../ios/LEDBackpack/FriendPlaybackViews.swift#L199) | Source-derived adaptive visual study |
| [GIFGallery](design-atlas.html#21886e31-097e-47c7-b204-a4ccbd35a108) | Library and playback | [GIFGallery](../../ios/LEDBackpack/GIFCatalog.swift#L105) | Source-derived adaptive visual study |
| [GIFDetails](design-atlas.html#0a579d31-4937-484d-858e-2ef1d3bb6170) | Library and playback | [GIFDetails](../../ios/LEDBackpack/GIFCatalog.swift#L203) | Source-derived adaptive visual study |
| [MediaEditor](design-atlas.html#251f412c-f3d5-4e60-abaf-beb5e0211b18) | Creation and editing | [MediaEditor](../../ios/LEDBackpack/GIFEditor.swift#L5) | Current-source refreshed adaptive study |
| [GIFPreviewImage](design-atlas.html#df579b43-ba80-46d2-8a71-864384888419) | Shared components | [GIFPreviewImage](../../ios/LEDBackpack/GIFPreviews.swift#L140) | Source-derived adaptive visual study |
| [GIFThumbnail](design-atlas.html#de41b866-e134-480b-8e4f-060f406e53ea) | Shared components | [GIFThumbnail](../../ios/LEDBackpack/GIFPreviews.swift#L171) | Source-derived adaptive visual study |
| [GIFTimingControls](design-atlas.html#f060246e-49af-4574-b74e-af37e49146e4) | Shared components | [GIFTimingControls](../../ios/LEDBackpack/GIFTimingViews.swift#L8) | Source-derived adaptive visual study |
| [GIFTimingEditorView](design-atlas.html#19389cc0-6569-4e03-b9fb-3de0232e2898) | Creation and editing | [GIFTimingEditorView](../../ios/LEDBackpack/GIFTimingViews.swift#L43) | Source-derived adaptive visual study |
| [GPSGamesView](design-atlas.html#a4dd3997-0810-4bef-9dac-557bfb6a70be) | Live and nearby | [GPSGamesView](../../ios/LEDBackpack/GPSGamesView.swift#L4) | Source-derived adaptive visual study |
| [LEDAlphabetView](design-atlas.html#d2b5bf78-9f17-4b75-8e0a-4217c35d03ad) | Creation and editing | [LEDAlphabetView](../../ios/LEDBackpack/LEDAlphabetView.swift#L5) | Source-derived adaptive visual study |
| [FeatureActionIsolationFixture](design-atlas.html#ddf81fab-b61b-440c-9f48-c1c84015f418) | Development fixtures | [FeatureActionIsolationFixture](../../ios/LEDBackpack/LibraryPreviewFixture.swift#L7) | Source-derived adaptive visual study |
| [LocalPairedGameView](design-atlas.html#964a113b-e582-4052-a1f0-75c53ae8c654) | Live and nearby | [LocalPairedGameView](../../ios/LEDBackpack/LocalPairedGameView.swift#L6) | Source-derived adaptive visual study |
| [LocalPairStartControls](design-atlas.html#616daf9b-dfa3-46e6-ae3d-63a07abc9c87) | Shared components | [LocalPairStartControls](../../ios/LEDBackpack/LocalPairedGameView.swift#L103) | Source-derived adaptive visual study |
| [LocalRangeStatus](design-atlas.html#313990ff-ab7b-4454-a9a3-0cac8854a7c0) | Shared components | [LocalRangeStatus](../../ios/LEDBackpack/LocalPairedGameView.swift#L130) | Source-derived adaptive visual study |
| [LocalPixelCanvas](design-atlas.html#d16ad316-ff7c-4c1c-961a-b3c76afc3386) | Shared components | [LocalPixelCanvas](../../ios/LEDBackpack/LocalPixelPreview.swift#L45) | Source-derived adaptive visual study |
| [LocalPixelStudioView](design-atlas.html#11a11eb1-a642-4cdc-b7ed-a0f8aa20b321) | Creation and editing | [LocalPixelStudioView](../../ios/LEDBackpack/LocalPixelStudioView.swift#L6) | Source-derived adaptive visual study |
| [FriendLocationFeaturesView](design-atlas.html#9ddcffa3-0bcd-400e-b44f-66fbaafb0da4) | Live and nearby | [FriendLocationFeaturesView](../../ios/LEDBackpack/LocationFeatureViews.swift#L5) | Source-derived adaptive visual study |
| [EventLocalEligibilityView](design-atlas.html#01a3f56c-d26b-4030-83db-b4427ce6051e) | Events and routes | [EventLocalEligibilityView](../../ios/LEDBackpack/LocationFeatureViews.swift#L200) | Source-derived adaptive visual study |
| [LibraryMediaRow](design-atlas.html#9ab68ea6-6386-4987-9dc9-32335aff1671) | Shared components | [LibraryMediaRow](../../ios/LEDBackpack/MediaLibraryViews.swift#L4) | Source-derived adaptive visual study |
| [MediaOrganizer](design-atlas.html#92dc52dd-aa78-4b45-9649-12ca088eaf54) | Events and routes | [MediaOrganizer](../../ios/LEDBackpack/MediaLibraryViews.swift#L45) | Source-derived adaptive visual study |
| [MessageIncidentComposeView](design-atlas.html#529bfdcc-7a85-4925-bc77-0a01eae7a427) | Recovery and safety | [MessageIncidentComposeView](../../ios/LEDBackpack/MessageIncidentReports.swift#L105) | Current-source refreshed adaptive study |
| [MessageIncidentListView](design-atlas.html#8d88afb1-89b4-4713-a40b-cce33bffba0e) | Recovery and safety | [MessageIncidentListView](../../ios/LEDBackpack/MessageIncidentReports.swift#L141) | Source-derived adaptive visual study |
| [NativeApplePushView](design-atlas.html#b343f4fe-fdcb-4216-ab5d-03dd402b358a) | Library and playback | [NativeApplePushView](../../ios/LEDBackpack/NativeApplePush.swift#L209) | Source-derived adaptive visual study |
| [NativePushDestinationView](design-atlas.html#4261279a-d23f-48e2-8370-a5d1daadf070) | Library and playback | [NativePushDestinationView](../../ios/LEDBackpack/NativeApplePush.swift#L249) | Source-derived adaptive visual study |
| [NativeMatrixFilterControls](design-atlas.html#1f375755-6f22-4ee4-86df-e7d8571a3722) | Shared components | [NativeMatrixFilterControls](../../ios/LEDBackpack/NativeCatalogSizes.swift#L31) | Source-derived adaptive visual study |
| [CatalogContributorAvatar](design-atlas.html#97481ec0-c1e9-4b2c-b881-f69dbfe00ee6) | Shared components | [CatalogContributorAvatar](../../ios/LEDBackpack/NativeCatalogSizes.swift#L172) | Source-derived adaptive visual study |
| [NativeIntegrityRecoveryView](design-atlas.html#b868f4e7-5142-4ef4-8851-16b3b1879bbd) | Recovery and safety | [NativeIntegrityRecoveryView](../../ios/LEDBackpack/NativeIntegrityRecovery.swift#L25) | Source-derived adaptive visual study |
| [NearbyDiscoveryView](design-atlas.html#7324c4f8-2a9d-42e7-8dbe-7edc0d3112cc) | Live and nearby | [NearbyDiscoveryView](../../ios/LEDBackpack/NearbyDiscovery.swift#L208) | Source-derived adaptive visual study |
| [NearbyStartControls](design-atlas.html#0ca8b7f1-7341-4a35-8414-586fa10b6564) | Shared components | [NearbyStartControls](../../ios/LEDBackpack/NearbyDiscovery.swift#L328) | Source-derived adaptive visual study |
| [NearbyRadioStatus](design-atlas.html#7fb79a83-5aa1-4cc8-a0a3-c7c4ab5ab269) | Shared components | [NearbyRadioStatus](../../ios/LEDBackpack/NearbyDiscovery.swift#L346) | Source-derived adaptive visual study |
| [OrganizerMap](design-atlas.html#36b7f1d1-a8fe-4d1a-8e13-e2e139824264) | Shared components | [OrganizerMap](../../ios/LEDBackpack/OrganizerMap.swift#L13) | Source-derived adaptive visual study |
| [OrganizerPlaceSearchView](design-atlas.html#8fe02838-10ed-42e9-a432-65c3282ec33c) | Events and routes | [OrganizerPlaceSearchView](../../ios/LEDBackpack/OrganizerMap.swift#L203) | Source-derived adaptive visual study |
| [FixedVenueMapEditor](design-atlas.html#975e7cc5-90b7-42aa-9fc1-ab345ab71e2b) | Events and routes | [FixedVenueMapEditor](../../ios/LEDBackpack/OrganizerMap.swift#L224) | Source-derived adaptive visual study |
| [FixedEventPlanPreview](design-atlas.html#439dd5d1-bdf0-49cb-b65c-3c4af6c7bb7b) | Events and routes | [FixedEventPlanPreview](../../ios/LEDBackpack/OrganizerMap.swift#L315) | Source-derived adaptive visual study |
| [OwnerPlaylistsView](design-atlas.html#dc04dae6-13e3-4d85-8a3a-3368b4a0684d) | Library and playback | [OwnerPlaylistsView](../../ios/LEDBackpack/OwnerPlaylistViews.swift#L157) | Source-derived adaptive visual study |
| [OwnerPlaylistEditor](design-atlas.html#41370e50-cad2-4cbd-9797-f631ddbef323) | Creation and editing | [OwnerPlaylistEditor](../../ios/LEDBackpack/OwnerPlaylistViews.swift#L202) | Source-derived adaptive visual study |
| [NativePlaylistShareQRView](design-atlas.html#de16f2d1-a15d-44f2-ac39-5ee2c4288df9) | Library and playback | [NativePlaylistShareQRView](../../ios/LEDBackpack/OwnerPlaylistViews.swift#L371) | Source-derived adaptive visual study |
| [PeerIncidentAdminView](design-atlas.html#ce9f51f7-8386-496a-bffd-ccfd3e5ddc6f) | Recovery and safety | [PeerIncidentAdminView](../../ios/LEDBackpack/PeerIncidentAdminView.swift#L5) | Source-derived adaptive visual study |
| [PeerIncidentComposeView](design-atlas.html#3d3ef789-9822-43dd-aec6-6faf3e158351) | Recovery and safety | [PeerIncidentComposeView](../../ios/LEDBackpack/PeerIncidentViews.swift#L5) | Source-derived adaptive visual study |
| [PeerIncidentOwnerView](design-atlas.html#0e28c53f-8abd-47a0-a06a-46678dcd74a5) | Recovery and safety | [PeerIncidentOwnerView](../../ios/LEDBackpack/PeerIncidentViews.swift#L95) | Source-derived adaptive visual study |
| [PhoneDisplayLibraryView](design-atlas.html#38aa6fa2-4df0-419b-b904-2006b2de0092) | Library and playback | [PhoneDisplayLibraryView](../../ios/LEDBackpack/PhoneDisplayViews.swift#L6) | Source-derived adaptive visual study |
| [PhoneDisplayView](design-atlas.html#666286d2-aea0-4bb1-b16a-c66f1193fc6c) | Library and playback | [PhoneDisplayView](../../ios/LEDBackpack/PhoneDisplayViews.swift#L100) | Source-derived adaptive visual study |
| [PhonePixelGrid](design-atlas.html#c19d09de-e21a-4e66-a1f9-51e13ddab118) | Shared components | [PhonePixelGrid](../../ios/LEDBackpack/PhoneDisplayViews.swift#L249) | Source-derived adaptive visual study |
| [PhoneSwapGameView](design-atlas.html#4bec2226-554a-40b4-994d-f05aec309670) | Live and nearby | [PhoneSwapGameView](../../ios/LEDBackpack/PhoneSwapGameView.swift#L4) | Source-derived adaptive visual study |
| [GameRadioIndicator](design-atlas.html#b31812f8-a264-48b5-b34f-d125b0e0738f) | Shared components | [GameRadioIndicator](../../ios/LEDBackpack/PhoneSwapGameView.swift#L159) | Source-derived adaptive visual study |
| [PixelAnimationStudio](design-atlas.html#5b96070c-5460-43af-a7eb-5a9d7ddb9918) | Creation and editing | [PixelAnimationStudio](../../ios/LEDBackpack/PixelAnimationStudio.swift#L5) | Source-derived adaptive visual study |
| [DrawingFrameThumbnail](design-atlas.html#b5379ffa-7a3e-4f54-858e-4e590281b018) | Shared components | [DrawingFrameThumbnail](../../ios/LEDBackpack/PixelAnimationStudio.swift#L179) | Source-derived adaptive visual study |
| [BackpackMonitor](design-atlas.html#f9cbb01f-b5f4-4bcd-b34c-9d653fc2f0b6) | Backpack and hardware | [BackpackMonitor](../../ios/LEDBackpack/PlaybackViews.swift#L4) | Source-derived adaptive visual study |
| [PlaylistCollection](design-atlas.html#fc3be094-80d8-4c52-8673-a7fa882fde31) | Library and playback | [PlaylistCollection](../../ios/LEDBackpack/PlaylistCollection.swift#L5) | Source-derived adaptive visual study |
| [PlaylistEditor](design-atlas.html#c7717add-fffa-4a9c-8926-1919a95aeff6) | Creation and editing | [PlaylistEditor](../../ios/LEDBackpack/PlaylistCollection.swift#L60) | Source-derived adaptive visual study |
| [NativeChatPlaylistCard](design-atlas.html#959321fa-bd17-4de5-a028-9a3341443259) | Shared components | [NativeChatPlaylistCard](../../ios/LEDBackpack/PublishedPlaylistChat.swift#L94) | Source-derived adaptive visual study |
| [NativeChatPlaylistViewer](design-atlas.html#188caf58-ca19-4182-9720-820622b80739) | Messaging | [NativeChatPlaylistViewer](../../ios/LEDBackpack/PublishedPlaylistChat.swift#L112) | Source-derived adaptive visual study |
| [RouteArtworkPicker](design-atlas.html#26374607-9570-477d-b424-e205bd2b38c5) | Events and routes | [RouteArtworkPicker](../../ios/LEDBackpack/RouteArtworkPicker.swift#L5) | Source-derived adaptive visual study |
| [QuickScenes](design-atlas.html#23998466-8b18-4345-a41c-801d4bf2cdfb) | Shared components | [QuickScenes](../../ios/LEDBackpack/Scenes.swift#L53) | Source-derived adaptive visual study |
| [SceneLaunchRow](design-atlas.html#e7805f5a-0864-43bf-8e4b-d59ca3e26d4c) | Shared components | [SceneLaunchRow](../../ios/LEDBackpack/Scenes.swift#L70) | Source-derived adaptive visual study |
| [ScenesView](design-atlas.html#ba8dc166-09cd-4868-866c-610d7b91e7e3) | Library and playback | [ScenesView](../../ios/LEDBackpack/Scenes.swift#L96) | Source-derived adaptive visual study |
| [SceneEditor](design-atlas.html#153b7340-404b-4585-9f6d-a2af4300f879) | Creation and editing | [SceneEditor](../../ios/LEDBackpack/Scenes.swift#L134) | Source-derived adaptive visual study |
| [ScopedGlobalPhoneConsent](design-atlas.html#946f6716-0826-42ba-995b-2cb7cbad63a7) | Library and playback | [ScopedGlobalPhoneConsent](../../ios/LEDBackpack/ScopedGlobalPhone.swift#L112) | Source-derived adaptive visual study |
| [NativeScopedPhonePreviewView](design-atlas.html#9dc6f37c-e18b-4d4e-b20f-9052de805cc4) | Library and playback | [NativeScopedPhonePreviewView](../../ios/LEDBackpack/ScopedPhonePreview.swift#L342) | Source-derived adaptive visual study |
| [NativeScopedPhoneCanvas](design-atlas.html#2bb1d027-5108-400e-83be-fb95c68371dc) | Shared components | [NativeScopedPhoneCanvas](../../ios/LEDBackpack/ScopedPhonePreview.swift#L416) | Source-derived adaptive visual study |
| [SocialTabView](design-atlas.html#9fd27ac9-a567-4997-ba3f-8090225449a2) | Community and moderation | [SocialTabView](../../ios/LEDBackpack/SocialTabView.swift#L104) | Source-derived adaptive visual study |
| [SocialLink](design-atlas.html#2c8be92a-0ddb-446d-8ad7-6b7bebd406eb) | Shared components | [SocialLink](../../ios/LEDBackpack/SocialTabView.swift#L254) | Source-derived adaptive visual study |
| [SoloScenesView](design-atlas.html#63815107-e8dd-4a9b-bb5d-29fc1c030d63) | Live and nearby | [SoloScenesView](../../ios/LEDBackpack/SoloSceneViews.swift#L6) | Source-derived adaptive visual study |
| [SoloSceneComposer](design-atlas.html#1c339626-65c1-4bc5-a1fc-be72c0242984) | Live and nearby | [SoloSceneComposer](../../ios/LEDBackpack/SoloSceneViews.swift#L287) | Source-derived adaptive visual study |
| [SoloAreaEditor](design-atlas.html#8d91983f-eb83-405c-bd9f-17361df62ae8) | Live and nearby | [SoloAreaEditor](../../ios/LEDBackpack/SoloSceneViews.swift#L375) | Source-derived adaptive visual study |
| [SoloDaylightEditor](design-atlas.html#2b40b99a-eb17-4ca6-86a8-0685ab3cf42a) | Live and nearby | [SoloDaylightEditor](../../ios/LEDBackpack/SoloSceneViews.swift#L506) | Source-derived adaptive visual study |
| [LiveView](design-atlas.html#8b2fc823-69d7-4a87-b522-aefca5c49027) | Live and nearby | [LiveView](../../ios/LEDBackpack/StudioAndSettings.swift#L7) | Current-source refreshed adaptive study |
| [SettingsView](design-atlas.html#b89cb40e-065f-4df3-8812-b7112acfe5b5) | Account and preferences | [SettingsView](../../ios/LEDBackpack/StudioAndSettings.swift#L185) | Source-derived adaptive visual study |
| [SwapRecoveryView](design-atlas.html#64bd2dd5-a0e7-4a9c-aaac-70ce668da146) | Recovery and safety | [SwapRecoveryView](../../ios/LEDBackpack/SwapRecoveryViews.swift#L135) | Source-derived adaptive visual study |
| [ReceivedSwapPreview](design-atlas.html#db5ed8ff-b5fe-434a-ae8e-4653ceb9f12b) | Shared components | [ReceivedSwapPreview](../../ios/LEDBackpack/SwapRecoveryViews.swift#L241) | Source-derived adaptive visual study |
| [ReceivedSwapPixels](design-atlas.html#a5f83846-2e81-4fd3-a080-9e5ae3e3f4fa) | Shared components | [ReceivedSwapPixels](../../ios/LEDBackpack/SwapRecoveryViews.swift#L267) | Source-derived adaptive visual study |
| [TextArtworkStudio](design-atlas.html#8fd6e9c1-d75d-4b2b-8f04-da467b1fdfb7) | Creation and editing | [TextArtworkStudio](../../ios/LEDBackpack/TextArtworkStudio.swift#L5) | Source-derived adaptive visual study |
| [ThemeEditor](design-atlas.html#7d3fbc30-72da-46f8-904d-8c8f330ec292) | Creation and editing | [ThemeEditor](../../ios/LEDBackpack/ThemeEditor.swift#L5) | Current-source refreshed adaptive study |
| [VideoGIFEditor](design-atlas.html#d75d2398-d8c6-4842-a33e-ef5babadc21d) | Creation and editing | [VideoGIFEditor](../../ios/LEDBackpack/VideoGIF.swift#L111) | Source-derived adaptive visual study |
| [AnimatedPreview](design-atlas.html#032286d7-b85c-4f1c-b5c4-a1f467910b38) | Shared components | [AnimatedPreview](../../ios/LEDBackpack/Views.swift#L24) | Source-derived adaptive visual study |
| [RootView](design-atlas.html#aa0c5516-9f78-4442-baf9-ac9544ec6e4e) | Library and playback | [RootView](../../ios/LEDBackpack/Views.swift#L49) | Source-derived adaptive visual study |
| [DeviceView](design-atlas.html#bd8c0827-1162-4902-8a63-78029f4114ae) | Backpack and hardware | [DeviceView](../../ios/LEDBackpack/Views.swift#L104) | Current-source refreshed adaptive study |
| [Connected backpack · adoption design](design-atlas.html#fieldwork-connected-backpack) | Backpack and hardware | [ConnectedBackpackPanel](../../ios/LEDBackpack/ConnectedBackpackView.swift#L5) | New source-informed state composition |
| [Recovery inbox · design](design-atlas.html#fieldwork-recovery-inbox) | Recovery and safety | [DeviceRecoveryInboxView](../../ios/LEDBackpack/DeviceRecoveryViews.swift#L5) | New source-informed state composition |
| [Recovery conversation · design](design-atlas.html#fieldwork-recovery-thread) | Recovery and safety | [DeviceRecoveryThreadView](../../ios/LEDBackpack/DeviceRecoveryViews.swift#L74) | New source-informed state composition |
| [Erase review fixture · design](design-atlas.html#fieldwork-erase-fixture) | Development fixtures | [BackpackEraseReviewFixture](../../ios/LEDBackpack/BackpackEraseReviewFixture.swift#L6) | New source-informed state composition |
