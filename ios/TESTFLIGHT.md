# Internal TestFlight setup

This prepares **LED Backpack**, bundle ID `com.errantactions.ledbackpack`,
version `0.1.0`, for internal testing. It does not create an Apple app record,
generate credentials, or upload anything by itself.

## Verified profile photo usability build 16 upload - 2026-11-10

Version **0.1.0 (16)** was signed, archived, exported and accepted by App Store
Connect in [run 42949552461](https://github.com/ErrantActions/-led-backpack/actions/runs/42949552461).
Source `d2fec3d` adds visible **Profile photo** entries in Account and at the top
of Social, Photos/Files choices without pre-consent, automatic scoped preview,
HEIC still preparation and a separate explicit public-profile upload action.
Existing screening, captured avatar version, account boundaries and original
GIF bytes are retained. No backend or signing-key change was needed.

Native code inputs match `ef2bb4e`, which compiled and passed all 13 selected
input/consent/crop tests in run 42944765831. That UI run reached upload but
asserted a nonexistent standalone status text. After correcting only the
grouped-label selector, the full Photos-to-upload and Account/Social discovery
walkthrough passed in run 42947459830; native captures reviewed.
The protected release ran build/sign/upload only, with normal approval and
successful temporary signing cleanup. No simulator suites were repeated.

The binary upload is verified. Apple processing/internal tester availability
is not yet verified because the App Store Connect browser session expired.
No real account avatar was changed during fixture validation.

## Verified performance build 15 upload - 2026-11-10

Version **0.1.0 (15)** was signed, archived, exported and accepted by App Store
Connect in [run 42921358818](https://github.com/ErrantActions/-led-backpack/actions/runs/42921358818).
Source `d996fe4` retains the exact native performance inputs verified at
`c3e57da`: app compilation and 61 selected unit tests, zero failures.
Normal protected-environment approval was used; no simulator suites ran
during release, and temporary signing assets were removed successfully.

The matching backend is live as isolated source `8134f44`, based on deployed
`52044b5` rather than the unrelated recovery-v2 branch. All six performance
flags are enabled. Existing account/data/key fingerprints, environment,
mounts, network identity and disabled capabilities were preserved. Registry v1
remains active; recovery-v2 flags are absent. Node24 build/80 selected Linux
checks, isolated runtime smoke and normal external HTTPS authenticated
inbox/library/media checks passed. The dedicated synthetic member was erased
and its generated credentials removed.

App Store Connect completed processing and lists build 15 as **Ready to Submit**
in internal group **Me**. This is not an external beta/App Store submission or
proof of installation, physical BLE/GPS/fold behavior or live provider acceptance.
Signing keys, backend keys, APNs/adoption/user-held/redraw settings are unchanged.

## Verified app-wide workflow build 14 upload - 2026-11-10

Version **0.1.0 (14)** was signed, archived, exported and accepted by App Store
Connect in [run 42900232408](https://github.com/ErrantActions/-led-backpack/actions/runs/42900232408).
Release source `2a6dea5` extends essentials-first workflows through library,
creation, playback, live/settings, account/cloud/social, games, event extras and
administration while retaining the invitation-first event core.

Native app inputs match `ca200ec`, which compiled and passed the app-wide and
editor/settings walkthroughs in
[run 42891341051](https://github.com/ErrantActions/-led-backpack/actions/runs/42891341051).
The remaining Live test had a stale selector; its corrected retry then hit a
simulator-runner bootstrap crash before tests started, not an app crash.
The owner explicitly requested another Live-only retry.
[Run 42896938342](https://github.com/ErrantActions/-led-backpack/actions/runs/42896938342)
passed that one scenario with zero failures and cleaned up its fresh simulator.
No native app inputs changed between these checks or the release.

The protected release used normal environment approval and build/sign/upload
only. Temporary signing assets were removed successfully. No simulator suites
ran during upload, no backend was deployed and no signing keys were changed.
Native screenshots were reviewed; full-suite, physical fold/orientation,
BLE/GPS and private-provider end-to-end acceptance are not certified.

App Store Connect showed build 14 as **Processing** after the accepted upload.
Internal tester availability is not yet verified.

## Verified event rework build 13 upload - 2026-11-10

Version **0.1.0 (13)** was signed, archived, exported and uploaded in
[run 42886758008](https://github.com/ErrantActions/-led-backpack/actions/runs/42886758008).
Release source `4f0312e` includes invitation-first event browsing/details,
essentials-first creation and persistent adaptive cancellation controls.
Its native inputs match source `65496af`, which passed focused compilation,
42 unit checks and one event UI walkthrough before this release.

The protected release ran build/sign/upload only, with normal environment
approval and successful temporary signing cleanup. No simulator suites were
repeated; signing keys and the backend were unchanged.

App Store Connect explicitly showed build 13 as **Processing** after upload.
Internal tester availability is not yet verified.

## Verified Aurora build 12 upload - 2026-11-10

Version **0.1.0 (12)** was signed, archived, exported and uploaded in
[run 42876610552](https://github.com/ErrantActions/-led-backpack/actions/runs/42876610552).
Release source `4d6fabc` includes the full native Aurora integration, motion,
artwork-only GIF surfaces, scoped confirmation toggles and Messenger-inspired
inbox/thread. Protected approval and temporary signing cleanup succeeded.
No backend deployment or signing-key change was needed.

The owner accepted incomplete simulator UI validation for this internal beta.
Native source `3fa17cb` compiled and ran 1,088 unit tests with 0 failures and
2 explicit skips. Its 16 UI tests had 2 failures: unsigned simulator Keychain entitlement (-34018)
and app termination. Full simulator, physical-device and authenticated live
messaging acceptance are not certified. Production Keychain remains fail-closed.

Fastlane skipped waiting for Apple processing. **Apple processing and internal
tester availability remain separate, unverified checkpoints.**

## Verified build10 upload - 2026-11-08

Version **0.1.0 build10** was signed, archived, exported and successfully uploaded
to App Store Connect in
[run42506053458](https://github.com/ErrantActions/-led-backpack/actions/runs/42506053458).
Release commit `1ef59c3` preserves the exact native inputs verified at `0772fd9`.
The exact-source Linux reuse gate, protected upload and temporary signing
asset/keychain/profile cleanup all passed. Existing signing assets and the
reviewed OS-provided-encryption declaration remain unchanged.

Frozen native source `0772fd9` passed
[run42502718422](https://github.com/ErrantActions/-led-backpack/actions/runs/42502718422):
app/test compilation, full native1011/0 with2 explicit skips, integrated UI7/0,
all18 synchronization fixtures and separate read-only public integration1/0.
The full GPS/nearby priority and consolidated fixture gates also passed.
The actual exported Library screenshots were reviewed before promotion.

This candidate adds the clean action-first UI, one automatically synchronized
owned GIF library, remote-edit/preview reconciliation and the verified post-build9
GPS/SOLO/paired-game fixes. Only reviewed committed source is promoted; dirty
firmware/bitmap/OTA/reserved-slot work and existing signing assets are unchanged.
Fastlane explicitly skipped waiting for Apple processing. Therefore build10's
**processing status and internal tester availability are not verified**.
Software fixtures/public reads are not private-production sync or physical
GPS/BLE/UWB/backpack/provider acceptance.

## Verified build9 upload - 2026-11-07

Version **0.1.0 build9** was signed, archived, exported and successfully uploaded
in [run42437873593](https://github.com/ErrantActions/-led-backpack/actions/runs/42437873593).
Release source `1944292` passed complete native validation in
[run42435195099, attempt2](https://github.com/ErrantActions/-led-backpack/actions/runs/42435195099):
portable9/0, priority96/0 plus its UI1/0, focused528/0, full native964/0 with
2explicit skips, integrated UI5/0 and separate read-only public integration.
Do not add repeated groups together as a unique coverage total.
Attempt1 had a simulator UI runner bootstrap crash before UI cases; the fresh
host retry passed without removing test or release gates.

Build9 includes the Social tab, GPS/private hunt entry, current-playing PHONE
GIF swaps and paired Found Users, durable cooldown/recovery, direct community/
private-cloud sending, timing/loops, natural eyes and guided/map-first events.
Only committed validated source was promoted; independent dirty firmware,
bitmap/OTA/reserved-slot research was excluded. Existing profile/certificate/
API key and reviewed OS-provided-encryption declaration remain unchanged.
The exact-source Linux gate reused validation; signed archive/export/upload
and temporary signing/keychain/profile cleanup all passed.

The interactive App Store Connect session expired when refreshed after upload.
Therefore **Apple processing status and internal tester availability have not
been visually verified for build9**. Successful upload is not physical GPS/
BLE/UWB/backpack playback, App Attest, APNs, PRF/user-held recovery or external
beta approval evidence. Remaining roadmap work resumes after this confirmed
upload; new source work is not silently included in build9.

### Previous build8

Version **0.1.0 build8** was signed, archived and successfully uploaded in
[run42394340634, attempt2](https://github.com/ErrantActions/-led-backpack/actions/runs/42394340634).
Release `eead26d` preserves the exact native inputs verified at `30ee227` in
the consolidated recovery run; independent dirty firmware/Wire/reserved-slot
research was excluded. The release gate passed without repeating simulator
tests. Temporary signing files/keychain/profile were cleaned successfully.

Attempt1 failed before upload because the old distribution profile lacked
Associated Domains. The owner-authorized App ID capability was enabled and
the existing App Store profile regenerated with the same distribution
certificate. Its app/team/certificate/expiry/distribution/Apple-login/Associated
Domains were verified before replacing only the profile environment secret.
No certificate/API-key rotation or feature removal was performed.

App Store Connect visibly lists build8 as **Processing** after upload.
This is not yet internal-group availability, physical device acceptance,
external beta approval or an App Store release. Apple processing/group
assignment remains a separate checkpoint. The existing OS-provided-encryption
declaration was retained after owner review of Apple's documentation table.
No encryption documentation was fabricated or uploaded.

The workflow is manual, main-branch-only, environment-protected, and requires
an explicit upload confirmation. It does not submit an App Store release or
request external beta distribution. Internal beta uploads build, sign, archive,
export and upload the committed source. They do not run simulator tests or
require a full passing regression suite. Release-input/toolchain checks,
protected approval, the signed device build and signing cleanup remain required.
Focused/full native validation is a separate workflow, not a routine TestFlight
prerequisite. Do not repeatedly run broad suites merely to upload an internal beta.

Both workflows use the documented `xcode-27` hosted image and exactly
`/Applications/Xcode_27.1.app`. They verify the iOS 27.1 SDK and fail early
instead of silently falling back to an older SDK. Native validation uses the
iOS 27.1 iPhone Duo simulator. Review the exported layout screenshots before
releasing; simulator/rotation checks alone do not prove physical fold behavior.

Unsigned simulator Keychain entitlement failures do not authorize replacing
production Keychain storage or silently ignoring its errors.

## 1. Register the app with Apple

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Register an explicit App ID for **`com.errantactions.ledbackpack`**.
2. Use the same Apple Developer team that will sign the build.
3. The current committed app requires **Associated Domains** for its
   `webcredentials:led.errantactions.com` passkey association and **Sign in with
   Apple** on this App ID and the committed `LEDBackpack.entitlements`.
   Enable both and regenerate this app's distribution profile when changed.
   These settings do not themselves activate APNs, iCloud or CloudKit.
   Bluetooth/location background modes and privacy strings are in Info.plist.

In [App Store Connect](https://appstoreconnect.apple.com/apps):

1. Add a new **iOS** app.
2. Name: **LED Backpack**, if that name is available.
3. Primary language: your intended language, e.g. English.
4. Select `com.errantactions.ledbackpack`.
5. Use a unique SKU, e.g. `led-backpack-ios`.
6. Accept outstanding Apple agreements if Apple blocks app creation.
7. Under TestFlight, create an internal group, e.g. **Internal**.

Internal testers must be eligible App Store Connect users with access to the
app (up to 100). A friend who is not an eligible account user normally needs
external TestFlight testing and its separate review process.

## 2. Create the distribution certificate from Windows

You can use the OpenSSL included with Git for Windows. Work in a **private
folder outside the repository**. Do not paste passwords/private keys into chat
or commit them, even if encrypted.

In a local PowerShell terminal:

```powershell
$openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
& $openssl genrsa -aes256 -out AppleDistribution.key 2048
& $openssl req -new -key AppleDistribution.key -out AppleDistribution.csr
```

Enter the key's passphrase interactively. Enter your own appropriate
certificate-request identity when prompted. Keep that information private.

In Apple's Certificates section:

1. Create an **Apple Distribution** certificate.
2. Upload the `.csr`, not the private `.key`.
3. Download the resulting distribution certificate as `distribution.cer`.

Back in your private local folder:

```powershell
& $openssl x509 -inform DER -in distribution.cer -out distribution.pem
& $openssl pkcs12 -export -inkey AppleDistribution.key -in distribution.pem -out distribution.p12
```

The commands prompt for the private-key and P12 export passwords as needed.
The **P12 export password** is the password the CI import needs.

Do not revoke an existing certificate used by other apps merely to create this
one. Certificate/profile administration needs an appropriate Apple team role.

## 3. Create the provisioning profile

In Apple's Profiles section:

1. Create an **App Store Connect / App Store distribution** profile.
2. Select the explicit LED Backpack App ID.
3. Select the matching Apple Distribution certificate from step 2.
4. Name it, e.g. **LED Backpack App Store**.
5. Download its `.mobileprovision`.
6. If Sign in with Apple was added afterward, regenerate the profile before
   configuring CI. The signing helper requires that capability; an old profile
   will not sign the updated app. The distribution certificate can be reused.

Do not use a Development, Ad Hoc, enterprise or wildcard profile.
The CI helper checks the team, exact application identifier, expiration, and
distribution type, and refuses to overwrite an existing profile on the runner.

## 4. Create an App Store Connect upload API key

In App Store Connect **Users and Access > Integrations > App Store Connect API**:

1. Create a team API key with sufficient app-upload access (normally App Manager).
2. Record the **Key ID** and **Issuer ID**.
3. Download the `.p8` private key; Apple normally allows a single download.

This API key authenticates the upload. It is not the Apple Distribution
certificate, and it does not replace the provisioning profile.

## 5. Configure the GitHub environment

In this repository's **Settings > Environments**, create **`testflight`**.
Restrict deployment to `main` and enable required-reviewer protection where
your GitHub plan/team configuration supports it.

Add these **environment secrets**, not files in the repository:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | Apple's ten-character Team ID |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 of the P12 |
| `IOS_DISTRIBUTION_P12_PASSWORD` | P12 export password |
| `IOS_APPSTORE_PROFILE_BASE64` | Base64 of the `.mobileprovision` |
| `APP_STORE_CONNECT_KEY_ID` | Upload API Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Upload API Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64 of the `.p8` private key |

On Windows, [Configure-Signing.ps1](Configure-Signing.ps1) can upload these
secrets directly through an authenticated GitHub CLI. It targets only
`ErrantActions/-led-backpack` and the existing `testflight` environment.
Run it in your own PowerShell terminal with explicit file paths and identifiers:

```powershell
.\ios\Configure-Signing.ps1 -P12Path 'C:\private-signing\distribution.p12' `
  -ProfilePath 'C:\private-signing\LED_Backpack_App_Store.mobileprovision' `
  -ApiKeyPath 'C:\private-signing\AuthKey_YOURKEYID.p8' `
  -TeamId 'YOURTEAMID' -KeyId 'YOURKEYID' -IssuerId 'YOUR-ISSUER-UUID'
```

Replace the example paths and identifiers. The script prompts privately for the
P12 export password, verifies the profile's signature, app, team, expiry and
distribution type, and checks that its certificate matches the P12. Secret
values go over the CLI's standard input, not command-line arguments, logs or the
clipboard. It does not create an environment, change its protections, configure
export compliance or start a build/upload. Existing GitHub secrets cannot be
downloaded; reuse the original local signing files and known export password.
An existing Distribution identity and permitted team upload API key can be
reused across apps on the same team, but each app needs its own profile.

Alternatively, to configure the secrets manually:

To copy a file as one-line base64 without printing it to a terminal log:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\private-signing\distribution.p12')) | Set-Clipboard
```

Replace the example path with your private file. Paste directly into the
corresponding GitHub secret. Repeat for the profile and P8. Clear your clipboard
afterward; don't send its contents here.

Add the **environment variable** `IOS_NON_EXEMPT_ENCRYPTION` with an explicitly
reviewed value of `true` or `false`. Review Apple's export-compliance questions:
the current app also uses CryptoKit authenticated peer encryption and private
vault cryptography. Do not rely on the older HTTPS-only description. The
Account Holder must determine the appropriate
answer and any required documentation. There is deliberately no silent default.
The workflow writes that reviewed value into a temporary archive Info.plist,
not into committed source.

## 6. Run the internal upload

1. Confirm the regular simulator CI is green.
2. Open **Actions > LED Backpack TestFlight > Run workflow** on `main`.
3. Pick an unused Apple build number for version `0.1.0` (start with `1` for a
   new record; increment for each upload, including reuploads after processing).
4. Check **confirm_upload** only when you intend to upload.
5. Approve the protected environment if required.

The workflow:

- Builds the signed device archive directly, without a simulator/regression prerequisite.
- Creates a temporary keychain, installs the supplied signing identity/profile.
- Archives and exports a signed IPA for the configured team and bundle ID.
- Uploads to App Store Connect using Fastlane/API-key authentication.
- Does **not** distribute externally or submit an App Store release.
- Cleans up the task's keychain/profile/private temporary files even on failure.
- Does not publish the signed IPA or signing assets as public Actions artifacts.

The configured signed upload is now verified as recorded above. Each newer
build still requires a matching current profile, unused build number and
exact validated-source gate.

## 7. Add the build to internal testing

Wait for Apple processing. In **App Store Connect > LED Backpack > TestFlight**:

1. Complete any missing export-compliance/build questions.
2. Select the processed build.
3. Add it to the internal group and provide **What to Test** notes.
4. Invite eligible internal testers; install Apple's TestFlight app on their
   iPhones and accept the invitation.

Suggested first notes:

> Experimental stock-firmware LED backpack controller. Begin with read-only
> discovery/status. Test live previews, GPS freshness/cap and restoration while
> stationary. Do not delete or overwrite valuable backpack artwork without an
> original copy. Background behavior and physical pixel output need validation.

No claim of iPhone Duo certification is made by this upload. Full native Duo
adaptation additionally needs an appropriate SDK and actual resize/pose tests.

## Troubleshooting

- **Missing secrets:** configure the `testflight` environment with exact names.
- **Wrong team/profile/bundle:** recreate/select matching assets; do not bypass
  the checks or use arbitrary profiles.
- **No signing identity:** ensure the P12 contains its private key, the correct
  export password, and a valid Apple Distribution certificate.
- **Duplicate build number:** choose a new number and rerun.
- **App record missing:** create it before upload; this workflow does not create it.
- **Processing succeeds but no invitation:** manually add the build to an
  internal group and check App Store Connect user/app access.
- **Source/compiler tests fail:** fix the ordinary Mac build before trying
  credentials or a release upload.

Apple references:

- [Add an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
- [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [Fastlane TestFlight upload](https://docs.fastlane.tools/actions/upload_to_testflight/)
