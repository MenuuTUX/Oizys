#include "oizys_ports.h"
#include "oizys_dl3.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

#include <inttypes.h>
#include <string.h>

static uint64_t cf_u64(CFTypeRef value) {
    uint64_t out = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt64Type, &out);
    }
    return out;
}

static uint64_t property_u64(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    uint64_t out = cf_u64(value);
    if (value) CFRelease(value);
    return out;
}

static void property_string(io_service_t service, CFStringRef key, char *out, size_t capacity) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString(value, out, (CFIndex)capacity, kCFStringEncodingUTF8);
    }
    if (value) CFRelease(value);
}

/*
 * A branch's power allocation and port limit are published on the controller or hub the
 * device hangs off, not on the device. Walk up until one appears so every row can name the
 * budget it is actually sharing.
 */
static uint64_t inherited(io_service_t service, CFStringRef key) {
    io_service_t cursor = service;
    IOObjectRetain(cursor);
    for (int step = 0; step < 8 && cursor; step++) {
        uint64_t value = property_u64(cursor, key);
        if (value) { IOObjectRelease(cursor); return value; }
        io_service_t parent = 0;
        kern_return_t status = IORegistryEntryGetParentEntry(cursor, kIOServicePlane, &parent);
        IOObjectRelease(cursor);
        if (status != KERN_SUCCESS) return 0;
        cursor = parent;
    }
    if (cursor) IOObjectRelease(cursor);
    return 0;
}

static void visit(io_service_t service, int depth, OizysPort *ports, int max, int *count) {
    if (*count >= max) return;
    io_name_t class_name = {0};
    int is_device = IOObjectGetClass(service, class_name) == KERN_SUCCESS &&
                    strcmp(class_name, "IOUSBHostDevice") == 0;
    if (is_device) {
        OizysPort *port = &ports[(*count)++];
        memset(port, 0, sizeof(*port));
        port->depth = depth;
        io_name_t name = {0};
        if (IORegistryEntryGetName(service, name) == KERN_SUCCESS) {
            snprintf(port->name, sizeof(port->name), "%s", name);
        }
        property_string(service, CFSTR("USB Product Name"), port->name, sizeof(port->name));
        property_string(service, CFSTR("USB Vendor Name"), port->vendor, sizeof(port->vendor));
        port->vid = (uint16_t)property_u64(service, CFSTR("idVendor"));
        port->pid = (uint16_t)property_u64(service, CFSTR("idProduct"));
        port->location_id = (uint32_t)property_u64(service, CFSTR("locationID"));
        port->bcd_usb = (uint16_t)property_u64(service, CFSTR("bcdUSB"));
        port->speed_code = (int)property_u64(service, CFSTR("Device Speed"));
        port->link_bps = property_u64(service, CFSTR("UsbLinkSpeed"));
        port->sink_ma = (uint32_t)inherited(service, CFSTR("UsbPowerSinkAllocation"));
        port->port_limit_ma = (uint32_t)inherited(service, CFSTR("kUSBWakePortCurrentLimit"));
        depth++;
    }
    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(service, kIOUSBPlane, &children) != KERN_SUCCESS) return;
    io_service_t child;
    while ((child = IOIteratorNext(children))) {
        visit(child, depth, ports, max, count);
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
}

int oizys_ports_scan(OizysPort *ports, int max) {
    if (!ports || max <= 0) return 0;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return 0;
    int count = 0;
    visit(root, 0, ports, max, &count);
    IOObjectRelease(root);
    return count;
}

uint64_t oizys_port_capable_bps(uint16_t bcd_usb) {
    if (bcd_usb >= 0x0310) return 10000000000ull; /* USB 3.1 Gen 2 and later */
    if (bcd_usb >= 0x0300) return 5000000000ull;  /* USB 3.0 / 3.1 Gen 1 */
    if (bcd_usb >= 0x0200) return 480000000ull;   /* USB 2.0 High Speed */
    if (bcd_usb >= 0x0110) return 12000000ull;    /* USB 1.1 Full Speed */
    return 0;
}

const char *oizys_port_verdict(const OizysPort *port) {
    if (!port || !port->link_bps || !port->bcd_usb) return NULL;
    if (port->bcd_usb >= 0x0300 && port->link_bps <= 480000000ull) {
        return "declares SuperSpeed but negotiated USB 2.0. Its SuperSpeed pairs are not "
               "connected: try the other end of the cable, a cable rated for USB 3, or another port.";
    }
    if (port->bcd_usb >= 0x0200 && port->link_bps < 480000000ull) {
        return "declares USB 2.0 but negotiated Full Speed, which is 40x slower. This is "
               "usually a damaged cable or a failing port.";
    }
    return NULL;
}

const char *oizys_port_rate(uint64_t bps, char *out, size_t capacity) {
    if (!bps) snprintf(out, capacity, "unreported");
    else if (bps >= 1000000000ull) snprintf(out, capacity, "%.4g Gb/s", (double)bps / 1e9);
    else snprintf(out, capacity, "%.4g Mb/s", (double)bps / 1e6);
    return out;
}

void oizys_ports_print(const OizysPort *ports, int count, FILE *out) {
    /* Narrow enough to fit the menu's panel without reflowing. A fixed-width table that
     * wraps loses the column alignment that carries its meaning. */
    fputs("Device                     VID:PID    Declares  Actual    Budget\n", out);
    for (int i = 0; i < count; i++) {
        const OizysPort *port = &ports[i];
        char rate[32], capable[32];
        oizys_port_rate(port->link_bps, rate, sizeof(rate));
        oizys_port_rate(oizys_port_capable_bps(port->bcd_usb), capable, sizeof(capable));
        char budget[48] = "-";
        if (port->sink_ma) {
            snprintf(budget, sizeof(budget), "%u mA", port->sink_ma);
        }
        fprintf(out, "%*s%-*s %04x:%04x  %-9s %-9s %s\n", port->depth * 2, "",
                25 - port->depth * 2, port->name[0] ? port->name : "(unnamed)",
                port->vid, port->pid, capable, rate, budget);
        const char *verdict = oizys_port_verdict(port);
        if (verdict) fprintf(out, "%*s  ! %s\n", port->depth * 2, "", verdict);
    }
    if (!count) fputs("No USB devices are attached.\n", out);
    fputs("\nActual is the link rate this device negotiated; Declares is the fastest its own\n"
          "USB revision allows. A hub's rate is shared by everything below it.\n"
          "Branch budget is the current macOS allocated upstream. A powered dock supplies its own\n"
          "downstream ports from its adapter, and macOS is not told what it offers on them: no\n"
          "software on this Mac can read or raise a dock port's power. See Documentation/Ports.md.\n",
          out);
}

/*
 * assert() compiles out under NDEBUG, so a selftest built on it passes silently in exactly
 * the build people run. Same CHECK convention as config.c: count failures, report the first
 * line of each, keep going.
 */
static int g_failures;
#define CHECK(condition)                                                      \
    do {                                                                      \
        if (!(condition)) {                                                   \
            g_failures++;                                                     \
            fprintf(stderr, "ports selftest: %s:%d %s\n", __FILE__, __LINE__, \
                    #condition);                                              \
        }                                                                     \
    } while (0)

int oizys_ports_selftest(void) {
    g_failures = 0;
    char text[32];

    CHECK(oizys_port_capable_bps(0x0320) == 10000000000ull);
    CHECK(oizys_port_capable_bps(0x0300) == 5000000000ull);
    CHECK(oizys_port_capable_bps(0x0200) == 480000000ull);
    CHECK(oizys_port_capable_bps(0x0110) == 12000000ull);
    CHECK(oizys_port_capable_bps(0x0000) == 0);

    CHECK(strcmp(oizys_port_rate(5000000000ull, text, sizeof(text)), "5 Gb/s") == 0);
    CHECK(strcmp(oizys_port_rate(480000000ull, text, sizeof(text)), "480 Mb/s") == 0);
    CHECK(strcmp(oizys_port_rate(0, text, sizeof(text)), "unreported") == 0);

    /* A USB 2.0 hub at 480 Mb/s is at its own maximum and must never be flagged. */
    OizysPort fine = {.bcd_usb = 0x0200, .link_bps = 480000000ull};
    CHECK(oizys_port_verdict(&fine) == NULL);
    /* Nor is 5 Gb/s on a 3.2 device a provable fault: bcdUSB does not promise Gen 2. */
    OizysPort gen1 = {.bcd_usb = 0x0320, .link_bps = 5000000000ull};
    CHECK(oizys_port_verdict(&gen1) == NULL);
    /* Losing SuperSpeed entirely is provable, and is the common bad-cable symptom. */
    OizysPort dropped = {.bcd_usb = 0x0320, .link_bps = 480000000ull};
    CHECK(oizys_port_verdict(&dropped) != NULL);
    OizysPort slow = {.bcd_usb = 0x0200, .link_bps = 12000000ull};
    CHECK(oizys_port_verdict(&slow) != NULL);
    /* An unreported rate is unknown, not a fault. */
    OizysPort quiet = {.bcd_usb = 0x0320, .link_bps = 0};
    CHECK(oizys_port_verdict(&quiet) == NULL);

    /* Encoder gain: unity by default, clamped both ways, and restored so a self-test never
     * leaves the encoder dimmed for whatever runs next. */
    int restore = oizys_video_gain();
    CHECK(restore == 256);
    oizys_video_set_gain(-5);
    CHECK(oizys_video_gain() == 0);
    oizys_video_set_gain(4096);
    CHECK(oizys_video_gain() == 256);
    oizys_video_set_gain(128);
    CHECK(oizys_video_gain() == 128);
    oizys_video_set_gain(restore);
    CHECK(oizys_video_gain() == 256);
    return g_failures;
}
