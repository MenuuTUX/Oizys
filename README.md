# MView

An open userspace driver for the DisplayLink Ridge dock. It presents two 1920×1080
displays to macOS, captures them, and encodes the result as Ridge colour strips over USB
without loading DisplayLink Manager, vendor libraries, or firmware.

The driver, encoder, transport and recovery supervisor are C. Swift is the glue and
nothing more: it binds ScreenCaptureKit, `CGVirtualDisplay` and the menu-bar app, and hands
every frame straight to C, which owns queueing, buffer lifetimes, pixel access, encoding
and all scheduling decisions. No Objective-C or Objective-C++ remains in the tree.

## Overview

The measured ACASIS DS-0602 (DL-6950) adapter is USB `17e9:6000`; its type-`0x40` configuration record names
`RidgeDoc`. Two Dell P2219H monitors sit on logical selectors `1` and `3`, with video
endpoints `0x08` and `0x0b`.

A run authenticates the dock over HDCP 2.2, sets both heads to 1920×1080 at 60 Hz, creates
two virtual displays, and captures them with ScreenCaptureKit. The first frame after a
mode set is a keyframe covering the whole strip grid, presented three times so it reaches
every buffer the dock rotates through. After that only the macro tiles whose pixels moved
are encoded, each riding three consecutive frames for the same reason. A still desktop puts
zero bytes on the video endpoints; the link is held up by the control session's own clocks,
a 13 ms status poll and a 3 s heartbeat, which run whether or not anything moved.

## Requirements

macOS 14 or later on Apple silicon, Xcode 16 or later, and Screen Recording permission for
the built binary. The encoder is NEON and is compiled for the host core.

## Building

```bash
xcodebuild -project MView.xcodeproj -scheme mview -configuration Release build
```

For the standalone Swift menu-bar app:

```bash
python3 Tools/build_app.py
open build/Release/MView.app
```

Grant **MView** Screen Recording access, then use its Start/Stop button. Launch the bundle
with `open` or Finder so macOS attributes capture to MView, rather than a terminal or the
app that launched a bare executable. The bundle contains a Swift `MView` executable and a
separate C `MViewDriver` helper. Diagnostics are in
`~/Library/Application Support/MView/logs/`. This is an ad-hoc development build; a new
build can require permission again. Distribution signing and notarization are not set up.

Or open `MView.xcodeproj`. Two targets: `mview` is the command-line tool and
`MViewCoreDylib` builds the core sources as a dylib for the test suite to drive.
Build settings live in `Configs/*.xcconfig` rather than inside the project file, so
a setting is reviewable in a diff and the IDE and command line cannot drift apart.

## Running

```bash
build/Release/mview probe                      # identify the hub, read-only
build/Release/mview routes                     # configured routes and native I2C matches, read-only
build/Release/mview diagnose --takeover        # authenticate both heads, read EDIDs
build/Release/mview verify --takeover          # measured pattern proof
build/Release/mview run --takeover --stats     # one diagnostic session with capture metrics
build/Release/mview serve --takeover --stats   # recover MView sessions after failures
build/Release/mview confirm                    # record that you saw both panels
```

`--takeover` stops DisplayLink Manager before claiming the USB interfaces; bounded commands
restore it when they finish and `run` restores it on Ctrl-C. `serve` owns a separate C
worker, restarts MView after faults, and waits for a disconnected dock to return. It does
not launch DisplayLink for recovery. On Stop it restores DisplayLink only if it was running
before takeover. Virtual displays are recreated during recovery, so applications may move
windows during that gap.

## Dock and native routing

Both Dell HDMI connections currently use the Ridge USB graphics path. Disabling one with
`heads.active` stops MView driving that output. It does not connect it to the Mac's GPU.
`heads.native` describes an intended native connection and cannot switch the dock's wiring.
An explicit native configuration is checked before `run`, `patterns`, or `verify` stops
DisplayLink Manager. Overlapping dock/native selections and unverified native connections
are rejected.

A hybrid setup needs a physical native route through USB-C DisplayPort Alt Mode or
Thunderbolt. A dock can provide that alongside DisplayLink only if it has the additional
hardware. The identified ACASIS adapter advertises both HDMI outputs through DisplayLink,
with no separate native output. See [the routing investigation](Documentation/Routing.md).

`mview ddc list` reports native I2C services matched to a unique online monitor EDID.
DDC reads and writes over this backend still need validation on a natively connected
monitor. Ridge USB DDC tunnelling is not implemented. The Swift app currently provides connection,
recovery status, permission guidance and diagnostics; it does not yet expose monitor settings.

## Verification

`verify` and `run` write `logs/verify.json`: the live USB owner, Ridge identity and
firmware, H-prime/L-prime/V-prime results, sealed control replies, both presence bits and
EDIDs, and video writes on both endpoints.

`machine_pass` covers what the process can observe. `overall_pass` additionally requires a
person and is set only by `mview confirm`, which refuses a run whose `machine_pass` is
already false. The separation is deliberate: nothing measurable here distinguishes a
faithfully encoded black frame from a broken encoder, and earlier versions of this driver
reported success from USB acknowledgements while one panel was black and the other showed
no signal.

Both Dells were confirmed on 2026-08-29, first on solid-colour patterns and then on the
live desktop, with DisplayLink Manager stopped.

## Testing

```bash
python3 Tools/test.py                    # build the library, run every suite
python3 Tools/test.py --coverage
python3 Tools/test.py --sanitize thread
python3 Tools/test.py --mutate
```

The suite is Python driving `libMViewCore.dylib` through ctypes, so it exercises the
shipping code rather than a reimplementation of it. `Tools/test.py` creates `.venv` and
installs pytest, hypothesis and numpy on first run.

`Tests/Support/reference.py` is a second implementation of the codec, written in numpy from
the format rather than from the C. Any surface can be run through both, so unlike a
recorded vector it says something about inputs nobody thought to record. Mutation testing
scores 100% on `wht.c` against it: no single-operator change to the encoder survives,
because any behavioural change makes the two disagree.

See [Documentation/Testing.md](Documentation/Testing.md).

## Profiling

`run --takeover --stats` reports capture cadence, pending-frame replacements, processing
time and capture timestamp age when USB submission finishes. These do not measure panel
latency. `--profile` additionally instruments the inner codec loops and has measurable
overhead; do not use it for a CPU comparison against the vendor.

Frame PNG/binary dumps are off by default. Set `capture.dump_frames` only for an explicit
diagnostic capture: files in `logs/` can contain private screen content, including failure
dumps. Normal operation does not write pixel dumps.


```bash
python3 Tools/profile.py
python3 Tools/profile.py --save baseline.json
python3 Tools/profile.py --compare baseline.json
```

Zone collection is in C, because the zones are tens of nanoseconds and a Python callback
would cost more than the work being measured. Attribution, presentation and baseline
comparison are in Python.

```bash
build/MotionBench 60 --pattern cycle        # workload: every screen, above every window
python3 Tools/measure_processes.py cpu.json --seconds 20
python3 Tools/report.py logs/<run>          # one README.md with tables and charts
```

`report.py` reads driver logs, process samples and saved profiles out of a folder and
writes a single `README.md` beside them: latency per head against the frame budget, strips
sent against the strips a whole surface would be, zone timings, CPU and RSS, and the
failure lines grouped by shape with a count. `MotionBench` is the workload it is usually
reading; `--pattern` chooses which stage to pressurise, from scrolling rules through dense
text, full-screen noise, a panning gradient, 10 Hz flashes and scattered blinking squares
to a still desktop.

## Performance

See [the hardware comparison and recovery report](Documentation/Performance-2026-08-30.md)
for the current motion workload, CPU/RSS measurements, and physical-test status. The table
below is an earlier encoder microbenchmark, not an end-to-end latency measurement.

Earlier measurements used a 1920×1080 desktop with cursor and window damage:

| stage | at the start | now |
| --- | --- | --- |
| fingerprint a surface | 33.7 ms | 0.21 ms |
| encode a full frame, one core | 31.8 ms | 15.2 ms |
| encode a full frame, all cores | — | 2.8 ms |
| encode one macro tile | 0.236 ms | 0.068 ms |

Four things account for that. Strips are independent, so `dispatch_apply` spreads them over
the cores, which was worth more than every other change combined. Fingerprinting uses the
CRC32 instruction, one word per cycle against three dependent operations for the hash it
replaced. The colour conversion and the quantiser are NEON. The bit writer holds a register
and stores whole words rather than ORing single bits into pre-zeroed buffers.

The encoder is written as NEON intrinsics rather than inline assembly, and the generated
code is the argument for that: the widening subtract in the colour conversion comes out as
a single `usubl.8h`, fusing three intrinsics the source asks for separately. Hand-written
assembly would have frozen the worse version and locked the register allocator out.

There is no Metal in the scanout path, measured rather than assumed. Fingerprinting is the
most GPU-shaped work in the driver — 8 MB in, 16 KB out, unified memory, no upload cost —
and on an M3 it takes 0.21 ms across the cores. The same job as a compute kernel takes
0.863 ms, and an empty dispatch round trip costs 0.129 ms before any work happens. The
encoder is a worse fit again: variable-length bit packing whose output the CPU needs
straight back.

## Repository

```text
Configs/            xcconfig build settings
Documentation/      architecture, protocol and testing notes
Sources/MViewCore/  the driver
Sources/mview/      command-line entry point and C supervisor
Sources/MViewApp/   native Swift menu-bar app
Tests/              pytest suites and the numpy reference model
Tools/              build, test, profile and mutation scripts
```

## License

MIT. See [LICENSE](LICENSE).
