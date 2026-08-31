# Ridge protocol notes

What is written down here was established from live I/O against the dock on this machine,
the public Vino project's documentation, and the HDCP 2.2 specification. No part of it came
from disassembling DisplayLink Manager or its libraries, and Oizys keeps no copy of anyone
else's source.

## Device

USB `17e9:6000`, product string "USB TO DP HDMI". The type-`0x40` configuration record
names the platform `RidgeDoc` and carries a firmware triple. Interface ff/00/03 is claimed
exclusively; DisplayLink Manager reclaims the dock if it is not.

Two heads: logical DDC selectors `1` and `3`, video bulk endpoints `0x08` and `0x0b`.

## Control session

Frames carry a 16-byte header: a size field of `body + 12` little-endian at offset 2, a
32-bit type at 4, sub and aux 16-bit fields at 8 and 10, and a sequence at 12.

After authentication the control plane is sealed with AES-CTR under a whitened session key,
and replies arrive on `0x84`.

Two clocks run for as long as the session is open, independent of whether any pixel moved:

| message | interval |
| --- | --- |
| `0x14/0x0c` status poll | 13 ms |
| `0x16/0x75` heartbeat, `0x2ee0` at offset 22 | 3 s |

These hold HDMI up. A build that sent no video for eighteen minutes kept both panels alive
on polls alone; a build that sent a correct keyframe and then stopped polling lost the link
within a second. Video is not the keepalive.

## Authentication

Standard HDCP 2.2 AKE: `AKE_Init` with `rtx`, the receiver's certificate,
`AKE_No_Stored_km` carrying `km` under RSA-OAEP, then `H'` verification, locality check
with `rn` and `L'`, and `SKE_Send_Eks` with the content key and `riv`. Both heads
authenticate separately.

## EDID

An EDID reply is `0x0114/0x0021` with the 128-byte blocks starting at offset 22. Byte 126
of the first block is the extension count and drives the copy length, so it is validated
against the payload before anything is read. Every block's checksum must sum to zero.

## Mode set

`0x48/0x22` carries the timing. Offsets are into the decrypted inner plaintext, and the
field positions are corroborated twice over: `off26` reads 1920 and `off70` reads 14850 in
units of 10 kHz, which is the 148.5 MHz pixel clock for 1080p60.

| off | 22 | 23 | 26 | 28 | 30 | 32 | 34 | 36 | 42 | 44 | 46 | 48 | 66 | 68 | 70 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | head | 2 | 1920 | 280 | 88 | 44 | 1080 | 45 | `0x0400` | 60 | `0x4000` | `0x6000` | `0x2810` | `0x0200` | 14850 |

`off22` is the head, zero-based. `off23` is **not** a head, despite sitting next to one and
holding small integers: it selects the mode's line count. The dock's buffer-sizing records give
the mapping outright, because they report the size it settles on:

| `off23` | lines the dock sizes for | record |
| --- | --- | --- |
| 0 | 720 | `2363f0 0 2d00 2d00` |
| 1 | 1440 | `2363f0 0 4000 5a00` |
| 2 | 1080 | `2363f0 0 4000 4380` |

Only 2 matches the 1080 the rest of the packet describes. Filling `off23` in with a head number
sizes the buffer 2/3 or 4/3 wrong, and the dock answers by taking a fallback path and leaving
the panel dark, with nothing in the session reporting a failure.

Reading `off23` as a head is an easy mistake to make twice. Notes for other Ridge firmware
describe a one-based head number at that offset, and a per-head setup burst elsewhere in this
protocol really does carry one, so the value agrees with a head index for exactly one head and
disagrees silently for the other.

## Sink engage

`0x16/0x23` takes the DDC selector at `off22` and the **head** at `off23`. Passing the selector
twice looks harmless and is not: the dock dispatches the command either way, and then does
nothing with it. Its trace shows the vendor handing it `(1, 0)` and `(3, 1)` and running a
three-call per-head setup immediately afterwards, which is what makes the dock size and
register a buffer for the mode that follows. Without it the set-mode is accepted, the timing is
programmed, the output flag is set, and no buffer is ever allocated, so the panel stays dark
with no error anywhere in the session.

This is the same mistake as the mode set's `off23`: a field that holds the head number, filled
in with a selector because both are small integers that happen to agree for one head.

## Video

A 1920×1080 head is 2040 strips of 64×16. Each strip is sixteen 8×8 blocks across three
planes, transformed with a three-level unscaled integer Haar pyramid, quantised into a
fixed scan order, and entropy coded.

The strip layout is a 16-byte header carrying the origin and two region offsets, then a
main region of last-significant-scan values and DC deltas, then two regions of AC
coefficients covering blocks 0–7 and 8–15. Every region is padded to an even byte count.

Codebook ceilings are 7 for the sync field, 10 for DC, 10 for chroma AC, and 9 for luma AC.
The luma ceiling being one below chroma is load-bearing: at the maximum category the unary
prefix carries no terminating zero, so a luma coefficient coded with chroma's ceiling emits
a bit the dock reads as an offset and everything after it in the half-strip decodes off by
one. The symptom is a picture that is almost right.

The dock rotates its backing store over 4×4-strip macro tiles, so a changed strip drags its
macro tile with it and each must be presented on three consecutive frames.

How many buffers it rotates over is a separate number, and on this dock it is two. The frame
trailer's phase is how the dock is told to step to the next one, and it has to wrap on the
real count: `dock.buffers` had been declared with a default of 2 and never read while the
trailer wrapped on a hardcoded 3, which advanced the phase past the last real buffer. The dock
then stopped flipping and held the armed frame on the glass, accepting and discarding every
frame after it. The symptom is a lit panel showing a still image, which looks nothing like a
protocol fault: every write succeeds and the dock reports no error.

`Tests/Support/reference.py` is an executable statement of all of the above.
