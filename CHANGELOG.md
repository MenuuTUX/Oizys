# Changelog

## Unreleased

Both physical panels now render a live desktop, and the login service brings them up
without help. Six faults stood between the driver and a picture, and not one produced a
failed write, a rejected frame or an error reply; each was visible only in the dock's own
firmware trace and on the glass.

- Send the head at `off23` of the sink engage `0x16/0x23` instead of a second copy of the
  DDC selector. Without it the dock accepted the command, did nothing with it, and never
  allocated a buffer for the mode that followed, so the panel stayed dark.
- Send the mode's line count at `off23` of `0x48/0x22` and the head at `off22`. `off23` is
  not a head number: the dock reads 0 as 720 lines, 1 as 1440 and 2 as the 1080 the timing
  asks for. A head index there sized the buffer 2/3 or 4/3 wrong.
- Wrap the frame trailer's phase on `dock.buffers`, which was declared and never read, in
  place of a hardcoded 3. The dock has two, so the phase ran past the last buffer and it
  stopped flipping, holding the armed frame while discarding the rest.
- Ask for Screen Recording when the preflight fails instead of retrying in silence forever.
- Run the driver's supervisor from the login agent rather than the app wrapper, whose
  preflight cannot pass under launchd for an ad-hoc signed bundle.
- Log the dock's firmware trace without discarding bytes below `0x20`, which had been
  running its fields together and hiding the arguments that identified all of the above.
- Add a full-screen terminal UI, an ASCII logo generator, and `.dmg` packaging.
- Apply head brightness and contrast to the pixels, composed into the same per-channel
  lookup as the calibration, instead of scaling and lifting the encoded planes afterwards.
  The two agree until a value leaves 0..255; past that, clamping planes clips a channel
  difference and a luma independently of each other, which is not any RGB triple, and the
  dock reconstructed blocks of wrong colour from it.
- Invalidate a head's cached strip bodies when its brightness, contrast or calibration
  changes. The cache is keyed on source pixels, which do not move when a setting does, so a
  new brightness used to reach only the tiles that happened to change under it.
- Present the last captured frame again when those settings change. ScreenCaptureKit
  delivers nothing at all on a still desktop, so a change made while nothing was moving
  waited for something to move.
- Restore the arrangement and seat the heads in one display transaction, and debounce the
  reconfiguration callback into a single settle per burst. Each commit is a mode set and
  each mode set blanks the desk; booting with the dock attached had dozens of callbacks each
  scheduling their own restore and arrange, so the driver was flickering at itself.
- Do everything System Settings > Displays does that has a public route, in the Displays
  panel: resolution, refresh rate, main display, mirroring and relative placement. Name the
  four that have no route rather than offering controls that do nothing.
- Own the switch for Control Center's Screen Mirroring module in the Oizys menu, and stop
  writing that preference on first run. The preference hides the module; it does nothing to
  the purple indicator macOS shows while an iPad or AirPlay display is attached, so writing
  it changed a system setting nobody asked to change and removed no icon. That indicator and
  the screen-recording one both belong to macOS and neither has a supported switch; the same
  section now says which is which, what Oizys captures, and what makes each of them leave.
- Cut the menu-bar item from `Logo.png` and the panel header from `tiny_Logo.png`, which is
  the way round that works: white stipple on black is what a template mask wants.

- Use `Oizys.png` for repository branding and native macOS app icons.
- Measure Python tools and separately compiled native tests alongside instrumented
  production, debug, CLI, and developer executables. Keep untested code in the denominator.
- Add a strict project coverage check and reject invalid coverage thresholds.
- Load the requested library configuration in normal test runs and fail builds by exit status.
- Remove temporary configuration directories when tests exit. Keep production logging
  arguments type-checked without evaluating them or emitting log calls.
- Test installation replacement/rollback, build policy validation, icon packaging, CLI
  validation, and native diagnostic exports.
- Update contributor guidance and document coverage and hardware-validation limitations.

## 0.3.0

Current source version. Includes the Oizys rename, production/debug workflows, and the
Ridge per-head mode-addressing fixes in commit `6d975ad`. See
[the protocol notes](Documentation/Protocol.md) for the wire-format corrections.
