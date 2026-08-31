# Xcode workflows

Open `Oizys.xcodeproj`, or run `./dev.sh xcode` to regenerate it first. The generator
preserves user schemes, workspace state and breakpoints. Add source files under the
existing source directories, then regenerate. App, CLI, library, developer tools and
test sources are visible in the project navigator.

| Scheme | Run | Profile / Archive |
| --- | --- | --- |
| `Oizys-production` | Quiet production listener | Optimized production app |
| `Oizys-production-fallback` | Production with vendor recovery | Same production identity, fallback enabled |
| `Oizys-debug` | Developer GUI, minimal logging | Optimized developer GUI |
| `Oizys-debug-verbose` | Developer GUI, verbose logging | Optimized verbose GUI |
| `Oizys-debug-fallback` | Developer GUI with vendor recovery | Optimized fallback GUI |
| `oizys` | Read-only monitor listing | Profile configuration of the CLI |
| `oizys-profile` | Encoder zone profiler | Encoder profiler |
| `oizys-live-profile` | Foreground USB supervisor with capture statistics | Live USB capture; claims the dock |
| `OizysCoreDylib` | Library for the suites; not a runnable app | Library build |

`OizysApp` is a native application target and embeds the `oizys` target's executable.
`OizysTests` is a native XCTest bundle depending on `OizysCoreDylib`. Build settings live
in `Configs/*.xcconfig`. Command-line packaging builds these same native targets; it
does not maintain a second Swift compiler invocation for the app.

Use Command-R for Run, Command-I for Instruments, Shift-Command-B for Analyze and
Product → Archive for an Xcode archive. Production and debug app schemes preserve
their selected policy for Profile and Archive. Production Profile configurations allow
local debugger attachment; normal production builds and archives do not. Optimized configurations keep frame
pointers and dSYM files. App archives are build artifacts, not debug installers;
`./dev.sh build debug-minimal` creates the portable distribution executable.

The debugger can stop at Swift UI/lifecycle code and C CLI/core code. Capture executes
in the app's `OizysDriver` child, so attach LLDB or Instruments to that process when
investigating capture, encoding or USB. GUI profiling alone does not include child
process CPU. For direct driver profiling, stop production with `oizys service stop`,
use `oizys-live-profile`, then restore it with `oizys service start`.

Run `./dev.sh setup` before Command-U. The XCTest bridge invokes the existing Python
suites against the configuration's `libOizysCore.dylib`, records failures in the Test
navigator and attaches the full output to the xcresult. Tests never require running
the GUI. For detailed source coverage, use `./dev.sh coverage`; Xcode's scheme coverage
option also instruments builds, but Python subprocess and mocked-library coverage
must not be mistaken for coverage of the whole driver.

For Address, Undefined Behavior and Thread Sanitizer workflows, use the corresponding
developer menu entries or `./dev.sh sanitize address|undefined|thread`. Xcode scheme
diagnostic options are available for native runs. Apple's Python process can reject
injected sanitizer runtimes; `Tools/test.py` handles that restriction with a native
runner. Enable Main Thread Checker or other GUI diagnostics in Edit Scheme → Run →
Diagnostics when needed. Instruments' Time Profiler, Allocations and System Trace can
attach to the appropriate app or driver process. Nothing records automatically.

Build without executing anything:

```bash
xcodebuild -project Oizys.xcodeproj -scheme Oizys-production -configuration Production build
xcodebuild -project Oizys.xcodeproj -scheme Oizys-debug -configuration DebugMinimal build
xcodebuild -project Oizys.xcodeproj -scheme oizys -configuration Debug build-for-testing
```

Privacy approval remains a macOS operation. Production login launches through
LaunchServices without activating a window. Debug sessions have their own app identity
and may need separate Screen Recording access. Re-signing an ad-hoc build can change
its privacy authorization. Before a debug app requests missing Screen Recording access,
it resets only registered Oizys debug identities for Screen Recording, including stale
copies of its own identity. It preserves valid access and never resets production or
unrelated apps. If cleanup fails, it reports the failure before requesting access.
A signed, notarized distribution needs the developer's signing credentials.

Quitting the debug app restores installed production and resets Screen Recording for
that debug variant only. Another running copy of the same variant keeps its shared
permission until it quits. Each new debug session may therefore need approval again.
Use macOS's **Quit & Reopen** button when granting permission: that system relaunch
preserves the pending grant. The debug app's own **Quit** command ends the session
and removes its permission. Force-killing an Xcode process cannot run app quit cleanup.

## Testing edits while production is installed

Run `./dev.sh setup` once, then `./dev.sh debug`. This rebuilds the minimal debug
variant from your checkout and opens its GUI while installed production keeps running.
Repeating the command closes the previous instance of that debug variant and its tests,
rebuilds it, and opens the new version. This also handles an instance started in Xcode.
If debug owned the adapter, production resumes before the rebuild. Settings and privacy
permissions are not reset by the build command. Build-only commands still require you
to close a running app whose bundle they would replace.
Use `./dev.sh debug debug-verbose` for detailed logs or `./dev.sh debug debug-fallback`
for fallback code. With DisplayLink uninstalled, fallback has no vendor app to launch.
`./dev.sh build-debug-all` builds every debug variant without installing or launching it.

Run software tests, benchmarks and visual workloads while production remains active.
To test capture or USB changes, click **Start debug driver**. Production pauses because
two drivers cannot own the same adapter. Click **Stop debug and restore production**
when finished. Closing the app also restores production; closing just a window does
not quit the app. Another debug session cannot take the dock while one already owns it.

Each debug variant has separate configuration and logs under
`~/Library/Application Support/Oizys/Debug/<variant>/`. Its initial configuration uses
built-in defaults. Production keeps `~/Library/Application Support/Oizys/config.json`.
An explicit `OIZYS_CONFIG_PATH` override still takes precedence for automated tests.

Xcode's three debug app schemes use the same handoff. After a forced debugger stop,
run `oizys service recover-debug` if production has not resumed. Give the debug app its
own Screen Recording permission when macOS requests it.

When the edit is ready, quit debug and run `./dev.sh test`, then
`./dev.sh install production`. Installation is the only step that replaces the main app.
