# Historical monitor startup investigation

This is an incident record from before commit `6d975ad`. Its instructions and machine
state describe that investigation, not the current setup. The subsequent head-addressing
fixes are in [Protocol.md](Protocol.md) and [Dock-Trace.md](Dock-Trace.md). DisplayLink was
removed again during the 2026-08-31 cleanup. Old local logs and temporary paths below
may no longer exist.

## Task and result at the time

Fix Oizys so both physical Dell monitors show a live desktop without DisplayLink Manager. The user normally disconnects the dock overnight. After reconnecting this morning, both monitors stayed in standby. Restarting the Mac did not help.

**Official DisplayLink Manager 15.0 immediately restored both physical screens on this exact setup. Oizys loses the picture again when it takes over, including after DisplayLink has initialized the dock.** This is not limited to cold startup. No Oizys fix has been found or installed.

The user reported slowly pulsing white power LEDs, no backlight, and black screens. Power-cycling the right monitor briefly showed “no HDMI detected.” The most recent Oizys tests also produced black/no-HDMI screens. These are physical observations, not virtual-display screenshots.

## Environment

| Item | Value |
| --- | --- |
| Repository | `/Users/shib/Developer/Oizys` |
| Old workspace | `/Users/shib/Developer/MView`, no longer the active source tree |
| Machine | M3 MacBook Air, macOS 26.7 |
| Dock | ACASIS DS-0602, DisplayLink DL-6950 / Ridge |
| USB | `17e9:6000`, location `0x00200000`, 5 Gbit/s |
| Serial | `PUPR293133102069826705029` |
| Identity / firmware | `RidgeDoc`, `12.1.15` |
| Displays | Two Dell P2219H, HDMI, 1920×1080 at 60 Hz |
| USB interfaces | Video `ff/00/03` on interface 0; app/DFU interface 1 |
| Endpoints | Control OUT `02`, IN `84`; video OUT `08` and `0b` |
| DDC selectors | `1` and `3` |
| Installed app | `/Applications/Oizys.app` |
| Driver / CLI | `/Applications/Oizys.app/Contents/MacOS/OizysDriver`; `/opt/homebrew/bin/oizys` |
| Git HEAD | `157a524fbebc2d2ac46def51a2cef3fccf342897` |

The tree contains substantial pre-existing uncommitted work, including the MView → Oizys rename. Do not reset, clean, or overwrite it. This investigation did not edit production source or replace installed Oizys binaries. It added evidence and this handoff.

## State left for you

All experimental drivers have been stopped. Oizys's original production service is stopped. DisplayLink Manager has been relaunched to restore the previously confirmed working baseline; check ownership before testing.

DisplayLink had previously been removed at the user's request. The user explicitly approved temporarily reinstalling/running it for this comparison. Its signed, Apple-notarized 15.0 app was extracted from the official package and copied to `/Applications/DisplayLink Manager.app`. No installer scripts or login-screen extension were installed. The app remains available for this investigation, not as an accepted permanent dependency of Oizys. Preserve Oizys and remove the temporary vendor app after the independent solution is validated, or explain any unfinished cleanup to the user.

## What Oizys successfully does, despite no physical picture

- Owns the dock exclusively and reads its real identity.
- Completes shared authentication with H′, L′, and V′ verification.
- Receives the expected per-head authentication message sequence: `03, 14, 06, 07, 08, 0a, 0c, 12, 11`.
- Receives sealed control replies and real, distinct DEL EDIDs on both selectors.
- Reports presence and completes writes on both video endpoints.
- Creates two macOS virtual displays and captures nonblack desktop content with Screen Recording permission granted.
- Also fails when desktop capture and virtual displays are completely bypassed, while sending static colored frames and servicing control keepalives.

**USB write success, EDID, authentication, virtual displays, and “trained” logs do not prove HDMI output.** Verification JSON intentionally keeps physical confirmation false. The supervisor's heartbeat establishes worker responsiveness, not a working physical screen.

Both vendor-read EDIDs advertise CTA VIC 16 and a preferred 148.5 MHz 1920×1080 timing with horizontal blanking 280 and vertical blanking 45, matching Oizys's timing. EDID filenames identify the two panels as `DELA115-9D6N6W2` and `DELA115-9L5J443`.

## Tests already completed

| Test | Physical result |
| --- | --- |
| Restart Oizys; macOS wake assertion with `caffeinate -u` | Still black |
| Targeted standard IOKit USB resume and device reset | API calls succeeded; still black |
| User power-cycled monitor and fully disconnected/reconnected dock | No recovery; monitor could display its own no-HDMI message |
| Full Mac reboot | Still black with Oizys |
| Diagnostic Oizys desktop session | Nonblack captured frames and successful writes; panels remained asleep |
| Direct static blue/green using current driver core, no capture/virtual displays | 88 frame pairs and 2503 control-service calls in the initial test; still black |
| Move leading `2f=1 / 2e=3` sink markers before set-mode, following public Ridge documentation | 90-second isolated test; still black; patch rejected |
| Official DisplayLink 15.0, same hardware/cables | User confirmed both screens worked immediately |
| Original installed Oizys after DisplayLink, with vendor stopped and then removed | User explicitly confirmed both black; warm initialization by DisplayLink does not rescue Oizys |
| Repeat normal mode activation in the same authenticated session after three seconds of frames/keepalives | Still black/no HDMI; rejected |
| Current driver linked to the earlier IOUSBHost transport from commit `2003ec1` | More than 550 blue/green frame pairs; user confirmed still off while test owned USB; rejected as a fix |

One early 100-second handoff test restored DisplayLink before the user's reply, making that particular reply ambiguous. Do not cite it as an Oizys success. The later sustained production-only test removed that ambiguity and failed. There has been **no confirmed Oizys physical success in this investigation**.

## Code to inspect

All paths below are relative to the repository.

- `Sources/OizysCore/driver.c:215`: shared AKE and vendor preamble.
- `Sources/OizysCore/driver.c:446`: nine-step per-head authentication. It waits a fixed 165 ms after No_Stored_km and checks for Rrx, but does not fully validate every downstream authentication result.
- `Sources/OizysCore/driver.c:554`: control setup, output enable, per-head finalizers, and vendor request `24` with value zero.
- `Sources/OizysCore/driver.c:647`: EDID/presence reply handling; presence uses status bit `0x1000`.
- `Sources/OizysCore/driver.c:677`: presence probes, EDID reader start/fetch, sink engage, and post-engagement presence wait.
- `Sources/OizysCore/driver.c:1523`: mode activation, marker sequence, initial armed frame, commits, and black-frame training. “Trained” means writes completed, not verified physical output.
- `Sources/OizysCore/driver.c:1824`: status poll every 13 ms and heartbeat every 3 seconds. Runtime replies are drained rather than interpreted for downstream changes.
- `Sources/OizysCore/dl3.c:200`: fixed 1080p60 mode builder, flags `0400`, VIC word `2810`.
- `Sources/OizysCore/usb_session.c`: current IOKit C transport, synchronous reader thread and bounded inbox.
- `Sources/oizys/main.c:763`: desktop pipeline and activation order. Direct-color tests eliminate capture as a necessary cause.
- `Sources/oizys/supervisor.c`: recovery checks worker heartbeat/topology, not physical output.

The current `driver.c`, `dl3.c`, and `usb_session.c` match HEAD after normalizing the rename. Commit `d46060f` replaced the older Objective-C++ IOUSBHost transport with the C transport. The earlier `2003ec1` README documents prior physical success, but that is historical documentation, not proof of present behavior. Testing that older transport with today's driver did **not** restore a picture. It was compiled as Objective-C with namespace changes only, without C++ or a full repository rollback.

## Evidence and reproduction

All persistent evidence is under:

`/Users/shib/Developer/Oizys/logs/reconnect-20260831/`

Start with its `README.md`. It is chronological; later observations supersede earlier “pending” entries. Relevant files include:

- `desktop-diagnostic.log`, `desktop-verification.json`
- `direct-color-driver.log`, `direct-color-test.log`
- `experimental-startup-order.patch`, `experimental-driver.log`, `experimental-session.log`
- `displaylink-displays.txt`, `displaylink-usb-owner.txt`
- `warm-handoff-driver.log`, `warm-handoff-session.log`, `warm-handoff-verification.json`
- `production-after-displaylink.txt`
- `same-session-remode-test.py`, `same-session-remode-driver.log`, `same-session-remode-session.log`
- `previous-usb-test.py`, `usb_session-before-refactor.m`, `previous-usb-driver.log`, `previous-usb-session.log`

Temporary build products, the verified vendor package/app payload, and comparison scripts remain under `/tmp/oizys-displaylink-comparison/`. They can disappear on reboot. Older pre-reboot `/tmp/oizys-startup-order-test` files are already gone; the patch and results were preserved in the evidence directory.

Useful commands:

```sh
/opt/homebrew/bin/oizys probe
/opt/homebrew/bin/oizys service status
pgrep -fl 'Oizys|DisplayLink|previous-usb-test.py|remode-test.py'
/opt/homebrew/bin/oizys service stop
osascript -e 'tell application "DisplayLink Manager" to quit'
# Check that the vendor has released USB before starting a test.
/opt/homebrew/bin/oizys service start
# To restore the working vendor baseline, stop Oizys first, then:
open '/Applications/DisplayLink Manager.app'
```

An existing verbose diagnostic helper is at `build/DebugVerbose/Oizys-debug.app/Contents/MacOS/OizysDriver`. It supports `run --takeover --stats` and `patterns --takeover --seconds N`. The installed production build excludes those commands and vendor fallback. Do not assume a diagnostic's message about restoring DisplayLink means its compiled policy actually enables that behavior; the investigation wrappers explicitly restored it.

## Constraints and next investigation

Read `Documentation/OriginalBrief.md`, but distinguish its historical implementation notes from today's source. No firmware flashing, vendor binary disassembly/decompilation, vendor-library linking, or GPL kernel-code copying. Public Vino protocol documentation and this project's own history are available. Do not reset privacy permissions or change monitor settings indiscriminately.

Public references used were `https://github.com/FireBurn/Vino/blob/main/docs/ridge.md` and `https://github.com/FireBurn/Vino/blob/main/docs/handover.md`. They describe other docks/firmware as well. Their ready-byte rule cannot simply be transplanted: this dock returned readiness byte zero alongside real, distinct Dell EDIDs. A readiness/presence bit is also not established as a lit/dark oracle.

USB DDC/CI tunneling is not implemented here. The CLI's DDC implementation needs a native I2C route, which this dock's HDMI connections do not provide. Do not claim to have sent a monitor power-on VCP command through it.

The remaining question is why Oizys's apparently successful protocol session fails to produce HDMI while DisplayLink works immediately. The exact missing or incorrect step remains unknown. Avoid another generic restart loop or treating the rejected transport/mode experiments as a fix. Keep tests isolated and confirm actual colored patterns or a live desktop on both panels while Oizys exclusively owns USB. Make the active driver explicit before asking the user to judge the screens.
