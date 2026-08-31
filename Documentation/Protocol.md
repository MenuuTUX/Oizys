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
| | 1 | head+1 | 1920 | 280 | 88 | 44 | 1080 | 45 | `0x0400` | 60 | `0x4000` | `0x6000` | `0x2810` | `0x0200` | 14850 |

The two head bytes are the part worth stating plainly, because both were wrong here and
each one cost a working panel.

`off23` is the **one-based head number**, 1 and 2. It is the head selector. The per-head
setup burst in `configure_one_head` already used this convention; the mode builder pinned it
to a constant 2, so every set-mode addressed head 1. Head 0 was never programmed at all and
stayed dark, while head 1 was programmed twice under two stream indices and its downstream
link retried on a five-second cycle without ever settling.

`off22` is **not** a head index, despite reading like one. It is 1 for both heads. The only
vendor capture available shows `off22=1`, but that capture had a single monitor on the second
socket, so `off22=0` has never been observed on the wire and treating it as a zero-based head
was an inference rather than a reading. Sending 0 made the dock size head 0's buffer at 23040
against head 1's 17280 — a ratio of exactly 4/3, the 32-bit to 24-bit pixel ratio — after
which it skipped its final buffer registration and took a fallback path. The panel lit, held
the correct timing, and rendered a barred, banded image. With `off22=1` both heads compute
17280 and run an identical path through the dock's firmware.

Neither fault produced a failed write, a rejected frame, or an error reply. Both were visible
only in the dock's own trace and on the glass.

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

The dock rotates its backing store over 4×4-strip macro tiles across three buffers, so a
changed strip drags its macro tile with it and each must be presented on three consecutive
frames.

`Tests/Support/reference.py` is an executable statement of all of the above.
