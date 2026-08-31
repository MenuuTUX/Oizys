# Routing investigation, 2026-08-30

The earlier native/USB split investigation is closed for the current setup. Both Dell
HDMI cables stay on the ACASIS adapter, and Oizys is intended to drive both outputs itself.
The user accepts that software cannot create a native GPU route through a USB-only path.

## Measured topology

Read-only checks on this Mac found:

- USB `17e9:6000`, product `USB TO DP HDMI`, at `0x00200000`, using a 5 Gbit/s USB link.
- DisplayLink Manager's agent owns the USB device.
- Both Dell P2219H displays are online at 1920x1080, extended rather than mirrored.
- One `DCPAVServiceProxy`, with `Location = Embedded`. No `External` service exists.
- Neither Thunderbolt bus reports a connected Thunderbolt/USB4 device. This alone does
  not rule out USB-C DP Alt Mode; it is a different connection type.
- Default config remains `heads.active = left,right`, `heads.native = none`.

WindowServer hides the online displays from the Codex sandbox. The display enumeration
was repeated outside the sandbox before recording these results. A missing display list
inside the sandbox is not evidence that a monitor is disconnected.

Reproduce without stopping DisplayLink Manager:

```sh
build/Release/oizys routes
system_profiler SPDisplaysDataType SPThunderboltDataType
ioreg -r -c DCPAVServiceProxy -w0 -l
```

## What the measurements establish

There is no currently verified native external route. The existing Ridge driver sends
encoded pixels to two USB endpoints. Disabling one stream cannot create a native GPU
connection to that output.

The user identified the adapter as the
[ACASIS DS-0602 dual-HDMI DisplayLink adapter](https://www.acasis.com/products/acasis-usb-c-displaylink-dual-4k-60hz-hdmi-adapter-for-apple-mac).
ACASIS lists a DL-6950 controller and dual 4K60 HDMI output through DisplayLink. It does not
advertise an independent DP Alt Mode output on this adapter. Together with the measured
USB topology, this supports treating both HDMI ports as USB graphics outputs. It does not
establish a way to switch either output to the Mac's GPU.

DDC/CI carries monitor settings, such as brightness and input selection. Finding its
USB tunnel would help control the Dells but would not change where their video comes from.
The planned unknown-subopcode sweep was not run during this investigation.

## Code corrections

Native DDC now checks EDID validity and matches vendor, product and serial to exactly one
eligible online display. Missing, corrupt, unmatched or ambiguous EDIDs cannot fall back
to an arbitrary display. Opening a specific display resolves its own matching service.
The layout code uses this verified native identity instead of assuming every non-Apple
external display is native.

DDC reply lengths and checksums are validated before parsing. Capabilities fragments must
echo the requested offset, fit the output buffer and terminate successfully. A settings
write first establishes I2C framing with a read, rather than treating an I2C write completion
as a monitor acknowledgement. None of these changes prove that a real monitor accepts the
native DDC framing; that still requires a native connection and a readback test.

The CLI reports disabled dock heads without claiming they have native video. Explicit
`heads.native` requests must not overlap `heads.active` and must have a verified native
display before takeover. This is a conservative check using the current IOKit backend;
missing private API support can also prevent verification.

## Current work

Oizys drives both outputs using its own protocol and encoder. The motion/reset fixes and
independent session recovery are recorded in [the performance report](Performance-2026-08-30.md).
The Ridge DDC/CI tunnel and native monitor readback testing remain unfinished. A Swift
menu-bar app now provides connection controls, recovery status and permission guidance. The protocol currently sets 1080p60 for the local Dell panels; the adapter's
advertised 4K60 support is not a claim that Oizys implements that mode yet.

The earlier native-DDC tests covered synthetic EDID matching and malformed replies. They
do not prove native DDC on a physical monitor: this setup exposes no native external I2C
service. Live USB tests have since been run, but USB acknowledgements and virtual-display
capture cannot replace the user's confirmation of the actual panel image.
