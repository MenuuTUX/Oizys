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
