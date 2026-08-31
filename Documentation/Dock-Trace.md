# Reading the dock's own log

The Ridge firmware keeps a text trace of what it is doing and hands it back over the control
plane. Draining it costs nothing that the driver was not already doing, and it reports the
dock's internal state rather than whether a USB write returned success. Both head-addressing
faults in `Protocol.md` were found here after every other signal in the system said the
driver was healthy.

## Getting it

The trace arrives as `sub=0x0c` replies to the `0x14/0x0c` status poll the control session
already sends every 13 ms. `drain_control_debug` in `driver.c` decodes and logs them.

The payload is ASCII, prefixed with fourteen zero bytes and newline-terminated per record:

```
|<timestamp> <symbol><head> [args...]\n
```

The first decoder dropped every byte below `0x20` while filtering for printable characters,
which swallowed the newlines and ran the records together. Field boundaries vanished and the
arguments were unreadable, which is why the geometry values sat in captured logs for hours
without being noticed. It now escapes non-printables instead of discarding them and logs the
raw payload beside the text. That change is what made the second fix findable.

To reconstruct a session, concatenate every `dock trace raw:` payload, decode the hex, strip
the zero padding, and split on `|`.

## Format

A record is a timestamp, then a five-character symbol with the head index appended, then
space-separated hexadecimal arguments. Symbols are firmware addresses, so there is no symbol
table and names have to be earned from context. Several were, because their arguments check
themselves.

| symbol | meaning | established by |
| --- | --- | --- |
| `2e6de<h> <bit> <new> <old>` | set a per-head flag | `new` is always `old` with `bit` applied |
| `3a652<h> <bit> <new> <old>` | clear a per-head flag | `new` is always `old` without `bit` |
| `29391<h> <n> <w> <h> <r>` | program timing | reads `780 438 3c`, which is 1920×1080 at 60 |
| `2363f<h> 0 <stride> <size>` | buffer geometry | `stride` is the `off46` the driver sent |
| `3de59<h> <base> <len>` | final buffer registration | absent on the failing head |
| `2ac75`, `273d7` | per-head base and length | same values `3de59` later carries |

Flag bit `0x4` is the one worth watching. DisplayLink leaves a working head holding it, and a
head that never sets it is a head with no picture.

## Method

Four things did the work, in this order.

**Diff the dock against itself.** Once one head rendered correctly and the other did not, the
working head became a reference implementation running on the same firmware in the same
session. Normalising the head index out of both trace streams and diffing them reduced a
firmware with no symbols to a handful of lines that actually differed. The second fault was
three lines: one wrong number, one fallback call the good head never made, one setup call the
bad head never reached.

**Distrust the transport.** Every USB write succeeded through both faults. No frame was
rejected, no endpoint stalled, no reply carried an error. `verify.json` keeps
`physical_confirmed` false for exactly this reason, and it should stay that way.

**Test the control before the change.** Several hours went into head 0's corruption before
anyone checked whether DisplayLink Manager reproduced it. It did, because the dock had been
left in a bad state — a hard `SIGKILL` of the vendor app, denying it a clean teardown. Every
measurement taken against that dock was noise. Establish that the vendor renders correctly,
then measure the driver, and power-cycle the dock between them.

**Separate the variables the test actually moves.** The pattern generator keys colour off the
logical head, so "head 0 is corrupt" and "red and blue are corrupt" were the same experiment
until the colours were swapped. Red and blue also share a luma value in this encoder and
differ only in chroma, which made the confound plausible rather than academic. Swapping the
head-to-endpoint routing, the colours, and the head-to-wire-identity mapping each eliminated a
class of cause outright.

## What this cannot do

The symbols are addresses in a firmware nobody here has read, and none of the names above
came from anywhere but argument arithmetic and context. They describe firmware 12.1.15 on
this dock. Treat a symbol whose meaning rests on a single observation as a guess, and say so
in the log rather than in the code.
