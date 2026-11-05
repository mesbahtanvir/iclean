# Releasing to TestFlight

`.github/workflows/testflight.yml` builds the iPhone app for release, checks the build, and, after
someone approves, signs it with Apple's cloud signing and uploads it to App Store Connect, where it
appears in TestFlight. No certificate, provisioning profile or Mac is involved: the only credential is an
App Store Connect API key.

```text
 tag v1.2.0 ─┐
 Run workflow ─┴─►  archive  ──►  (a reviewer approves)  ──►  upload  ──►  App Store Connect  ──►  TestFlight
                    no secrets                                 the only job with the key
                    unsigned, checked                          signs in Apple's cloud, sends it
```

## One-time setup

You need a paid Apple Developer Program membership ($99 a year). The rest takes about twenty minutes.

### At Apple

1. **Register the bundle ID.** developer.apple.com, Account, Certificates, Identifiers & Profiles,
   Identifiers, **+**, App IDs, App: an explicit ID `com.mesbahtanvir.iclean`. The app uses no
   capabilities, so tick none. (App Store Connect only offers identifiers that exist.)
2. **Create the app.** appstoreconnect.apple.com, Apps, **+**, New App: platform iOS, a name (testers see
   it), a primary language, the bundle ID above, and any SKU (`iclean`).
3. **Create an API key.** App Store Connect, Users and Access, Integrations, App Store Connect API,
   Team Keys, **+**: name it `GitHub Actions` and give it the **Admin** role. Apple creates the
   distribution certificate in its cloud on the first upload, and a key with a lesser role may be refused
   that. Write down the **Key ID** (in the list) and the **Issuer ID** (above the list), and download the
   `.p8` file: Apple lets you do that once.
4. **Find your Team ID.** developer.apple.com, Account, Membership details.
5. **Make a group of testers.** Your app, TestFlight, **+** beside Internal Testing: add yourself and
   anyone else who has an App Store Connect user, and turn on automatic distribution so that each build
   reaches them without a click. External testers are a separate step in App Store Connect, and the first
   build of each version goes through Beta App Review.

### At GitHub

1. **Create the environment.** Settings, Environments, New environment, `testflight`. Add yourself as a
   required reviewer: that is the one gate between a click or a tag and an upload. Once a first run has
   worked, limit its deployment branches and tags to `main` and `v*`.
2. **Add four secrets to that environment** (not to the repository: a job can read an environment's
   secrets only by running under it, and only the upload job does).

   | Secret | Is |
   |---|---|
   | `ASC_KEY_ID` | the Key ID |
   | `ASC_ISSUER_ID` | the Issuer ID |
   | `ASC_KEY_P8` | the whole `.p8` file, or that file encoded as base64 |
   | `APPLE_TEAM_ID` | your Team ID |

   With the GitHub CLI the key goes in without a paste, and the other three ask for their value:

   ```bash
   gh secret set ASC_KEY_P8 --env testflight < ~/Downloads/AuthKey_XXXXXXXXXX.p8
   ```

   ```bash
   gh secret set ASC_KEY_ID --env testflight
   ```

   ```bash
   gh secret set ASC_ISSUER_ID --env testflight
   ```

   ```bash
   gh secret set APPLE_TEAM_ID --env testflight
   ```

3. **Try it without the secrets.** Actions, TestFlight, Run workflow, tick `dry_run`. It builds, checks
   and stops. This is also what a pull request that changes the release files runs.

## Shipping a build

- **By hand:** Actions, TestFlight, Run workflow, on `main`. Leave `dry_run` off.
- **By tag:** `git tag v1.1.0 && git push origin v1.1.0`. The tag names the version.

Either way the `upload` job waits for a reviewer of the `testflight` environment. The run's page has the
Review deployments button.

**Version and build number.** The version is the tag's, else the `version` input, else
`MARKETING_VERSION` in `project.yml`. A version is one to three numbers (`1.2.0`): App Store Connect does
not take `-beta`, and the build number is what tells builds of one version apart. The build number is the
workflow run's number, so it only rises; dry runs use numbers too, so the numbers skip, which does no
harm. If builds were uploaded some other way before, set the repository variable
`TESTFLIGHT_BUILD_OFFSET` (Settings, Secrets and variables, Actions, Variables) to the highest build
number App Store Connect has, and the numbers continue from there.

**After the upload** Apple processes the build, usually in 10 to 30 minutes, and mails the account holder
if it refuses it. Then it shows under TestFlight and goes to the testers of every group with automatic
distribution.

**What is checked first.** `scripts/check-built-app.py` reads the archived app: the bundle id, the Photos
text, no App Transport Security exceptions, the privacy manifest, no networking framework or API, none of
the Debug-only tooling, and that the version and the build number are the ones this run chose.

**Xcode.** The README asks for Xcode 27. The job stops when the runner's Xcode is older, because an older
compiler leaves out the code written for the newer SDK (the scan that goes on after the app is left,
for one) and the build would not have it. The "Select Xcode" step lists the Xcodes the runner has; pick one
with the `xcode` input (`27.0` selects `/Applications/Xcode_27.0.app`). To ship the older build anyway,
tick `allow_older_xcode`. A run started by a tag has no inputs, so it needs a runner whose Xcode is
new enough.

## When it fails

| It says | Because | Do |
|---|---|---|
| `ASC_… is not set` or `does not look right` | A secret is missing, was added to the wrong place, or is the wrong thing | Add it to the `testflight` environment; the message says what it should be |
| Cloud signing permission error, or no permission to create a certificate | The API key is not Admin | Make a key with the Admin role and replace the three secrets that came from it |
| No profiles for `com.mesbahtanvir.iclean`, or the bundle ID is not registered | Step 1 at Apple was skipped | Register the explicit App ID |
| Apple knows no app with this bundle ID | Step 2 at Apple was skipped | Create the app in App Store Connect |
| A binary with this build number already exists, or the build number must be higher | An upload used that number | Set `TESTFLIGHT_BUILD_OFFSET` to the highest build number in TestFlight |
| The version's train is closed | That version has been released or approved | Use a higher version |
| The export says the archive has no signature, or finds no signing identity | Cloud signing could not sign an archive that was built unsigned | See the next section |
| Xcode is older than the README asks for | The runner's default Xcode | The Xcode paragraph above |

The job prints Apple's own logs when the upload fails. They are in the "What Apple's tools logged" step.
GitHub hides the secrets in them.

## Why the archive is built unsigned

The archive job has no secrets and signs nothing; the upload job signs. So the code of a pull request or
a tag never runs next to the key, the job that waits for approval builds nothing, and the dry run builds
exactly the bits that would be signed. Signing at export is also what Apple's cloud signing is made for:
the distribution certificate stays at Apple, and no development certificate or registered device is
needed on the runner.

Two limits come with it. The iPhone app must have no entitlements (it has none now), because an archive
built without signing keeps none: when it gains a capability that needs one, such as iCloud, push or Sign
in with Apple, the archive step has to sign, and a test in `scripts/tests` fails until it does. And the
first real run is the test of the choice itself, because nothing can run it without your key. If Apple
refuses to sign an unsigned archive, the fix is in the archive step: build it with automatic signing, the
key and `-allowProvisioningUpdates` (Apple then wants a registered device for the development profile).

## Rotating the key

Revoke it in App Store Connect (Users and Access, Integrations), create another with the Admin role, and
replace `ASC_KEY_ID` and `ASC_KEY_P8` in the environment. The issuer and the team do not change.

## What the workflow does not do

- It does not run for a pull request with a secret in reach. The only job that reads one is under the
  `testflight` environment and is skipped for pull requests; `scripts/check-workflows.py` fails any job
  that reads a secret without an environment, and `scripts/tests` pin the shape of this workflow.
- It does not send the Mac app, add external testers, write "What to test" notes, or submit for review.
  Each can be added when it is wanted.
