# Oizys product audit and redesign plan

## Implementation update, 10 October 2026

The audit fixes now include nanosecond configuration reload tracking, receiver certificate
trust checks, fail-closed random generation, typed settings and
port responses, bounded background CLI execution, retained values after failed reads,
coalesced slider commits, permission-aware status and actions, stable dock display names,
popover brightness controls, saved gamma-table restoration, and a 15-second display-change
confirmation with rollback on quit. Native controls provide keyboard and accessibility
behavior, and the connection animation follows Reduce Motion.

The window now uses Overview, Displays, Arrangement, Colour, Diagnostics, and Settings.
Overview shows both head states, a map using macOS desktop coordinates, USB warnings, and a
repair action. Recovery includes elapsed time and guidance. Recent state changes are bounded
to eight observations from the current app session. A local report exports only connection
state and display geometry; raw logs, file paths, USB serials, and desktop content are omitted.
The popover hides brightness sliders until both heads are forwarding and offers individual
100% resets. Per-head power controls sit beside the display controls; shared power and Sidecar
are disclosures within Displays. App preferences moved to Settings. Advanced settings have
search, current and default values, individual resets, and an editor that stays open on failure.

Calibration now stages solver output in an isolated temporary directory and saves only while
the session remains active. Cancel during solving therefore leaves the active correction
intact. Undo restores the previous correction file exactly, including its absence, and refuses
to overwrite a later change. Clear stored correction is available without a new calibration
and removes both head corrections together. The guided screen includes eligibility, progress,
cancel, and a short measurement-limits disclosure.

Failed setting writes now restore the last confirmed value even when the follow-up read
also fails. Refreshes preserve unfinished slider edits, setting saves avoid rescanning USB,
and Sidecar rules update only after the saved values are read. Sidecar mirroring uses the
same display confirmation and rollback as the other layout controls.

Phone calibration now uses bounded, assembled HTTPS requests, exact authenticated routes,
a single-use entry token, sequential validated readings, session cancellation, and a
background solver. Live TLS tests cover certificate identity, IP hostname verification,
fragmented requests, token replay, restart, renewal, and listener shutdown. The release
workflow requires Developer ID signing and successful Apple notarization before publication.
The installer now preserves approval when both bundles have the same Developer ID designated
requirement and identifier. Loss of a previously observed grant triggers rollback. This policy
is covered by intercepted installer tests; it has not passed a real signed upgrade on a clean Mac.
Dormant DDC research is excluded from shipping builds, and unused USB chunk planning is removed.

The software suite passed 328 tests. Production and DebugVerbose builds passed. Native app
checks cover failed saves and reads, refresh during editing, reset, command timeout, slider
accessibility labels and values, arrow-key input, deferred commits, and exact RGB-table
restoration after a failed restore is retried. Generated healthy, permission-blocked, and
recovering interface previews cover static state and layout.
The built-app interaction check passed keyboard navigation through all six sections,
keyboard filtering of advanced settings, distinct reset labels, and the expected accessible
actions and brightness visibility in healthy, blocked, and recovering states.
The cancellation check waits until the real subprocess starts, cancels the session, and
verifies that its late completion leaves the active file unchanged. The same check then
completes a save and undoes it through the app's session coordinator.

The first physical test exposed a compatibility error: the local Ridge certificate does
not verify with the published DCP issuer key. The owner explicitly approved an exact
certificate fingerprint pin for this dock. Modified and unknown certificates remain
blocked; this is not proof of a DCP issuer chain or compatibility with other docks.
After that change, machine verification passed and the owner confirmed both alternating
color patterns and the return of both desktops. The confirmation command now records
both the overall result and the physical-observation field consistently.
The updated supervisor also recovered after its capture worker was forcibly terminated.
The replacement worker authenticated both heads, captured and sent both desktops, and
the owner confirmed both monitors recovered. The development session then restored the
previous production service and removed its temporary ownership lease.
For the physical cable check, the owner reported disconnecting the Mac-to-dock data cable
and seeing both desktops return. The test did not observe USB absence or a worker restart,
so reconnect acceptance remains unverified. The timed session restored production afterward.
The owner repeated the cable check with an independent observer of all USB attach/detach
events and again reported both desktops returning. That observer also captured no device
removal or addition. The mismatch remains unresolved; the production service was left running.

Three current Production scrolling trials retained both forwarding heads without a worker
restart. The owner confirmed moving rows on both monitors and normal desktops afterward.
Median driver CPU was 65.8% of one core and simultaneous peak RSS was 76.0 MiB. This is an
Oizys-only measurement on macOS 27.0.1 with a Sidecar/AirPlay display present. DisplayLink
Manager is absent, so it does not establish a current vendor comparison or isolate a change
from the dated macOS 26.7 result.
Both controlled Production still-screen attempts failed with a control-session keepalive
error. The repeated attempt also observed USB absence and the loss of both virtual displays.
The installed listener later detected the returned dock, recreated both heads, and the owner
reported normal desktops. Idle CPU remains unverified; failed samples are excluded. Debug
USB failure logging now records control-read error codes and a full reply queue. See
[the current performance report](Performance-2026-10-10.md).

### Remaining acceptance work

| Area | Implemented evidence | Remaining proof |
| --- | --- | --- |
| Status and recovery | Versioned supervisor state, permission and one-head guidance, retry action, timeline, scripted state checks, observed worker-crash recovery | Physical reconnect detection and output, sleep/wake, lock/unlock, single-HDMI reconnect, permission change, long unattended use, arrangement and window retention |
| Settings and responsiveness | Bounded CLI, retained confirmed values, one commit per drag, individual reset, search, save-error tests | Matched popover-open and idle CPU measurements |
| Calibration and display safety | Live TLS checks, staged save, undo conflict protection, exact gamma restoration, 15-second mode/layout rollback | Physical iPhone certificate/camera flow and visual calibration result |
| Native interface | Six sections, semantic system colours, native controls, minimum-size previews, native slider input, built-app sidebar keyboard navigation, keyboard search, and accessible state actions | Manual setup and display-control tasks, and full VoiceOver navigation |
| Public release | Signing/notarization required by workflow, packaging and rollback tests | Signing credentials, clean-Mac install/update/rollback, permission retention across signed updates |
| Performance | Three current Production historical-workload scrolling trials, no restarts, owner-confirmed output; median 65.8% driver CPU and 76.0 MiB RSS | Diagnose the failed controlled idle runs; current vendor comparison, energy, and physical recovery timing |

Manual setup/display-control and VoiceOver tasks, cold reconnect, the iPhone certificate/camera flow,
and clean-Mac install/update still need live acceptance. No iPhone or release signing
credentials are available for the remaining checks, so no signed public release was
produced. The recommendations below record the original audit, including broader product
ideas that are not all implemented.

## Implementation update, 26 September 2026

The first reliability slice is implemented: the C supervisor now publishes an atomic,
versioned runtime status with phase and active head mask, and the app checks it against
the live supervisor PID and the online virtual heads before showing a live connection.
The menu icon follows that verified software state. Login-service and display-sleep
queries now run on the app's background command queue rather than on each fast UI refresh.
The status remains a software observation; a person must still confirm that physical
panels show the picture. The following audit findings describe the original baseline and
remain the plan for work not covered by this first slice.

26 September 2026. This reviews the current working tree, including uncommitted changes. It is a plan, not an implementation or a claim that the physical monitors passed today.

## Scope and verdict

Oizys is a native macOS utility for one identified DisplayLink Ridge dock, not a general website. Its stack is SwiftUI and AppKit for the interface, ScreenCaptureKit and CoreGraphics for displays, a C encoder and USB driver, a C recovery supervisor, and Python build and test tools. The phone calibration page is its only browser interface. The supplied Altitude reference is therefore a visual direction for the Mac app and that phone page, not a reason to rebuild the driver as a web app.

The core is unusually well tested for an experimental hardware project. Damage tracking, codec output, protocol parsing, recovery, packaging policy, and configuration have automated checks. The product gap is trust at the edge: users cannot easily distinguish "app open," "supervisor alive," "head online," and "picture visible." The recent hardware report also says that reconnect and long unattended use have not met the reliability target. Work on those states should lead the redesign.

The recommended stack decision is to **keep the C driver and native SwiftUI/AppKit shell**. A browser framework, Electron, Metal rewrite, or new IPC service would add deployment and permission complexity without evidence that it improves the current bottlenecks. Add a small structured status and settings response to the existing CLI, then use that contract in the app. Revisit technology only after a repeatable measurement shows a specific limit.

## Evidence and limits

- `python3 Tools/test.py`: **275 passed in 77.49 seconds** on this machine.
- `xcodebuild -quiet -project Oizys.xcodeproj -scheme Oizys-debug-verbose -configuration DebugVerbose build`: exit 0, with two Swift implicit capture warnings in `OizysPanels.swift:680,686`.
- `Oizys-debug --render-preview build/audit-ui-2026-09-26`: exit 0. I inspected `popover.png`, `window.png`, `panel-power-and-standby.png`, and `panel-colour.png`. The whole-window render is a layout review aid; its offscreen AppKit controls are not proof of the live window's exact appearance.
- No dock takeover, unplug/replug, sleep/wake, physical display, power, or new end-to-end latency test was run. The installed production service was left alone.
- `Documentation/Performance-2026-08-30.md` reports 92.7% of one core median for Oizys worker plus supervisor against 54.0% for DisplayLink in one matched scrolling workload, and 75.1 MiB against 196.0 MiB peak driver-process RSS. Those are dated, workload-specific measurements; they do not describe this uncommitted build or total system memory.
- The prior physical test confirmed both panels on 29 August. The later report says worker-crash recovery took 7.66 seconds, windows can move when virtual displays are recreated, and physical sleep/wake, hotplug, lock/unlock, and unattended tests remain open. See `README.md:452` and `Documentation/Performance-2026-08-30.md:124-142`.

## How the product currently works

```text
Dock event / login state
  -> production listener and C supervisor
  -> authenticate dock and configure two fixed 1920 x 1080 heads
  -> create virtual displays
  -> ScreenCaptureKit frames and dirty rectangles
  -> C damage ledger, colour correction, strip encoder
  -> sealed USB frames and independent control clocks

Menu bar / window -> OizysModel -> bundled CLI or CoreGraphics -> configuration and actions
```

The event-driven dormant path and bounded capture queue are sensible. The control clocks must run even when no video is sent. The existing damage ledger and three-frame repayment address real dock behavior. Do not simplify these mechanisms merely because they are complex. See `Documentation/Architecture.md`, `Sources/OizysCore/driver.c`, `Sources/OizysCore/encode.c`, and `Sources/OizysPlatform/Capture.swift`.

## Ranked findings

| Priority | Finding and user effect | Evidence | Recommended change and proof |
| --- | --- | --- | --- |
| P0 | **Status overstates health.** The app marks `running` when a supervisor lock exists, and the menu icon follows that boolean. A supervisor can be alive while no virtual head is online or the panels are dark. The summary says "Starting..." in one case, but the action row still says "Running." | `Sources/OizysApp/OizysModel.swift:78-88,130-137`; `Sources/OizysApp/OizysPanels.swift:34-38`; `Sources/OizysApp/OizysMenuBar.swift:109` | Publish a typed state with `dockAbsent`, `permissionRequired`, `starting`, `recovering`, `oneHead`, `twoHeads`, `stopped`, and `fault`. Show last verified event and next action. Treat physical picture confirmation separately because software cannot infer it. Test transitions with fake status responses and real reconnects. |
| P0 | **Distribution is still developer-only.** Release automation publishes ad hoc signed, unnotarized bundles. Users on other Macs face Gatekeeper override and may need to regrant Screen Recording after rebuilds. | `README.md:62-78,181-201`; `.github/workflows/release.yml:24-99`; `Tools/install_app.py:99-143` | Before public release, use stable Developer ID signing and notarization, preserve the permission identity across updates, and test install/update/rollback on a clean Mac. Keep existing local builds for development. |
| P0 | **Hardware reliability gate is incomplete.** Recovery recreates virtual displays and can move windows. Sleep/wake, hotplug, lock/unlock, permission changes, and unattended sessions lack physical acceptance evidence. | `Documentation/Performance-2026-08-30.md:124-142`; `Documentation/Testing.md:169-173` | Define a repeatable dock matrix. Record visible output on both panels, arrangement, recovery time, process restart count, and whether windows move. Ship broader claims only after these pass. |
| P1 | **Main-thread status refresh can block.** Each refresh invokes `pmset` and `launchctl` synchronously, and refresh runs every 1.5 seconds while the popover is open and every 20 seconds with a dock. A slow child can freeze interaction. Sidecar tint is also reapplied on every refresh. | `Sources/OizysApp/OizysModel.swift:130-137,247-255,320-326`; `Sources/Support/OizysLifecycle.swift:71-76,80-81`; `Sources/OizysApp/OizysMenuBar.swift:91-99`; `Sources/OizysApp/DisplayTint.swift:33-53` | Cache slow facts and refresh them off the main thread on relevant events or a bounded interval. Apply tint only after a display or tint setting changes. Measure popover open time and idle CPU before and after. |
| P1 | **Slider drag queues persistent writes.** `HalftoneSlider` already has an `onCommit`, but head, Sidecar, and DDC bindings call config or DDC writes on each value change. Each `run` then rereads settings and ports. Rapid drags can queue obsolete writes and stale feedback. | `Sources/OizysApp/OizysLogo.swift:198-212`; `Sources/OizysApp/OizysPanels.swift:445-509,636-659`; `Sources/OizysApp/OizysModel.swift:116-126,140-153,306-312,332-340,394-397` | Keep local visual feedback during drag; commit the final value on release, keyboard step, or a short debounce. Coalesce writes per key and reload only the changed setting. Count child processes and time to applied value in a drag test. |
| P1 | **CLI results are untyped.** The model merges stdout and stderr, discards exit status, and displays the final text line as `lastMessage`. Settings are parsed from human-readable output and a failed read becomes an empty array. This makes errors and stale state hard to explain. | `Sources/OizysApp/OizysModel.swift:94-125,207-236` | Return exit code, stdout, stderr, timeout, and action ID. Add versioned JSON for `status`, `config list`, and `ports`; keep the human CLI intact. The UI should retain its last known values and show a specific read or write error. |
| P1 | **Calibration transport is less robust than its description.** The session describes a single-use URL, but `used` is never read or set. The listener accepts any path with the token prefix, reads the HTTP request only once, and does not verify reading order or finite channel values before recording them. The Mac-side solver runs synchronously on the UI thread. | `Sources/OizysApp/CalibrationSession.swift:23-25,50-58,130-202,258-286` | Exact-match the two routes, bound and assemble the complete HTTP body, enforce one active session and sequential readings, reject nonfinite/out-of-range values, and move the solver off the main thread. Add transport tests with fragmented requests, duplicate and reordered posts, and timeout/cancel. Do not tell users to trust a certificate warning as a long-term onboarding pattern without testing the phone flow. |
| P1 | **Sidecar tint does not restore the prior transfer table.** `clear` writes an identity formula while its comment promises to restore what macOS had. It could remove an existing display adjustment. | `Sources/OizysApp/DisplayTint.swift:56-68` | Capture the original transfer table before the first change and restore it on clear, detach, and quit, or remove this control if faithful restoration is unavailable. Verify with a nonidentity starting ramp. |
| P2 | **The interface foregrounds inventory and explanations over actions.** The 330-point popover lists all displays but provides no quick per-head brightness or direct repair step. The full window mixes routine controls with advanced raw settings, and power and colour begin with long prose. The preview shows this density clearly. | `Sources/OizysApp/OizysPanels.swift:9-95,136-205,512-579,760-836,862-898`; `build/audit-ui-2026-09-26/` | Make connection state and next action the first block. Put the two Oizys head controls immediately below. Move long explanations behind "Why?" and raw keys into Advanced. Validate the redesigned preview at 330 points and the minimum window size. |
| P2 | **The display labels are unstable and unclear.** "Oizys head 21" is derived from `CGDirectDisplayID % 100`, an OS identifier rather than a desk position or monitor name. | `Sources/OizysApp/OizysModel.swift:11-44` | Label by stable head selector and user-facing position, such as "Left dock display" and "Right dock display". Use EDID names when reliable and allow a local rename. Never use transient display IDs as names. |
| P2 | **UI behavior has no focused automated gate.** The preview renderer checks visual output with fixed sample data, while the Xcode suite delegates to the Python core suite. Neither checks keyboard paths, error states, or VoiceOver labels. | `Sources/OizysApp/PreviewRender.swift:1-109`; `Tests/Xcode/SuiteTests.swift` | Add a small set of interaction tests for setup, failed write, recovery, and keyboard navigation. Keep preview snapshots for layout review rather than treating them as interaction proof. |
| P2 | **Documentation has drifted.** The routing section says the Swift app does not expose monitor settings, while current panels expose resolution, brightness, position, and mirroring. | `README.md:432-449`; `Sources/OizysApp/OizysPanels.swift:258-415` | Update capability tables when the current interface settles, and distinguish dock heads from native and Sidecar displays. |

## Complexity audit

The hardware-specific C code earns much of its complexity. The strongest cuts are at product boundaries:

1. `delete:` exclude the dormant DDC tunnel from the production target until its dock I2C opcode and an actual transport are known. Its only installer in this repository is a self-test; the file is 261 lines plus a public header. Keep the research branch or tests if this is active protocol work. `Sources/OizysCore/ddc_tunnel.c:6-16,193-259`.
2. `shrink:` replace repeated UI calls to `config set` plus full `config list` and `ports` reload with a coalesced write and one targeted refresh. This removes duplicated orchestration and makes the interface respond at the rate people can see. `Sources/OizysApp/OizysModel.swift:116-153`.
3. `shrink:` keep the generated Xcode project and existing Python tooling, but avoid creating another app layer, state framework, or generalized hardware abstraction for one known dock. `Tools/make_xcodeproj.py` already keeps build policy in one place.

Possible shipping-target cut: about 260 dormant C lines and no new dependency. Repository deletion should wait until the DDC work is explicitly abandoned. There is no evidence for replacing ScreenCaptureKit, the C encoder, or the recovery supervisor.

## Product priorities

| Order | User problem | Smallest useful feature | Success signal |
| --- | --- | --- | --- |
| 1 | The dock is plugged in but screens are dark | Connection timeline with the current blocker and one next step: grant permission, inspect cable/USB speed, retry, or export a report | A user can identify the blocker from the app without reading a service log. |
| 2 | A display disappears or a recovery moves windows | Stable head identity, bounded recovery status, layout restoration, and a manual "Retry connection" action | Reconnect and crash tests restore two visible heads and the prior layout within a stated target. |
| 3 | Everyday brightness takes too many clicks | Two head sliders in the popover, with truthful "picture brightness" wording and a reset to 100% | A brightness change reaches the selected panel once per completed action. |
| 4 | Standby and power settings are hard to choose | Presets named "Keep this display awake" and "Let it blank when idle" with per-head scope | Users can change one monitor without affecting the other and understand which timer they changed. |
| 5 | Calibration is fragile and conceptually dense | A guided comparison flow with eligibility, progress, cancel, and undo | Fragmented phone requests and cancel/retry pass; a stored correction can be undone safely. |
| 6 | Raw config is too exposed | Advanced settings with search, current/default value, validation, and per-key reset | Invalid or failed writes leave the displayed value and error state accurate. |

Avoid adding generic multi-dock support, AI suggestions, dashboards, account features, cloud sync, or more debug controls until a supported hardware path and user need are demonstrated.

## Redesign direction

Use the supplied "midnight financial editorial" palette as a visual grammar, adapted to a utility that must work at 330 points. The app should feel calm and exact: dark stepped surfaces, thin borders, one blue accent, and readable numerical controls. Use a ridge line only in a welcome or empty state. Do not put landscape photography behind settings or a terminal frame around real controls.

| Role | Proposed use |
| --- | --- |
| Canvas and layers | `#181818` window; `#1f1f1f` cards and inputs; `#262626` hover and selected rows; `#323232` popovers; `#111111` narrow footer wells. Prefer a 1px `#323232` border to shadow. |
| Text | `#eeeeee` primary and `#a4a19b` secondary. Reserve `#5e5d59` and `#4b4b4b` for disabled text and separators. Calculated contrast against `#1f1f1f` is about 14.2:1 for Bone, 6.4:1 for Fog, and only 2.5:1 for Smoke. |
| Accent | `#2b7fff` for focus, links on the main canvas, and active controls. Its contrast on `#262626` is about 4.0:1, so use a lighter blue variant such as `#438eff` for small link text on raised surfaces. Never encode health through hue alone. |
| Type | Libre Baskerville regular for one 28-36px page heading, 20-24px in a popover. Inter or the system sans for controls at 14-16px. Fira Code only for identifiers, logs, and raw config. Do not import the reference's 6-10px extracted type into the product; 12px is the metadata floor. |
| Spacing and shape | 4px base grid; 8px within a row, 12-16px card padding, 24-32px section gaps in the app. Buttons and fields 4px radius, cards 8px, onboarding sheet 16px. The reference's 80-224px section gaps belong to marketing pages, not this window. |
| Platform behavior | Keep native SwiftUI controls for keyboard, VoiceOver, focus, and macOS preferences. Honor Increase Contrast and Reduce Transparency. Supply a high-contrast treatment without changing the information hierarchy. |

### Navigation and screen inventory

| Screen | First visible content | Main action | Secondary content |
| --- | --- | --- | --- |
| First run | Supported dock check, Screen Recording state, two physical output checks | "Continue setup" or "Open privacy settings" | Short explanation of what Oizys captures, with local-only diagnostics. |
| Menu bar panel | Precise connection state, last transition, next action | Start/retry/stop as appropriate | Two head brightness controls, "Open displays", and one-line permission or port problem. Move menu-bar preferences to Settings. |
| Overview | Dock and two head cards beside a compact arrangement map | Retry connection or open a head | Recent recovery event and USB link warning. |
| Display detail | Stable name, output state, picture brightness and contrast | Change one control, reset it | Keep-awake and blanking controls, fixed 1080p explanation. Native monitors get only controls the connection actually supports. |
| Arrangement | Accurate display positions and mirror state | Move, set main, or open macOS Displays | "Restore previous layout" after reconnect. |
| Power | Per-head sleep and keepalive presets | Apply preset | macOS global display sleep as a link, not a misleading per-head switch. |
| Sidecar | Attached/nearby/unsupported state and selected device | Connect/disconnect | Automatic connection rules in a disclosure; mark private API dependence plainly. |
| Colour | Eligibility, visual steps, progress, result, undo | Start/continue/cancel | Measurement limitations in a short details disclosure. Phone page uses the same palette and large controls. |
| Diagnostics | Current blocker, last events, both head states | Export privacy-reviewed report | USB ports and advanced raw log/details. |
| Settings | Start at login, appearance, announcements | Save each setting | Searchable advanced driver keys, each with default and reset. |

### Key states and interaction rules

The top status line must name the *observed* state. "Connected" means both virtual heads online and frames accepted; "Picture confirmed" requires the person's explicit check. "Recovering" displays elapsed time and the last step. "Needs Screen Recording" takes the user to the exact System Settings pane. "Dock not found" offers a USB cable/port check. If only one head is online, the app identifies which side and offers a bounded retry. The menu icon receives an accessible state label and never signals success through a coloured dot alone.

For display controls, show a live local number while dragging, write on commit, then show "Applied" or a specific failure. Keep the prior value available for undo. Any setting that can blank or rearrange a screen gets a short reversible confirmation period. Keep fixed dock resolution visible as information, not a disabled picker that looks broken.

The information architecture should use **Overview, Displays, Arrangement, Colour, Diagnostics, Settings**. Power sits inside each display and as a compact shared screen. Sidecar can be a device section within Displays. "How it works" belongs in Help. This reduces eight peer navigation items without removing controls.

### Compact wireframe

```text
OIZYS                                      [Open]
Two displays online                       12:42
Dock connected at 5 Gb/s                 [Details]
────────────────────────────────────────────────
LEFT DISPLAY                     Online  1080p60
Picture brightness               [────●──] 72%
RIGHT DISPLAY                    Online  1080p60
Picture brightness               [──────●] 100%
────────────────────────────────────────────────
[Display settings]              [Stop driver]
```

In failure states, the two sliders give way to a concise problem card with one next action. The full window uses a 200-point sidebar and a content column that can grow, with no nested table clipped at the minimum width.

## Delivery order and acceptance

1. **Status contract and recovery.** Add typed status output, map failure reasons, and test all transitions. Establish a physical reconnect baseline first. Done when UI text agrees with supervisor, virtual head, and permission states in scripted and dock tests.
2. **Responsiveness and settings.** Move slow reads off the main thread, coalesce writes, stop repeated tint applications, and surface exit codes. Done when a slider drag produces one final write, popover input stays responsive during slow commands, and failed writes show the old value plus an error.
3. **Calibration and display safety.** Tighten the LAN protocol and solver lifecycle; preserve display transfer state; test cancel/undo and request fragmentation. Done when invalid/replayed readings cannot advance a session and a prior gamma ramp survives a round trip.
4. **Native redesign.** Introduce semantic design tokens, reorganize the navigation, then build the menu panel and Overview before secondary screens. Keep controls native. Done when all states render at 330-point popover width and the minimum window, keyboard and VoiceOver tasks succeed, and no primary text uses Smoke contrast.
5. **Release and performance gates.** Sign and notarize public artifacts; test clean install/update. Repeat the documented scrolling comparison on the current build and measure idle CPU, energy, and recovery separately. Aim first for no regression in visible output or recovery, then a measured driver CPU reduction from the dated 92.7% baseline. Do not infer panel latency from capture-to-USB processing time.

The minimum physical acceptance matrix is cold attach, unplug/replug, worker kill, sleep/wake, lock/unlock, one HDMI head removed and restored, permission revoked/regranted, and a long unattended session. For each case record both panels' visible image, mode, arrangement, window positions, recovery time, and logs. CI can keep its existing software gates, but hardware acceptance remains a human-observed gate.
