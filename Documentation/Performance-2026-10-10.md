# Production performance check, 10 October 2026

## Scope and result

The owner confirmed moving coloured rows on both dock monitors and the return of both
normal desktops after the scrolling session. All three measured scrolling trials kept both
heads forwarding with the same worker. This establishes visible output for that session.
It does not measure image quality, physical refresh cadence, or input-to-photon latency.

The current Production driver and C supervisor used a median of **65.8% of one CPU core**
during scrolling. Median simultaneous peak driver RSS was **76.0 MiB**. WindowServer used
36.2% of one core separately. The native app was paused during the test, so these numbers
exclude its memory and CPU.

DisplayLink Manager is absent on this Mac. A current comparison with the vendor is therefore
unavailable. The dated 92.7% Oizys result used a different macOS version and display set;
these new measurements do not isolate a software improvement or establish a vendor advantage.

## Method

- Host: Mac15,12, M3 MacBook Air, 16 GiB, macOS 27.0.1, build 26A434.
- Displays: built-in display, a Sidecar/AirPlay display, and two 1920 x 1080 dock heads.
- Driver: the current Production build, `serve --takeover`, with isolated default configuration
  and no calibration. Neither `--stats` nor fine profiling was enabled.
- Workload: the exact historical `Tools/MotionBench.swift` source from revision `2003ec1`,
  compiled separately. It places a titled 960 x 540 scrolling-row window on each screen.
  The current tool's windowed flag scales with screen size and changes the row geometry,
  so that flag alone does not reproduce the historical workload.
- Each scrolling trial had three seconds of warmup and approximately 21 seconds of sampling.
  The sampler reads cumulative process CPU time and RSS once a second. CPU is the change in
  CPU seconds divided by elapsed wall time; 100% means one core.
- Driver memory is the largest simultaneous sum of worker and supervisor RSS. Shared pages
  can appear in both processes, so this is not a total system memory or energy measurement.
- The native development-session lease paused the installed service and restored it afterward.
  Measurements reject missing forwarding, a stopped workload, or a worker restart.

## Scrolling measurements

| Trial | Duration | Driver CPU | Driver peak RSS | WindowServer CPU |
| --- | ---: | ---: | ---: | ---: |
| 1 | 20.86 s | 64.0% | 76.0 MiB | 35.6% |
| 2 | 20.93 s | 66.8% | 77.2 MiB | 36.2% |
| 3 | 20.91 s | 65.8% | 71.9 MiB | 36.6% |
| Median | | 65.8% | 76.0 MiB | 36.2% |

The sampling worker did not restart in any of these trials. Owner confirmation applies to
this completed scrolling session, not to later still-screen or recovery trials.

## Still-screen check

Controlled idle performance is **unverified**. Both Production still-screen attempts failed
and were excluded from the results.

Two earlier samples between scrolling trials measured 45.5% and 40.6% driver CPU. They left
the desktop visible and waited only ten seconds. They are uncontrolled desktop samples,
not valid measurements of the configured idle path, which waits twenty seconds.

The first controlled attempt failed. Both heads reported a control-session keepalive failure,
and the supervisor restarted the worker. That sample includes recovery and is excluded from
idle performance. A subsequent DebugVerbose diagnostic run retained the same worker and
both forwarding heads, but the original cross-process window-placement check returned no
coverage. Its CPU numbers are excluded from the Production comparison. The cause of the
initial control-session failure remains undetermined.

The replacement still-screen test adds a placement report inside the test-window process.
It checks that a visible, full-screen static window covers each dock head throughout sampling.
It waits twenty-five seconds before measuring, beyond the default twenty-second idle threshold.
The repeat initially confirmed coverage of both heads, then lost forwarding when the control
session failed. The dock disappeared from the USB listing; both virtual heads disappeared.
The installed listener later detected the returned dock and recreated both heads. The owner
reported that the cable was connected and both normal desktops were visible afterward.
That observation confirms restoration; it does not establish why USB disconnected or prove
continuous output during the static workload.

The test-window placement reporting is confined to the ignored test copy. The debug driver
now logs USB control-read return codes and reply-queue overflow so another occurrence can
identify the transport failure. Production diagnostic logging remains compiled out.

## Outstanding gates

Energy is unmeasured. The local power sampler requires superuser access and returned an error.
CPU and RSS are not substitutes for energy measurements.

Physical cable recovery remains unverified. The owner reported disconnecting the Mac-to-dock
cable and both desktops returning, but both the native detector and an independent USB event
observer recorded no removal or addition. Forced worker recovery passed separately; it does
not prove physical hotplug recovery or window-position retention.

A current vendor comparison, physical panel latency, sleep/wake, lock/unlock, HDMI reconnection,
permission changes, and an unattended session remain outside the completed proof.

## Local evidence

Raw files are under `build/final-validation/performance/`, which is ignored by Git:

- `production-defaults/scroll-1.json`, `scroll-2.json`, and `scroll-3.json` contain cumulative
  CPU and RSS samples. `metadata.json` records worker and forwarding checks plus owner confirmation.
- `production-defaults/idle-1.json` and `idle-2.json` are the uncontrolled desktop samples.
- `production-still/` contains the failed initial static run.
- `diagnostic-still/` contains the diagnostic run rejected by the original placement check.
- `production-controlled-still/` contains the repeat with placement reports from the test windows.
- `summary.json` records the calculated numbers and remaining limits.
- `RecordedScroll.swift`, `ControlledStill.swift`, and `performance-check.swift` preserve
  the workload and temporary test coordinator used for these sessions.
