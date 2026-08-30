# Motion, latency and recovery — 2026-08-30

## Scope

Test host: MacBook Air M3, macOS 26.7 (25G224). Adapter: ACASIS DS-0602, DL-6950,
USB `17e9:6000`. Displays: two Dell P2219H panels at 1920×1080, 60 Hz, with both HDMI
cables left on the adapter. Vendor comparison: DisplayLink Manager 15.0.0.

The target remains an independent open-source replacement, with C/C++ and ARM intrinsics
in the driver and Swift in the user interface. This report records current measurements;
it does not establish feature parity, zero failures, or lower visible latency than the
vendor. A basic Swift menu-bar app is now available; USB DDC/CI and the full monitor-settings
interface are still unfinished.

## Reproduced failure and fixes

Scrolling reproduced USB endpoint resets in the previous implementation. The first
observed run failed after about eight seconds. Versions that explicitly enqueued a
zero-length request after packet-aligned frames also failed, including after a successfully
completed aligned frame. Saved frame records were within the size limit and their strips
passed the independent decoder.

Removing the extra zero-length request changed the result: a 60-second motion test,
120 seconds of motion followed by 60 seconds idle, and another 60-second cadence test
all completed without a reset. Subsequent recovery and comparison runs also used the
single-request path. This is evidence for the fix on this macOS/adapter combination, not a
claim about every USB controller. A frame remains one complete IOUSBHost request regardless
of packet alignment; short writes are errors.

Capture ingestion now keeps at most one pending complete frame per head. Newer frames
replace that pending frame when encoding is busy. Idle/blank/suspended callbacks are
ignored, and cached refreshes wait for two capture periods without fresh work. This avoids
replaying old surfaces between fresh updates. Normal operation no longer writes PNGs.
Strip-cache allocations retain capacity instead of resizing on every changed strip.

Failure messages are published atomically, partial capture startup is cleaned up, capture
startup has deadlines, and USB shutdown drains callbacks before freeing their context.
The mode-set path retries an overrun of its existing bracket up to three times; it does
not extend that bracket or retry failed USB writes in place.

## Capture cadence

The one-minute unprofiled cadence run (`mview-cadence-motion.log`) delivered roughly
57–58 complete captures per second per head. In the steady five-second windows, processing
averaged about 3–4 ms per capture. One pending frame per head was replaced over the minute.
These counts include captures with no changed encoded strips; they are not a measurement
of physical panel refresh.

`--stats` records capture cadence, replacements, processing duration and the age of the
ScreenCaptureKit display timestamp at the end of presentation. WindowServer can supply a
future timestamp, so age is clamped to zero in that case and included in the mean. Missing
timestamps are counted separately. This metric excludes unknown dock buffering and panel
scanout delay. It must not be reported as input-to-photon latency.

`--profile` also timestamps inner codec operations. That overhead affects CPU use, so CPU
comparisons below do not enable it.

## Repeated comparison

| Process group | CPU median (range), % of one core | Peak RSS median | WindowServer CPU median | WindowServer peak RSS median |
| --- | ---: | ---: | ---: | ---: |
| DisplayLink agent + XPC service | 54.0% (50.6–56.9) | 196.0 MiB | 41.2% | 297.7 MiB |
| MView worker + C supervisor | 92.7% (88.9–100.1) | 75.1 MiB | 41.9% | 319.5 MiB |

All six final trials completed without a reset or worker restart. MView uses roughly
1.72× the driver-process CPU of DisplayLink in this workload. Its driver-process RSS is
lower, while WindowServer RSS is higher. Shared pages and caching mean these RSS sums
are not a measurement of total system memory saved. MView is not yet ahead on CPU, and
no end-to-end latency advantage has been established.

`Tools/MotionBench.swift` puts the same 960×540 scrolling colored-row window on every
screen, including the built-in reference. That is what it did when these numbers were
taken. It has since changed defaults to a full-screen always-on-top surface and gained
other patterns, so reproducing this table needs `--windowed --pattern scroll`; the numbers
below are not comparable with a run of the current default. Trials alternate DisplayLink and MView, with
three seconds of motion warmup followed by at least twenty seconds of sampling. The final
MView trials use `serve --takeover --stats`, including its supervisor process. Each trial
must finish without a worker restart to qualify.

`Tools/measure_processes.py` samples cumulative CPU time and RSS once a second. CPU is the
change in cumulative CPU seconds divided by elapsed wall time; 100% means one core. RSS
is resident memory, not the total allocation footprint or energy use. WindowServer is
reported separately because the display work also changes its cost.

The workload is intentionally narrow. It does not establish video, full-screen animation,
text-quality, power-consumption or tail-latency performance. WindowServer caching and host
activity vary between runs. No physical-output confirmation for these changes has yet
been received from the user, so a lower memory figure cannot establish equivalent image
quality or visible responsiveness.

## Standalone app and ChatGPT attribution

The CLI tests were launched by the Codex helper inside `/Applications/ChatGPT.app`.
The user noticed macOS naming ChatGPT as the screen-sharing app. Apple's
[explanation of process responsibility](https://developer.apple.com/forums/thread/125438)
describes how privacy attribution can follow the user-facing app responsible for a helper.
That attribution does not add ChatGPT to MView's pixel path: the source calls
ScreenCaptureKit, the C encoder and IOUSBHost directly.

To test the launch context, a Swift `MView.app` was built and launched through LaunchServices.
The user granted its own Screen Recording permission. Its parent PID was 1, and TCC logged
`org.mview.MView` as the responsible app for the C helper. The embedded helper was verified
byte-for-byte identical to the CLI binary used in the repeated comparisons.

One identical 20-second motion sample measured **100.4% of one core** in the standalone C
worker, versus the earlier CLI range of 88.9–100.1%. The Swift UI and supervisor each
rounded to 0.0% CPU. Total app + supervisor + worker CPU was 100.4%, with 170.0 MiB
summed peak RSS; the Swift GUI adds resident memory absent from the CLI-only table above.
This single additional sample does not support launch attribution as the explanation for
the CPU gap. It is not a full statistical comparison of launch modes.

The standalone run stopped itself after 75 seconds and restored DisplayLink. Both Dells
were also independently confirmed online at 1080p60 with mirroring off. The sharing popup
shows one preview at a time; the user's two screenshots have opposite enabled navigation
arrows, consistent with separate carousel entries. A blank thumbnail alone does not prove
that a display or physical video stream is absent.

The native Swift window was visually checked after launch. Raw evidence:
`standalone-motion.json`, `standalone-app-session.log`, `mview-app-ui.png` and
`mview-tcc-attribution.log` in the same local evidence directory. The app is signed ad hoc
for development, since this machine has no usable development signing identity. Stable
signing and distribution packaging remain production work.

## Independent recovery

`mview serve --takeover` runs a separate C supervisor. It checks for a supported dock,
starts a fresh worker, and restarts MView after failures without launching DisplayLink.
Missing or ambiguous device sets cause a wait, rather than repeated seizures. Retry delay
backs off from one to eight seconds. Worker startup and heartbeat deadlines prevent a
hung framework call from blocking Stop indefinitely.

In the real-dock test, the active MView worker was deliberately killed. The supervisor
reopened the dock and reached healthy capture again in **7.66 seconds**. The subsequent
USB probe identified the new MView worker as the owner; no DisplayLink process appeared
in the thirty-second recovered-session sample. Both virtual heads resumed capture.
This tests a real worker crash; unplug/replug and an unresponsive worker were tested with
mock device discovery and real subprocesses, not by physically removing a cable.

Recovery currently recreates virtual displays, so application windows may move during the
gap. Preserving display identity and placement is still needed. Sleep/wake, HDMI hotplug,
lock/unlock, permissions changing during a session, and long unattended use need physical
validation. The software has not yet met the user's reliability target.

Stop restores DisplayLink only when it was running before service takeover. A machine
using MView alone does not need DisplayLink installed for service operation or recovery.
The single-session `run` command retains its diagnostic restore behavior.

## Validation and artifacts

Release CLI and dylib builds pass. All **73 tests pass**, including capture queue overload,
invalid DDC replies, complete USB frame boundaries, short writes, worker crashes,
absent/ambiguous/reconnected device discovery, duplicate services, and a worker that ignores
termination. Physical test wrappers restore DisplayLink after each bounded test.

Raw local evidence is in `logs/latency-20260830/` (gitignored):

- `comparison-final.json`, `*-final-*.json`, `*-final-*.log`: repeated samples and cadence.
- `mview-no-zlp-motion.log`, `mview-fixed-motion.log`: sustained motion and idle runs.
- `mview-cadence-motion.log`: one-minute capture cadence.
- `recovery.json`, `mview-recovery.log`, `recovered-probe.txt`: real worker-crash recovery.
- `tests-final.log`, `build-final.log`: suite and build results.

Rebuild the workload with `xcrun swiftc -O -module-cache-path build/ModuleCache
Tools/MotionBench.swift -o build/MotionBench`. Start either driver, run `build/MotionBench
27 --windowed --pattern scroll`, wait three seconds, then run `python3 Tools/measure_processes.py output.json --seconds
20`. Repeat under the same display layout. Do not run builds or test suites during CPU
sampling. Confirm the actual panels independently; do not use `mview confirm` solely
because USB and capture checks pass.
