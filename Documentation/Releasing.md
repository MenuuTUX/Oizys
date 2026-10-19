# Releasing Oizys

The tagged release workflow builds five variants, checks the software suite, signs every
executable with Developer ID Application, signs production PKGs with Developer ID Installer,
and submits the apps, portable debug launchers, PKGs, and DMGs to Apple. It publishes only
after every notarization returns `Accepted`. Apps, PKGs, and DMGs receive stapled tickets.
Portable command line launchers receive online tickets; use their stapled DMGs when offline.
The debug build also renders normal, permission blocked, and recovering menu previews in CI.

## GitHub Actions credentials

Set these repository secrets before creating a `v<version>` tag or dispatching the workflow:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12` | Base64 of a Developer ID Application `.p12` with its private key |
| `APPLE_DEVELOPER_ID_APPLICATION_PASSWORD` | Password for that `.p12` |
| `APPLE_DEVELOPER_ID_APPLICATION_IDENTITY` | Full `Developer ID Application: ...` identity name |
| `APPLE_DEVELOPER_ID_INSTALLER_P12` | Base64 of a Developer ID Installer `.p12` with its private key |
| `APPLE_DEVELOPER_ID_INSTALLER_PASSWORD` | Password for that `.p12` |
| `APPLE_DEVELOPER_ID_INSTALLER_IDENTITY` | Full `Developer ID Installer: ...` identity name |
| `APPLE_NOTARY_API_KEY` | Base64 of the App Store Connect team API `.p8` key |
| `APPLE_NOTARY_API_KEY_ID` | App Store Connect key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |

The workflow imports the keys into a temporary keychain on the macOS runner and removes its
files at the end. Missing credentials, failed signatures, rejected submissions, or failed
ticket validation stop the release before `gh release create`. Keep the private keys and
passwords out of the repository and logs. The workflow does not install Oizys on the runner.

The build uses hardened runtime and a secure timestamp. Distribution builds also remove
the debugger entitlement from nested diagnostic tools, because Apple's notary service
rejects `get-task-allow`. Local developer builds keep their existing debug behavior.

Apple's [distribution signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [package signing checks](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
describe the required identity types and ticket checks.

## Before sharing a release

Check `SHA256SUMS.txt` after downloading the release. On a clean Apple silicon Mac running
macOS 14 or later, download the DMG normally so quarantine stays attached. Open it through
Finder, drag Oizys to Applications, launch it, grant Screen Recording through macOS, and
confirm both physical panels show the expected desktop. Repeat after a cold dock reconnect,
sleep and wake, and a login restart. Try the fallback image only on a machine with
DisplayLink Manager installed.

Test an upgrade from the prior signed release and check that settings and Screen Recording
access survive. Then verify rollback by reinstalling the prior release. Record the macOS
version, dock firmware, release tag, and visual result for each panel. A CI pass or virtual
display screenshot cannot replace that hardware observation.

The PKG places the app in `/Applications`; it does not register Oizys's per-user login agent
or shell alias. The app's login toggle and the repository's `dev.sh install` handle startup.
Do not run a clean install on a user's daily Mac for release validation: it can remove
their current app and privacy approval.
