# Contributing

Oizys targets Apple silicon, macOS 14 or later, and the Ridge `17e9:6000` dock.
Use Xcode 16 or later and Python 3.9 or later. The test runner creates `.venv`.

## Before submitting a change

Keep USB/protocol/encoding logic in C and Apple framework bindings in Swift. Reuse
existing code before adding dependencies. Add a regression check for changed behavior.

```sh
python3 Tools/make_xcodeproj.py
python3 Tools/test.py
python3 Tools/test.py --coverage
python3 Tools/test.py --sanitize address
./dev.sh build production
./dev.sh build debug-minimal
git diff --check
```

Commit source, tests, documentation, and the regenerated Xcode project together. Do not
commit build products, `.venv`, personal Xcode settings, signing material, or local logs.
`Oizys.png` is the single branding source; packaging generates the app icon from it.

Describe the failure or need, the resulting behavior, and the checks you ran. Report
coverage by scope. The current suite does not achieve 100% whole-project coverage.
Use `--project-coverage-floor 100` to verify that target rather than excluding code.

## Hardware acceptance

Software tests must not stop the user's display driver or change their monitor settings.
Keep configuration writes in temporary directories and replace hardware operations in
unit tests. Test build and installer failures without modifying real Applications folders.

A hardware change needs a separate live check on both physical panels, including a cold
dock reconnect. Record the dock/firmware, build revision, active driver, workload, and
physical result. A successful USB write, virtual screenshot, or `machine_pass` is not proof
that either panel displayed pixels. Never set `overall_pass` without the user's observation.

## Privacy and security

Logs can contain device identities and local paths. Optional frame dumps contain screen
content. Review and redact diagnostic exports before attaching them to an issue.
Do not attach credentials, captured private screens, or complete unreviewed logs.

Report suspected security issues privately through GitHub's security reporting feature
if available. If it is unavailable, open a minimal issue asking for a private contact
without exploit details or personal data. Do not claim a response-time guarantee.

macOS owns Screen Recording and other privacy permissions. Never modify the TCC database,
disable Gatekeeper, or silently grant access. A scoped reset removes authorization and
requires the user to approve the new app again.

## Releases

Update `VERSION` for a release and keep changes in `CHANGELOG.md`. Build all five variants
through CI. Production must exclude diagnostics and vendor fallback unless the explicit
fallback variant was chosen. Local ad-hoc signatures are for local installation;
distribution to other Macs requires Developer ID signing and notarization.

The installer preserves settings during a normal upgrade. Removing all user data and
resetting permissions is a separate, destructive clean-install operation, not a build step.
