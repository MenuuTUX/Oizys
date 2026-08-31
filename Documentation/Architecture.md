# Architecture

## Overview

Oizys has three layers. The transport claims the USB interface and carries sealed frames.
The protocol layer authenticates the dock and sets modes. The scanout layer turns a
captured desktop into colour strips and decides which of them reach the wire.

```text
ScreenCaptureKit  ->  damage ledger  ->  strip encoder  ->  sealed frames  ->  USB
                          |                                      |
                      fingerprint                       control session clocks
```

## Transport

`usb_session.c` claims `IOUSBHostInterface` ff/00/03 exclusively, which is what stops
DisplayLink Manager reclaiming the dock mid-run. A frame goes out as a single bulk
request, including lengths divisible by 1024. Splitting a frame or appending a separate
zero-length request is not supported. The extra request was followed by resets in motion
tests on this dock; removing it passed the subsequent sustained tests.

`log.c` records control exchanges to `logs/run.log`. The log is the only record of what
the dock actually said, and several of this driver's bugs were only visible there.

## Protocol

`crypto.c` implements the HDCP 2.2 primitives: AES-CMAC, AES-CTR, HMAC-SHA-256, the key
derivations, and RSA-OAEP through Security.framework. `dl3.c` builds control frames and
parses the dock's replies, including EDIDs.

`driver.c` runs the session: engage, authenticate, fetch EDIDs, set both heads to 1080p60,
then present. It also runs the control clocks, which matter more than they look. The dock
expects a `0x14/0x0c` status poll about every 13 ms and a `0x16/0x75` heartbeat every 3 s,
and drops HDMI within a second without them. These are independent of video: a build that
sent no pixels for eighteen minutes held the link on polls alone, and a build that sent a
correct keyframe and then stopped polling lost it immediately.

## Scanout

A 1920×1080 surface is divided into 64×16 strips, 2040 of them. Each frame:

1. **Fingerprint.** Every strip is hashed with two CRC32 lanes. Both lanes see every word;
   splitting them across alternate words is twice as fast and wrong, because a change
   confined to one lane's bytes leaves the other untouched and drops the collision
   probability from 2⁻⁶⁴ to 2⁻³².
2. **Charge.** A strip whose fingerprint moved charges its whole 4×4 macro tile, because
   the dock rotates its backing store over macro tiles.
3. **Encode.** Owed strips are encoded, in parallel over the cores when there are enough of
   them to be worth the dispatch. Below that threshold the serial path is faster.
4. **Present.** Each strip rides three consecutive frames, one per dock buffer plus a frame
   of margin, so every buffer receives it before the debt clears.

`encode.c` holds the ledger, `wht.c` the codec.

## Codec

Each 64×16 strip is sixteen 8×8 blocks in three planes. A block goes through a three-level
unscaled integer Haar pyramid, is quantised into scan order, and is coded as unary category
prefixes with magnitude bits and a sign.

Two rules in there are easy to get wrong and produce a picture that looks almost right.
The luma plane's codebook stops one category below chroma: at the maximum category the
unary prefix carries no terminating zero, so a luma coefficient coded with chroma's ceiling
emits a bit the dock reads as an offset and the rest of the half-strip decodes off by one.
And a magnitude past the codebook saturates rather than failing, because overflowing puts
`cap + 1` ones on the wire and a decoder that stops counting at `cap` reads the extra one
as data.

`Tests/Support/reference.py` implements all of this a second time and is the executable
statement of the format.

## Display

`display.c` wraps `CGVirtualDisplay`, and also seats the two heads side by side above the
main display and breaks any mirror set macOS folded them into. Both are necessary: macOS
appends new displays to the end of one row, and with Sidecar active it mirrored a head to
an iPad, so the dock drove the iPad's framebuffer at the iPad's aspect ratio. A pair the
user has already arranged as a contiguous block is left alone.

`Capture.swift` binds the ScreenCaptureKit streams and the refresh clock. ScreenCaptureKit
delivers frames only on change and stops entirely on a still desktop, so the clock carries
both the control session's cadence and any transmission debt a strip still owes.


Capture ingestion and encoding use separate serial queues. Ingestion retains at most one
pending complete frame per head; a newer frame replaces it while encoding is busy. Idle,
blank and suspended callbacks do not resend a stale surface. Both heads share one encoder
queue because the protocol state is not thread-safe. The refresh timer repays cached strip
debt only after two capture periods without a fresh presentation.

### Dirty rectangles

Each sample buffer carries `SCStreamFrameInfo.dirtyRects`, the compositor's own account of
what moved. Swift copies it into `OizysDirtyRect` values and hands it to C with the frame;
`oizys_damage_plan_dirty` then fingerprints only the strips those rectangles cover and
carries every other strip's previous fingerprint forward unchanged.

Before this, every frame re-read all 8 MB of the surface to find out which 64×16 strips had
changed, whether or not anything had. Two heads at ~57 fps is around 900 MB/s of reads that
mostly confirmed nothing happened, and it is the main reason the driver cost more CPU than
DisplayLink Manager, which gets its damage from the compositor instead of rediscovering it.

Three things keep this from trading correctness for the saving:

- A rectangle outside the surface impeaches the whole list for that frame, which falls back
  to reading everything. Trusting a list that is already wrong about one rectangle is how a
  stale tile gets onto a panel.
- A replaced frame's rectangles are unioned into the frame that replaces it. The dropped
  frame's pixels were never fingerprinted, so forgetting where they changed would strand
  those strips. If the union no longer fits, the frame falls back to a full pass.
- One strip row in `OIZYS_DAMAGE_SWEEP` is re-fingerprinted unconditionally every frame, on
  a rotating phase. The rectangle list is a hint from the compositor, not a contract; a
  rectangle it omits costs at most eight frames of staleness rather than a tile nothing
  ever repairs. The sweep is an eighth of the old cost, and it is the reason the fast path
  is safe to trust at all.

## Recovery

`oizys serve --takeover` keeps a small C supervisor separate from the capture/USB worker.
It restarts Oizys after worker failures, waits while the dock is absent or ambiguous, and
uses a 1–8 second retry backoff. A worker must start within 45 seconds and then report its
health every second; 15 seconds without a report triggers shutdown. Shutdown gets 10
seconds in diagnostic builds and three seconds in production before terminating an unresponsive worker. No encoding runs in the
supervisor, and no vendor binary is used for recovery.

A per-user file lock prevents duplicate services. Screen Recording permission and head
selection are checked before takeover. Stopping the service restores DisplayLink only if
it was running beforehand. `run --takeover` remains the single-session diagnostic command
and restores DisplayLink when it ends.

This first recovery implementation recreates virtual displays when its worker restarts;
applications may move windows during that gap. Preserving virtual-display identity and
window placement across worker replacement remains work for the persistent display host.
The menu-bar user interface and the Apple-framework adapters are Swift; protocol,
encoding, transport and process supervision are C. The Swift layer never touches a pixel:
it forwards the sample buffer and the compositor's dirty rectangles into C and stops
there. The encoder uses ARM CRC instructions
and NEON intrinsics where measured.


## App and privacy identity

The debug app's `Sources/OizysApp/Main.swift` owns menu-bar controls and starts the bundled
`OizysDriver` supervisor with `Process`. It receives text status, not pixels. Production's
`Production.swift` has no diagnostic UI. It listens for USB attachment/removal and macOS
session/sleep/wake events. Without one supported dock and an awake console session, no
capture or USB worker runs. The event listener remains dormant so reconnects need no launch.

Production is `Oizys.app`; debug is `Oizys-debug <version>.app`. `Tools/install_app.py`
installs production into Applications and registers a per-user Aqua-session LaunchAgent.
The login path never presents a permission dialog. Initial Screen Recording permission is
granted through macOS by opening the app manually; it cannot be granted by the installer.
Worker teardown is asynchronous and bounded to three seconds in production. Wake starts a
fresh session after the old worker exits; USB authentication and display setup still take
time. Oizys neither disables screen locking nor prevents system sleep.

The production Swift executable is named `Oizys`; the helper is `OizysDriver`. They cannot be named
`Oizys` and `oizys`, since those collide on the usual case-insensitive macOS filesystem.
App Stop allows the C supervisor to clean up; Quit waits for that cleanup. A bounded
benchmark launch (`open Oizys.app --args --benchmark`) starts after permission and stops
the driver automatically 75 seconds after it first becomes ready.
