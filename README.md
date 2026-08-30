# MView

An open userspace driver for the DisplayLink Ridge dock. It presents two 1920×1080
displays to macOS, captures them, and encodes the result as Ridge colour strips over USB
without loading DisplayLink Manager, vendor libraries, or firmware.

The runtime is C. Objective-C appears only where Apple ships no C interface: IOUSBHost,
CGVirtualDisplay, and ScreenCaptureKit. There is no Swift, no C++, and no Rust.

## Overview

The measured dock is USB `17e9:6000`, whose type-`0x40` configuration record names
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

Or open `MView.xcodeproj`. Three targets: `MViewCore` is the static library, `mview` the
command-line tool, and `MViewCoreDylib` the same sources as a dylib for the test suite to
drive. Build settings live in `Configs/*.xcconfig` rather than inside the project file, so
a setting is reviewable in a diff and the IDE and command line cannot drift apart.

## Running

```bash
build/Release/mview probe                      # identify the hub, read-only
build/Release/mview diagnose --takeover        # authenticate both heads, read EDIDs
build/Release/mview verify --takeover          # measured pattern proof
build/Release/mview run --takeover             # forward two desktops
build/Release/mview confirm                    # record that you saw both panels
```

`--takeover` stops DisplayLink Manager before claiming the USB interfaces; bounded commands
restore it when they finish and `run` restores it on Ctrl-C.

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

```bash
python3 Tools/profile.py
python3 Tools/profile.py --save baseline.json
python3 Tools/profile.py --compare baseline.json
```

Zone collection is in C, because the zones are tens of nanoseconds and a Python callback
would cost more than the work being measured. Attribution, presentation and baseline
comparison are in Python.

## Performance

Everything outside the scanout path is USB latency. On a captured 1920×1080 desktop with
the localised damage a moving cursor and a dragged window produce:

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
Sources/mview/      command-line entry point
Tests/              pytest suites and the numpy reference model
Tools/              build, test, profile and mutation scripts
```

## License

MIT. See [LICENSE](LICENSE).
