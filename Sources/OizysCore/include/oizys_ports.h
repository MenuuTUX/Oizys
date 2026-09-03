#pragma once

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * What macOS can and cannot see about a dock's ports.
 *
 * CAN: the link speed every attached device actually negotiated, the USB revision that
 * device declares, and the current macOS allocated to the branch it sits on.
 *
 * CANNOT: what a dock offers on its own downstream ports. Those contracts are negotiated
 * between the dock's power controller and the attached device; the host is not a party to
 * them and no API reports them. A port that under-powers a device therefore shows up here
 * only as the device's own behaviour, never as a number -- and nothing in software can
 * raise it. See Documentation/Ports.md.
 */

#define OIZYS_MAX_PORTS 64

typedef struct {
    int depth;              /* 0 = host controller's own root port */
    char name[64];
    char vendor[64];
    uint16_t vid, pid;
    uint32_t location_id;
    uint16_t bcd_usb;       /* the USB revision the device declares, BCD */
    int speed_code;         /* IOKit "Device Speed": 0 low .. 4 SuperSpeed+ */
    uint64_t link_bps;      /* negotiated link rate, 0 when not reported */
    uint32_t sink_ma;       /* UsbPowerSinkAllocation on this branch, 0 when absent */
    uint32_t port_limit_ma; /* kUSBWakePortCurrentLimit, 0 when absent */
} OizysPort;

/* Every USB device in the IOUSB plane, parents before children. Returns the count. */
int oizys_ports_scan(OizysPort *ports, int max);

/* The fastest rate this device's declared USB revision allows, in bits per second. */
uint64_t oizys_port_capable_bps(uint16_t bcd_usb);

/*
 * A short explanation when this device is demonstrably not running at its own best rate,
 * NULL when it is. Only unambiguous downgrades are named: a device that declares
 * SuperSpeed and got High Speed has lost its SuperSpeed pairs outright, and one that
 * declares USB 2.0 and got Full Speed has lost High Speed the same way. A SuperSpeed
 * device at 5 Gb/s is NOT flagged: a bcdUSB of 0x0320 does not promise Gen 2, so calling
 * that a fault would be a guess.
 */
const char *oizys_port_verdict(const OizysPort *port);

/* Human-readable rate, e.g. "5 Gb/s". Writes into `out` and returns it. */
const char *oizys_port_rate(uint64_t bps, char *out, size_t capacity);

/* The tree, one device per line, with a verdict under any device that is downgraded. */
void oizys_ports_print(const OizysPort *ports, int count, FILE *out);

/* Asserts over the rate and verdict rules. Returns 0 when everything holds. */
int oizys_ports_selftest(void);

#ifdef __cplusplus
}
#endif
