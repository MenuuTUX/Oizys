# Architecture

## Overview

MView has three layers. The transport claims the USB interface and carries sealed frames.
The protocol layer authenticates the dock and sets modes. The scanout layer turns a
captured desktop into colour strips and decides which of them reach the wire.

```text
ScreenCaptureKit  ->  damage ledger  ->  strip encoder  ->  sealed frames  ->  USB
                          |                                      |
                      fingerprint                       control session clocks
```

## Transport

`usb_session.m` claims `IOUSBHostInterface` ff/00/03 exclusively, which is what stops
DisplayLink Manager reclaiming the dock mid-run. A frame goes out as a single bulk
transfer; splitting one across transfers halts the endpoint. When a frame's length is a
multiple of 1024 a zero-length packet terminates it.

`log.c` writes every control exchange to `logs/run.log`. The log is the only record of what
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

`display.m` wraps `CGVirtualDisplay`, and also seats the two heads side by side above the
main display and breaks any mirror set macOS folded them into. Both are necessary: macOS
appends new displays to the end of one row, and with Sidecar active it mirrored a head to
an iPad, so the dock drove the iPad's framebuffer at the iPad's aspect ratio. A pair the
user has already arranged as a contiguous block is left alone.

`capture.m` runs the ScreenCaptureKit streams and the refresh clock. ScreenCaptureKit
delivers frames only on change and stops entirely on a still desktop, so the clock carries
both the control session's cadence and any transmission debt a strip still owes.
