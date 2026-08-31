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
