# Testing

## Overview

The suite is Python driving `libMViewCore.dylib` through ctypes. It exercises the shipping
code, not a reimplementation, and the same suite runs unchanged against a sanitised or
instrumented build of that library.

```bash
python3 Tools/test.py                    # build, then every suite
python3 Tools/test.py -k damage          # arguments pass through to pytest
python3 Tools/test.py --coverage
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
| Files the suite reaches through the instrumented library | 64.00% |
| Every C file in the library | 20.96% |
| Swift (779 lines, 6 files) | 0% |

Four sources read 0% in the second table without being untested: `usb_session.c`,
`ddc_native.c`, `capture_frame.c` and `supervisor.c` are driven by `Tests/Support/*.c`,
which `#include`s the source and compiles it into a separate, uninstrumented dylib so it
can be run against mock hardware. What genuinely has no test is `driver.c`, `usb_probe.c`,
`display.c`, `config.c` and `bench.c` — between them the mode-set sequence, device
discovery, the virtual-display layout and configuration parsing.

Swift is 0% by construction. The suite drives the library through `ctypes` and never
enters Swift; ScreenCaptureKit, the virtual displays and the menu-bar app are exercised
only by a live run against the dock.

## What the suite cannot do

Nothing here proves pixels reach the panels. A faithfully encoded black frame and a broken
encoder are indistinguishable from inside the process, which is why `overall_pass` in
`logs/verify.json` requires a person to run `mview confirm` after looking at both monitors.
