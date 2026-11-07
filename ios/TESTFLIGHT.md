# Internal TestFlight setup

This prepares **LED Backpack**, bundle ID `com.errantactions.ledbackpack`,
version `0.1.0`, for internal testing. It does not create an Apple app record,
generate credentials, or upload anything by itself.

The workflow is manual, main-branch-only, environment-protected, and requires
an explicit upload confirmation. It does not submit an App Store release or
request external beta distribution. First get a passing regular
**LED Backpack iOS** or **Consolidated native recovery validation** workflow
whose complete app/test/package/project/privacy/entitlement and validation inputs
match the release commit exactly. A recovery-branch pass is eligible only after
that exact source is promoted to main; uncommitted firmware research is excluded.

 A lightweight Linux gate reuses
a successful push/manual CI run only when the app, tests, protocol
package, project, Info.plist and native CI workflow are unchanged. Documentation
and signing-only changes do not rebuild the simulator app. TestFlight still
creates the required signed device archive, but never repeats simulator tests.
Keep the native workflow's path filters and the release gate's protected paths
in sync when adding build inputs.

Both workflows use the documented `xcode-27` hosted image and exactly
`/Applications/Xcode_27.1.app`. They verify the iOS 27.1 SDK and fail early
instead of silently falling back to an older SDK. Native validation uses the
iOS 27.1 iPhone Duo simulator. Review the exported layout screenshots before
releasing; simulator/rotation checks alone do not prove physical fold behavior.

## 1. Register the app with Apple

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. Register an explicit App ID for **`com.errantactions.ledbackpack`**.
2. Use the same Apple Developer team that will sign the build.
3. This implementation does not need push-notification, iCloud, associated
   domain, or CloudKit entitlements. Native Apple login requires **Sign in with
   Apple** on this App ID and the committed `LEDBackpack.entitlements`.
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

- Verifies a passing native CI result before allocating a macOS release runner.
- Creates a temporary keychain, installs the supplied signing identity/profile.
- Archives and exports a signed IPA for the configured team and bundle ID.
- Uploads to App Store Connect using Fastlane/API-key authentication.
- Does **not** distribute externally or submit an App Store release.
- Cleans up the task's keychain/profile/private temporary files even on failure.
- Does not publish the signed IPA or signing assets as public Actions artifacts.

The first configured signing/upload run is still unverified until real
credentials and the Apple app record exist.

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
