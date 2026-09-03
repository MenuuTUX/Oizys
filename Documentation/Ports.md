# Dock ports: what the host can see, and what it cannot

`oizys ports` walks the IOUSB plane and reports, for every attached device, the link rate it
negotiated next to the fastest rate its own declared USB revision allows. It is read-only and
needs no takeover, so it can be run while the driver is serving.

```sh
oizys ports
```

## Measured topology on the ACASIS DS-0602, 2026-09-01

```
Device                     VID:PID    Declares  Actual    Budget
USB Hub                   1a86:8095  480 Mb/s  480 Mb/s  -
USB TO DP HDMI            17e9:6000  10 Gb/s   5 Gb/s    504 mA
```

The dock presents two independent devices to the Mac rather than one tree:

- `17e9:6000`, the Ridge video device, on its own SuperSpeed link at 5 Gb/s. Every encoded
  frame Oizys sends rides this and nothing else.
- `1a86:8095`, a USB 2.0 hub, at 480 Mb/s. The dock's downstream data ports hang off this.

The two do not share bandwidth. A flash drive copying at full speed on a USB-A port cannot
slow the video link, and vice versa.

## Are the ports running at their maximum rate?

The USB 2.0 ports are. 480 Mb/s *is* USB 2.0's signalling rate; there is no faster mode for
a port to fall back from, and no setting anywhere in macOS, the driver or the dock can raise
it. A USB 2.0 port reading 480 Mb/s is a port working correctly.

The video link reads 5 Gb/s against a declared 10 Gb/s, and `oizys ports` deliberately does
not flag that. A `bcdUSB` of `0x0320` records which revision of the specification a device was
written against, not which signalling rate its silicon implements, so a Gen 1 device in a
Gen 2 chassis reports exactly this. Calling it a fault would be a guess.

What the tool does flag is the unambiguous case: a device that declares SuperSpeed and
negotiated 480 Mb/s. That means the SuperSpeed pairs never came up, which is nearly always
the cable, and it is worth fixing because it costs a factor of ten.

Plug a device into each port in turn and re-run `oizys ports` to see which internal hub that
port belongs to and what it negotiated. Ports that are physically USB-C are not necessarily
faster than the USB-A ports beside them; on this dock the downstream data path is the USB 2.0
hub above, whatever shape the connector is.

## Why an iPad discharges while it is being used as a display

This one is not fixable in software, and it is worth being exact about why.

A dock's downstream port power is negotiated between the dock's own power controller and the
attached device. The host is not a party to that conversation and is never told its outcome.
`UsbPowerSinkAllocation`, the only current figure macOS publishes, describes what the Mac
allocated on its own upstream port; it says nothing about what the dock offers downstream. No
API on macOS reads a dock's downstream contract, and none sets it. Any tool claiming to raise
a dock port's output is changing something else.

The arithmetic is the whole explanation. A downstream USB-C data port on a DisplayLink dock
typically offers 5 V at 1.5 A or 3 A, so 7.5 W to 15 W, and the dock divides one adapter
between every port and both video outputs. An iPad running as a Sidecar display is close to
its worst case: panel at working brightness, radios up, SoC compositing a second desktop.
Draw exceeds supply, and the difference comes out of the battery. The battery percentage falls
while the cable is plugged in and delivering everything it has.

### Measured on this machine, 2026-09-01

With an iPad actively serving as a Sidecar display, `oizys ports` showed only two USB
devices: the dock and its hub. No Apple device was enumerated anywhere in the tree.

That is worth stopping on, because it rules out the explanation above for this setup. The
iPad is not on USB, so whatever it is doing, it is not drawing from a dock data port. The
Sidecar session is running over Wi-Fi.

Two things follow. Wireless Sidecar is the more expensive mode — panel, compositing and the
radios, with nothing coming back down a cable — so the battery drains faster than it would
wired. And if the iPad *is* physically plugged into the dock while showing no USB device,
the cable or the port is carrying power without data: a charge-only cable, or a port wired
for power alone. Either way it will not appear here, and its delivery cannot be measured.

Plug the iPad in with a cable known to carry data and re-run `oizys ports`. If it appears,
the link speed and the branch it sits on become visible. If it still does not appear, the
cable is the thing to replace.

Three things actually change the outcome, none of them software:

1. Charge the iPad from its own power adapter and keep the dock port for data. This is the
   only option that reliably gains ground during use.
2. Move it to the dock's high-power port if the dock designates one. On the DS-0602 the
   upstream USB-C port carries power delivery to the host and is not a downstream charger.
3. Lower the draw: reduce iPad brightness, and prefer wired Sidecar over wireless. The
   radios are a real share of the budget, and a wired session removes them.

Wired Sidecar only helps if the cable actually carries data, which on this machine it
currently does not — see the measurement above.

## What `oizys ports` will not tell you

- The dock's downstream power contracts, per the above.
- Per-port current draw. The dock does not report it and macOS does not model it.
- Anything about a device that has not enumerated. A port with no device is not in the tree,
  so a dead port and an empty port look identical.
