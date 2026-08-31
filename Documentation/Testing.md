# Testing

## Overview

The suite is Python driving `libOizysCore.dylib` through ctypes. It exercises the shipping
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
For Xcode’s Test navigator, first run `./dev.sh setup`, then Command-U.
The XCTest bridge attaches the existing Python suite output to the result bundle;
it does not rebuild recursively. See [Xcode workflows](Xcode.md).

## Developer dashboard

Portable debug variants expose **Developer Dashboard** in the main window and menu-bar menu.
Debug bundles include a source snapshot, extracted into Application Support outside the
signed app. **Prepare tools** installs its isolated Python dependencies. You can also
choose a source checkout to run suites, coverage, sanitizers, mutation tests, scanout
profiles and reports. Xcode tools are required for compilation. Bundled encoder diagnostics
and motion workloads do not need Python. Each operation has a time limit, bounded output
and a Stop control.

Live metrics show system CPU, active/wired/compressed memory, thermal state, process CPU
and RSS, display resolution, mode refresh rate, display-link cadence, and Oizys's processed
capture FPS and latency. These are separate measurements; neither display-link cadence nor
capture FPS proves physical panel output. Inactive or unrelated display drivers have no
capture samples. GPU utilization and energy are not measured.

Use **Record samples** while running a workload to save resource data for `Tools/report.py`.
Recordings stop at 3,600 samples or when the dashboard closes. Hardware diagnostics require
the running Oizys session to stop before claiming the dock. The dashboard and its repository
tools are excluded from production app builds.

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
| `test_config.py` | configuration parsing, clamping, persistence, and defaults |
| `test_capture.py`, `test_usb_frames.py`, `test_ddc.py` | bounded capture, USB frame boundaries, and DDC validation with fake devices |
| `test_supervisor.py` | worker crash, timeout, duplicate service, and reconnect behavior |
| `test_debug_permissions.py`, `test_diagnostic_report.py` | Swift permission policy and private report export |
| `test_build_tools.py` | icon generation, installation rollback, build-policy rejection, and coverage validation |
| `test_cli.py` | CLI build policy, isolated configuration, and invalid controls without hardware changes |
| `test_fixture*.py`, `test_debug_session.py` | developer fixture and debug-session tooling |

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

`python3 Tools/test.py --coverage` builds isolated instrumented debug and production
products, runs the suite, and writes `build/coverage/summary.json`. It measures all native
sources under `Sources/`, the Swift/Objective-C developer executables under `Tools/`, and
all Python tools, including modules the tests never import.

The USB, DDC, capture, supervisor, permission, and diagnostic-report test adapters register
their separately compiled binaries. Their counters now contribute to the native report.
Production and debug use different compiled policies, so both are included. Packaging's
`build-info` calls are discarded before testing. A failed suite returns failure before
publishing a summary.

LLVM can omit functions with different hashes but the same name across executables. An
empty-profile baseline supplies the denominator for these functions in `summary.json`;
they count as unexecuted instead of disappearing. LLVM's HTML/report output may omit those
mismatched functions, so use the JSON summary for the complete measured denominator.
Python line and branch counts are in `build/coverage/python.json`; native branch counts
come from LLVM, which does not report Swift branch coverage.

- `build/coverage/html/index.html`: native execution details.
- `build/coverage/python-html/index.html`: Python line and branch details.
- `--coverage-floor 80`: minimum line coverage of the six core files historically measured
  by CI. This is not whole-project coverage.
- `--project-coverage-floor 100`: fails unless every measured native/Python line is covered
  and no executable source remains uninstrumented. This target currently fails.

The 2026-08-31 validation run passed 207 tests. It measured 83.16% line coverage in the
six-file core subset, 17.66% across native sources, and 19.23% across measured native and
Python lines. `DiagnosticReport.swift` reached 100% line coverage. These are snapshots,
not promises for later changes; regenerate the reports for the current checkout.

`dev.sh` is not instrumented by LLVM or coverage.py and is explicitly listed as unmeasured.
Many production lifecycle, GUI, device discovery, authentication, and error paths remain
unexecuted. A green core coverage check must not be presented as 100% project coverage.

### Sanitisers and the interpreter

macOS refuses to load a sanitizer runtime into an Apple-signed binary — "Sanitizer load
violates platform policy". A `.venv` built on Xcode's `python3` is one, so on such a
machine the ctypes suite cannot host ASan or UBSan at all, while a CI runner's own Python
can. `--sanitize address` always runs as a native binary for that reason
(`Tests/Support/asan_runner.c`, compiled with the pure-logic sources). `--sanitize
undefined` tries the ctypes suite first, because it reaches every fuzzed input, and falls
back to the same native runner when the load is refused, so the command means the same
thing on a laptop as it does on CI.

The permission policy and diagnostic export have native Swift checks. ScreenCaptureKit,
virtual displays, and most app lifecycle/UI paths still need additional tests and live
validation.

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
`logs/verify.json` requires a person to run `oizys confirm` after looking at both monitors.
