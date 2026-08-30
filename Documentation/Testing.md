# Testing

## Overview

The suite is Python driving `libMViewCore.dylib` through ctypes. It exercises the shipping
code, not a reimplementation, and the same suite runs unchanged against a sanitised or
instrumented build of that library.

```bash
python3 Tools/test.py                    # build, then every suite
python3 Tools/test.py -k damage          # arguments pass through to pytest
python3 Tools/test.py --coverage [--coverage-floor 80]
python3 Tools/test.py --sanitize address|undefined|thread
python3 Tools/test.py --mutate
```

The first run creates `.venv` and installs pytest, hypothesis and numpy.

## The reference model

`Tests/Support/reference.py` implements the colour-strip codec a second time, in numpy,
written from the format rather than from the C. Golden vectors can only say that the
encoder still does what it did when they were recorded; they cannot distinguish a fixed bug
from a new one, and they say nothing about inputs nobody recorded. A second implementation
can be run on any input, and when the two disagree one of them is wrong and the input that
separated them is in hand.

Writing it found a bug in the model first: numpy slice views alias, so the Haar lifting
step was reading operands it had already overwritten. That is the shape of thing this
catches.

## Suites

| file | what it covers |
| --- | --- |
| `test_codec.py` | the C encoder against the reference model, over generated surfaces, origins and clipped strips |
| `test_wire.py` | an independent reader for the wire grammar, which reads a strip by the grammar rather than by calling the encoder back |
| `test_crypto.py` | AES-CMAC and HMAC-SHA-256 against RFC 4493 and RFC 4231; CTR as a keystream XOR; every HDCP derivation checked for dependence on every input byte |
| `test_protocol.py` | control framing, EDID parsing against generated malformed replies, and every frame builder checked for writing past its capacity |
| `test_damage.py` | the ledger as a state machine: arbitrary sequences of paint, plan and present with invariants after every step |
| `test_profiler.py` | the profiler, including concurrent recording |

Surfaces are drawn from several styles rather than one. The codec's paths are content
dependent: a flat tile never leaves the DC band, noise saturates the escape codes, and hard
edges are what first drove a luma coefficient past the codebook. Generating only noise
would exercise a third of the encoder.

## Stateful testing

The damage ledger carries per-strip debt across frames, so its bugs are sequence bugs. A
strip that stops being owed one frame too early leaves a stale tile on one of the dock's
buffers and nothing repairs it. Single-call tests cannot reach that. `test_damage.py` uses
hypothesis's `RuleBasedStateMachine` to drive arbitrary sequences and shrink any failure to
the shortest one that still breaks.

## Mutation testing

Coverage says a line ran. It does not say a test would notice the line being wrong.
`Tools/mutate.py` flips comparisons, shifts and constants one at a time, rebuilds, and
reports any mutant the suite still passes.

It found real holes the first time it ran. A sign flip in the Haar transform's vertical
pass and a loop reading a row past the end of a block both survived, because the suite at
that point checked self-consistency and syntax but never output values. The score against
the differential model is now 100% on `wht.c`: no single-operator change survives, because
any behavioural change makes the C disagree with the model.

## Coverage

`python3 Tools/test.py --coverage` prints two numbers, because one on its own misleads in
one direction or the other.

| Denominator | Line coverage |
| --- | ---: |
| Files the suite reaches through the instrumented library | 83.71% |
| Every C file in the library | 27.26% |
| Swift (793 lines, 6 files) | 0% |

Four sources read 0% in the second table without being untested: `usb_session.c`,
`ddc_native.c`, `capture_frame.c` and `supervisor.c` are driven by `Tests/Support/*.c`,
which `#include`s the source and compiles it into a separate, uninstrumented dylib so it
can be run against mock hardware. What genuinely has no test is `driver.c`, `usb_probe.c`,
`display.c` and `bench.c` — between them the mode-set sequence, device discovery and the
virtual-display layout.

`--coverage-floor` fails the run when the first number falls below it; CI runs at 80. The
floor exists because of a specific failure, not as a target to chase: a segfault inside the
suite means the interpreter never flushes its counters, every file then reports 0.00%, and
the run still exits through the reporting code. Read as a percentage that is a coverage
collapse; read as a signal it is a crash, and it has to fail either way. In CI the coverage
step also needs `set -o pipefail`, because a pipe into `tee` otherwise reports `tee`'s exit
status and buries the whole thing under a green tick.

### Sanitisers and the interpreter

macOS refuses to load a sanitizer runtime into an Apple-signed binary — "Sanitizer load
violates platform policy". A `.venv` built on Xcode's `python3` is one, so on such a
machine the ctypes suite cannot host ASan or UBSan at all, while a CI runner's own Python
can. `--sanitize address` always runs as a native binary for that reason
(`Tests/Support/asan_runner.c`, compiled with the pure-logic sources). `--sanitize
undefined` tries the ctypes suite first, because it reaches every fuzzed input, and falls
back to the same native runner when the load is refused, so the command means the same
thing on a laptop as it does on CI.

Swift is 0% by construction. The suite drives the library through `ctypes` and never
enters Swift; ScreenCaptureKit, the virtual displays and the menu-bar app are exercised
only by a live run against the dock.

## Reading a run

`python3 Tools/report.py logs/<run>` turns a folder of driver logs, `measure_processes.py`
samples and `profile.py --save` output into one `README.md`, with the charts written beside
it as SVG. It reads files that already exist and runs nothing, so it is safe to point at a
run somebody else recorded.

What it pulls out: per-head frame latency against the 16.67 ms budget, strips sent per
frame against the strips a whole surface would be, the zone profile, CPU and RSS per
process, and every line that matches a failure pattern — those grouped with digits and hex
replaced by `N`, so two hundred instances of the same bulk-write error appear as one row
with a count rather than two hundred lines to scroll past.

`Tools/MotionBench.swift` is the workload. It covers every screen, borderless and above
every window, and ignores the mouse so the machine stays usable while it runs.
`--pattern` picks what kind of pressure: `scroll` (the historical baseline), `text`,
`noise`, `gradient`, `flash`, `scatter`, `still`, or `cycle` for all of them in turn.
Each one is the worst case for a different stage, and the header of that file says which.

## What the suite cannot do

Nothing here proves pixels reach the panels. A faithfully encoded black frame and a broken
encoder are indistinguishable from inside the process, which is why `overall_pass` in
`logs/verify.json` requires a person to run `mview confirm` after looking at both monitors.
