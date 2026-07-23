# Xcode Cloud signing recovery

Last reviewed: July 21, 2026

This runbook is for the Xcode Cloud failure reported by build 5 of the
`Testflight Workflow`:

- Repository: `vnguyen9/mahjong-sensei`
- Project: `MahjongSensei.xcodeproj`
- Scheme: `MahjongSensei`
- Action: Archive — iOS
- Failure stage: export for App Store distribution
- Xcode Cloud message: Code Signing — “Exporting for App Store Distribution
  failed.”

The archive action reached distribution export. This is different from a Swift
compile or test failure. The commit that triggered build 5 did not change the
bundle identifier, development team, version, or signing settings. The project
currently uses:

- Bundle ID: `com.lumiodatalabs.MahjongSensei`
- Team ID: `WX6S96WKKC`
- Signing: Automatically manage signing

## Two separate issues to correct

### 1. The current workflow cannot create a public beta build

The workflow screenshot shows **Distribution Preparation → TestFlight
(Internal Testing Only)**. Apple permanently restricts builds produced this way
to internal App Store Connect users. They cannot be added to an external group
or public TestFlight link.

For the public-beta workflow:

1. Open App Store Connect → Mahjong Sensei → Xcode Cloud → the workflow.
2. Under **Archive — iOS**, set **Distribution Preparation** to **App Store
   Connect**.
3. Remove the **TestFlight Internal Testing — iOS** post-action while diagnosing
   signing. The archive should first upload successfully without automatic
   group distribution.
4. Save the workflow.
5. Keep **Clean** enabled for the first external-capable build.
6. Start a manual build from the latest intended commit.
7. After it succeeds and processes in App Store Connect, add the build to an
   external TestFlight group manually.

Keep the existing internal-only workflow only if you want a separate fast lane
for team-only builds. Rename it `TestFlight Internal` so the restriction is
obvious. Create or duplicate a second workflow named `TestFlight External
Candidate` with App Store Connect distribution.

### 2. Find the exact distribution-signing failure

The email is only a summary. Do not rotate certificates or change bundle IDs
based on that message alone.

1. Open App Store Connect → Mahjong Sensei → Xcode Cloud → Builds → build 5.
2. Open **Archive — iOS**.
3. Download the logs artifact. Xcode Cloud artifacts are retained for a limited
   time, so save it with the release records.
4. Search the export log for these strings:

   ```text
   error: exportArchive
   IDEDistributionErrorDomain
   IDEProvisioningErrorDomain
   No signing certificate
   No profiles for
   Cloud signing
   requires a provisioning profile
   agreement
   ```

5. Record the first concrete error and its surrounding 20 lines. Later errors
   are often consequences rather than the cause.

## Error-to-fix map

| Export log says | Fix |
| --- | --- |
| No Apple Distribution signing certificate; cloud signing not permitted | In App Store Connect → Users and Access, have the Account Holder/Admin grant the initiating user access to cloud-managed distribution certificates. Retry; do not export a private key into CI. |
| Certificate expired or revoked | Account Holder/Admin checks Certificates, Identifiers & Profiles → Certificates. Allow Xcode Cloud to create/use a current cloud-managed Apple Distribution certificate. Rotate only if the log identifies the expired/revoked certificate. |
| No profiles for `com.lumiodatalabs.MahjongSensei` | Confirm the App ID exists under the same team (`WX6S96WKKC`), the App Store Connect app record uses exactly that bundle ID, and automatic signing is enabled. Then retry so Cloud can regenerate the distribution profile. |
| Team or bundle identifier mismatch | Do not create a second app ID. Make the Apple Developer/App Store Connect record match `com.lumiodatalabs.MahjongSensei` and team `WX6S96WKKC`, or intentionally update both the project and records together. |
| Updated program license agreement required | Account Holder signs the current agreement in the Apple Developer account. Also check App Store Connect → Business → Agreements for items requiring attention. |
| The app record does not exist or is inaccessible | Create/restore the App Store Connect record for the exact bundle ID and grant the workflow owner access to Mahjong Sensei. |
| Build string already used | Let App Store Connect/Xcode Cloud manage the build number or increment `CURRENT_PROJECT_VERSION`; never reuse a successfully uploaded version/build pair. A failed upload may reuse its build number. |
| Internal-only distribution restriction | Change the Archive action to **App Store Connect**. An already uploaded internal-only build cannot be converted; create a new build. |

## Account-side signing checklist

The Account Holder or Admin should verify all of the following:

- Apple Developer Program membership is active.
- Any updated Apple Developer Program agreement has been accepted.
- App Store Connect → Business has no agreement blocking distribution.
- App Store Connect app bundle ID is exactly
  `com.lumiodatalabs.MahjongSensei`.
- The App ID belongs to team `WX6S96WKKC`.
- The user starting the Cloud build has access to the app and source repository.
- The user can use cloud-managed distribution certificates, or an Account
  Holder/Admin starts the diagnostic build.
- Automatic signing remains enabled for the MahjongSensei application target.

## Project-side preflight

Run an unsigned Release archive to prove the source and Release configuration
can archive independently of Apple credentials:

```sh
xcodebuild \
  -project MahjongSensei.xcodeproj \
  -scheme MahjongSensei \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/mahjong-cloud-preflight-derived \
  CODE_SIGNING_ALLOWED=NO \
  archive \
  -archivePath /tmp/MahjongSenseiCloudPreflight.xcarchive
```

Interpretation:

- If this fails, fix the compile/archive error before touching certificates.
- If this succeeds but Xcode Cloud export fails, the remaining problem is in
  distribution preparation, account permissions, signing assets, or agreements.

Do not commit provisioning profiles, `.p12` files, private keys, App Store
Connect API keys, or passwords to this repository.

## Known local warning that is not the Cloud failure

A local machine may report malformed files under `~/Library/Developer/Xcode/
UserData/Provisioning Profiles`. Those are local profiles and are not used by
Xcode Cloud. Clean them locally only when diagnosing local device signing; they
do not explain a Cloud export without a matching Cloud log error.

## Success criteria

The recovery is complete only when:

- Archive — iOS is green.
- The build appears under App Store Connect → TestFlight after processing.
- The build does **not** have the internal-only indicator when intended for an
  external/public group.
- The build installs on at least one iPhone and one iPad through TestFlight.
- The Xcode Cloud logs and build identifier are saved in the release record.

## Apple references

- [Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
- [Configuring an Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)
- [Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference)
- [Distributing for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Adding internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
