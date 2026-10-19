# Matching the displays with an iPhone

The goal is narrow and worth stating before anything else: make the monitors and the iPad
look like each other, using a phone that has nothing installed on it. Reached by scanning a
QR code, done in a minute, undoable.

This is not colorimetry. An iPhone camera cannot replace a colorimeter and this design does
not pretend it can. What it can do is compare two things photographed under the same
settings, which is enough to fix the fault people actually notice.

## Status

| Piece | State |
| --- | --- |
| Correction maths and its self-test | built — `Sources/OizysCore/calibrate.c`, `oizys calibrate selftest` |
| Storage, `oizys calibrate show / run / clear` | built |
| Patch presenter, capture page, QR pairing | built — Colour, in the menu bar's window |
| Applying a correction to a head | built — a per-channel lookup in the encoder |

Colour → Start puts a QR code on screen. The capture page sends eight RGB readings per
monitor, which the driver fits and stores. A running driver picks the result up within a
second. Automated tests cover the parser, reading validation, local TLS handshake, IP
certificate validation, token replay, page reload, session shutdown, and certificate renewal.
The camera and certificate confirmation flow still needs testing on a physical iPhone.

## Why absolute measurement is off the table

A web page gets camera frames through `getUserMedia`, and that is all it gets. Safari on iOS
exposes no manual exposure, no white-balance lock, no raw sensor data. Every frame has
already been through auto-exposure, auto white balance and Apple's tone mapping, and those
adjust themselves between shots. A single photograph of a white patch says almost nothing
about that patch's colour, because the camera has already decided what white is.

Ratios survive this. Two patches captured in the same frame, or in consecutive frames with
the scene otherwise unchanged, went through the same pipeline, so their relationship holds
even when neither absolute value does. Everything below is built on ratios only.

## What gets measured

Oizys shows a neutral ramp — eight grey levels — full-screen on one display at a time. The
phone, pointed at that display, reports the mean camera response for each patch. That gives
eight input/output pairs per channel.

Per channel, the display is modelled as `measured = scale × input^exponent`, fitted by least
squares on the logarithms, which is a straight line and needs no solver. Two numbers per
channel, six per display. `oizys_calibration_fit` does this, and its self-test checks that
the fit recovers a response it was generated from.

To match display B to display A, compose the correction with B's own response and solve for
the pair that lands on A:

```
gain     = (scale_A / scale_B) ^ (1 / exponent_B)
exponent = exponent_A / exponent_B
```

Closed form, in the same family, so nothing is inverted numerically. `oizys_calibration_solve`
does this and its self-test verifies the corrected display then measures like the reference.

Gain is clamped at 1. A panel cannot be driven brighter than its own white, and asking clips
highlights rather than matching them, so matching only ever darkens. **Pick the dimmest
display as the reference**, or every other display gets pulled down to meet it.

Six numbers will not reproduce a colorimeter. They correct grey balance and gamma mismatch
between panels, which is the visible fault: one monitor reading blue against the other, or
one showing crushed shadows the other does not.

## Applying it

The two display kinds need different routes, and the Oizys ones get the better one.

**Heads driven over the dock.** Oizys already owns every pixel that reaches these, so the
correction goes in the encoder as a per-channel 256-entry lookup, applied to the pixels
before the colour transform — it has to be before, because the transform's planes are linear
combinations of R, G and B and a per-channel scale does not commute with them.

`head.<side>.brightness` and `head.<side>.contrast` compose into that same table, the
calibration first and the user's own two knobs on top. They were a scale and a lift on the
planes once, which is exact only while nothing clips; on the pixels they clip per channel,
the way a monitor does. A table that changes for either reason invalidates every cached
strip body for that head, because those bodies were encoded through the old one.

The lookup is vectorised. `vqtbl4q_u8` reaches 64 entries and yields zero above that, so four
of them cover 256: each is offset by 64, and the wrap-around puts every index outside its own
quarter above 64 where it reads as zero, leaving exactly one quarter to answer. The tests
cover all four boundaries, and the scalar edge path is checked against the vector one so a
correction cannot stop at the last full strip and leave a seam down the right of the panel.

**Built-in, native and Sidecar displays.** Oizys does not own those pixels, so the
correction has to become an ICC profile: a corrected white point and per-channel TRC written
to `~/Library/ColorSync/Profiles/`, assigned with `ColorSyncDeviceSetCustomProfiles`. Public
API, reversible by removing the profile.

Whether a `CGVirtualDisplay` accepts an assigned ColorSync profile at all is untested here.
It does not matter for the heads, which take the encoder path, and it is the reason that path
is preferred rather than a fallback.

## Getting the phone onto the page

Oizys serves the capture page over HTTPS because `getUserMedia` requires a secure context.
The certificate is self-signed and includes the selected LAN IP address as a Subject
Alternative Name. It is renewed when the address changes or its one-year validity is nearly
over. The Mac shows its SHA-256 fingerprint beside the QR code.

A certificate warning alone does not authenticate the Mac. Compare the phone's certificate
fingerprint before granting camera access. Stop if it differs or Safari cannot display it.
Whether iPhone Safari exposes enough information for this check remains unverified.

The identity is imported into a private keychain for each session. Importing it into the
default keychain can block TLS on private-key authorization after an ad hoc rebuild. The
session keychain trusts the calling app and is deleted on stop or normal app termination.
This uses public deprecated macOS Keychain APIs, contained in `CalibrationSession.swift`.

### Rules for the server

The listener accepts bounded requests containing numbers:

- Off unless calibration is running; it stops when the Colour panel closes, the app quits,
  or the ten-minute session deadline expires.
- Bound to one interface, never `0.0.0.0`.
- A single-use QR token redirects to a separate session token. Reusing the QR token is
  refused; the session page can reload until the session ends.
- The phone reduces each frame to three RGB means and sends those values. Images stay on
  the phone. The solver receives a temporary readings file that is removed after use.
- Exact token-scoped page and reading routes; no file paths are served.
- Headers are limited to 8 KiB and bodies to 4 KiB. Readings must be finite, within 0...1,
  and match the current display and patch. Out-of-order or replayed readings are refused.

## The flow, end to end

1. Open Oizys, choose Colour, and start calibration when both dock displays are forwarding.
2. Scan the QR code and verify the certificate fingerprint against the Mac.
3. Open the capture page and grant camera access.
4. For each display in turn: the page says which one to point at, Oizys shows the ramp, the
   page reports eight readings.
5. Oizys chooses the dimmest measured display as the reference, fits each display, and stores
   corrections for the dock heads. The solver runs outside the UI thread and writes to a
   temporary directory. Only an active session can atomically save that result, so cancelling
   while solving leaves the current correction intact.
6. Review the result on the Mac. Undo last calibration restores the exact previous correction
   file, or removes the new file when there was no correction before. Undo refuses to overwrite
   changes made after calibration. Clear stored correction is available without running a new
   calibration and removes both head corrections together. Undo remains available in the
   current Colour view until another calibration replaces it or the view closes.

## What this will not do

- No absolute colour, no Delta-E figure, no claim of accuracy against a standard. There is no
  reference in the loop, so there is no scale to be accurate against.
- Nothing about a panel's white point in isolation. Only about the difference between panels.
- Nothing about a display the camera cannot see at the same sitting.
- No fix for a panel that cannot reach the reference. It is reported, not silently clipped.
