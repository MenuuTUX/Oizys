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

The whole loop runs: Colour → Start puts a QR code on screen, the phone opens the capture
page over TLS, Oizys shows eight grey patches per monitor, and the readings are fitted,
solved and stored. A running driver picks the result up within a second.

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

Oizys serves the capture page itself and shows a QR code containing its URL. There is one
real obstacle, and it has one workaround.

**`getUserMedia` requires a secure context.** Safari grants camera access on HTTPS and on
localhost, and nowhere else. A page served over plain HTTP at `http://192.168.1.x:8443` will
be refused the camera with no useful error. So the server has to speak TLS with a
self-signed certificate, and the phone gets a "connection is not private" warning to tap
through once. Camera access does work after that.

That interstitial is the cost of not installing anything, and it should be named on the
screen showing the QR code rather than left as a surprise.

The alternatives were considered and are worse. A trusted certificate needs a public domain
and a real CA, so the calibration flow would depend on the internet. A native app is an
install. AirPlay carries pixels one way and returns no camera. Tapping through one warning is
the least bad of these.

### Rules for the server

It listens on the LAN and accepts image data, so it is built to be boring:

- Off unless calibration is actually running, and it stops when the sheet closes.
- Bound to one interface, never `0.0.0.0`.
- A single-use token in the QR URL, expiring after two minutes. A second request with the
  same token is refused.
- Frames are reduced to nine mean values in memory and discarded. Nothing is written to disk,
  and no image leaves the machine.
- One route, `POST /reading`, taking numbers. It never serves a file path.

## The flow, end to end

1. Menu bar, Displays, Calibrate. Oizys picks a reference — the dimmest display, or one the
   user chooses — and starts the server.
2. A QR code appears on the built-in display, with the certificate warning explained beside it.
3. The phone opens the page, taps through once, grants the camera.
4. For each display in turn: the page says which one to point at, Oizys shows the ramp, the
   page reports eight readings.
5. Oizys fits each display, solves each against the reference, and shows the result as a
   before-and-after split on each panel.
6. Keep, or discard. Discarding restores identity, which is what shipped.

## What this will not do

- No absolute colour, no Delta-E figure, no claim of accuracy against a standard. There is no
  reference in the loop, so there is no scale to be accurate against.
- Nothing about a panel's white point in isolation. Only about the difference between panels.
- Nothing about a display the camera cannot see at the same sitting.
- No fix for a panel that cannot reach the reference. It is reported, not silently clipped.
