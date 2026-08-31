#include "oizys_encode.h"
#include "oizys_usb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void cf_cstring(CFTypeRef v, char *out, size_t n) {
    out[0] = 0;
    if (!v || n == 0) {
        return;
    }
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8);
    }
}

static uint32_t cf_u32(CFTypeRef v) {
    uint32_t x = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &x);
    }
    return x;
}

OizysFamily oizys_family_from_platform(const char *name) {
    if (name && strcmp(name, "RidgeDoc") == 0) {
        return OIZYS_FAMILY_RIDGE;
    }
    if (name && strcmp(name, "NavaDock") == 0) {
        return OIZYS_FAMILY_NAVARRO;
    }
    if (name && strcmp(name, "EllaDock") == 0) {
        return OIZYS_FAMILY_ELLA;
    }
    if (name && strcmp(name, "FflyMoni") == 0) {
        return OIZYS_FAMILY_FIREFLY;
    }
    return OIZYS_FAMILY_UNKNOWN;
}

const char *oizys_family_name(OizysFamily family) {
    switch (family) {
    case OIZYS_FAMILY_RIDGE:
        return "Ridge (DL-6xxx)";
    case OIZYS_FAMILY_NAVARRO:
        return "Navarro (DL-7000)";
    case OIZYS_FAMILY_ELLA:
        return "Ella (DL-3/5xxx)";
    case OIZYS_FAMILY_FIREFLY:
        return "Firefly (DL-4xxx)";
    default:
        return "unknown";
    }
}

int oizys_identity_parse(OizysIdentity *id, const uint8_t *bytes, int n) {
    memset(id, 0, sizeof(*id));
    if (n < 16 || bytes[0] < 16 || bytes[1] != OIZYS_IDENT_TYPE) {
        return -1;
    }
    memcpy(id->raw, bytes, 16);
    memcpy(id->firmware, bytes + 2, 6);
    memcpy(id->platform, bytes + 8, 8);
    id->platform[8] = 0;
    id->family = oizys_family_from_platform(id->platform);
    id->valid = 1;
    return 0;
}

static void add_endpoint(OizysInterface *iface, io_service_t pipe) {
    if (iface->ep_count >= OIZYS_MAX_EP) {
        return;
    }
    CFTypeRef addr = IORegistryEntryCreateCFProperty(pipe, CFSTR("bEndpointAddress"),
                                                     kCFAllocatorDefault, 0);
    CFTypeRef attr =
        IORegistryEntryCreateCFProperty(pipe, CFSTR("bmAttributes"), kCFAllocatorDefault, 0);
    CFTypeRef mps =
        IORegistryEntryCreateCFProperty(pipe, CFSTR("wMaxPacketSize"), kCFAllocatorDefault, 0);
    uint8_t a = (uint8_t)cf_u32(addr);
    uint8_t at = (uint8_t)cf_u32(attr);
    OizysEndpoint *e = &iface->ep[iface->ep_count++];
    e->address = a;
    e->dir_in = (a & 0x80) ? 1 : 0;
    e->transfer = at & 0x03;
    e->max_packet = (uint16_t)cf_u32(mps);
    if (addr) {
        CFRelease(addr);
    }
    if (attr) {
        CFRelease(attr);
    }
    if (mps) {
        CFRelease(mps);
    }
}

static void inspect_interface(OizysHub *hub, io_service_t iface) {
    if (hub->iface_count >= OIZYS_MAX_IFACE) {
        return;
    }
    OizysInterface *in = &hub->iface[hub->iface_count];
    memset(in, 0, sizeof(*in));
    CFTypeRef n =
        IORegistryEntryCreateCFProperty(iface, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
    CFTypeRef alt =
        IORegistryEntryCreateCFProperty(iface, CFSTR("bAlternateSetting"), kCFAllocatorDefault, 0);
    CFTypeRef cls =
        IORegistryEntryCreateCFProperty(iface, CFSTR("bInterfaceClass"), kCFAllocatorDefault, 0);
    CFTypeRef sub = IORegistryEntryCreateCFProperty(iface, CFSTR("bInterfaceSubClass"),
                                                    kCFAllocatorDefault, 0);
    CFTypeRef proto = IORegistryEntryCreateCFProperty(iface, CFSTR("bInterfaceProtocol"),
                                                      kCFAllocatorDefault, 0);
    in->number = (uint8_t)cf_u32(n);
    in->alt = (uint8_t)cf_u32(alt);
    in->class_code = (uint8_t)cf_u32(cls);
    in->subclass = (uint8_t)cf_u32(sub);
    in->protocol = (uint8_t)cf_u32(proto);
    if (n) {
        CFRelease(n);
    }
    if (alt) {
        CFRelease(alt);
    }
    if (cls) {
        CFRelease(cls);
    }
    if (sub) {
        CFRelease(sub);
    }
    if (proto) {
        CFRelease(proto);
    }

    io_iterator_t kids;
    if (IORegistryEntryCreateIterator(iface, kIOServicePlane, kIORegistryIterateRecursively,
                                      &kids) == KERN_SUCCESS) {
        io_service_t pipe;
        while ((pipe = IOIteratorNext(kids))) {
            CFTypeRef addr = IORegistryEntryCreateCFProperty(
                pipe, CFSTR("bEndpointAddress"), kCFAllocatorDefault, 0);
            if (addr) {
                add_endpoint(in, pipe);
                CFRelease(addr);
            }
            IOObjectRelease(pipe);
        }
        IOObjectRelease(kids);
    }
    /* Endpoints are not published in IORegistry while DisplayLink Manager
     * holds exclusive USB. Fill the layout measured on this Ridge hub. */
    if (in->class_code == OIZYS_DL3_CLASS && in->protocol == OIZYS_DL3_PROTOCOL &&
        in->ep_count == 0) {
        static const OizysEndpoint kRidge[] = {
            {0x02, 0, 2, 1024}, {0x84, 1, 2, 1024}, {0x08, 0, 2, 1024},
            {0x0a, 0, 2, 1024}, {0x0b, 0, 2, 1024}, {0x0c, 0, 2, 1024},
        };
        in->ep_count = 6;
        memcpy(in->ep, kRidge, sizeof(kRidge));
    }
    hub->iface_count++;
}

static int inspect_device(io_service_t svc, OizysHub *hub) {
    memset(hub, 0, sizeof(*hub));
    CFTypeRef vid = IORegistryEntryCreateCFProperty(svc, CFSTR("idVendor"), kCFAllocatorDefault, 0);
    CFTypeRef pid =
        IORegistryEntryCreateCFProperty(svc, CFSTR("idProduct"), kCFAllocatorDefault, 0);
    uint16_t v = (uint16_t)cf_u32(vid);
    uint16_t p = (uint16_t)cf_u32(pid);
    if (vid) {
        CFRelease(vid);
    }
    if (pid) {
        CFRelease(pid);
    }
    if (v != OIZYS_VID) {
        return 0;
    }
    hub->vid = v;
    hub->pid = p;

    CFTypeRef loc =
        IORegistryEntryCreateCFProperty(svc, CFSTR("locationID"), kCFAllocatorDefault, 0);
    hub->location_id = cf_u32(loc);
    if (loc) {
        CFRelease(loc);
    }

    CFTypeRef bcdusb =
        IORegistryEntryCreateCFProperty(svc, CFSTR("bcdUSB"), kCFAllocatorDefault, 0);
    CFTypeRef bcddev =
        IORegistryEntryCreateCFProperty(svc, CFSTR("bcdDevice"), kCFAllocatorDefault, 0);
    hub->bcd_usb = (uint16_t)cf_u32(bcdusb);
    hub->bcd_device = (uint16_t)cf_u32(bcddev);
    if (bcdusb) {
        CFRelease(bcdusb);
    }
    if (bcddev) {
        CFRelease(bcddev);
    }

    CFTypeRef man =
        IORegistryEntryCreateCFProperty(svc, CFSTR("USB Vendor Name"), kCFAllocatorDefault, 0);
    CFTypeRef prod =
        IORegistryEntryCreateCFProperty(svc, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    CFTypeRef ser =
        IORegistryEntryCreateCFProperty(svc, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
    CFTypeRef spd =
        IORegistryEntryCreateCFProperty(svc, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
    CFTypeRef owner =
        IORegistryEntryCreateCFProperty(svc, CFSTR("UsbExclusiveOwner"), kCFAllocatorDefault, 0);
    cf_cstring(man, hub->manufacturer, sizeof(hub->manufacturer));
    cf_cstring(prod, hub->product, sizeof(hub->product));
    cf_cstring(ser, hub->serial, sizeof(hub->serial));
    if (spd && CFGetTypeID(spd) == CFNumberGetTypeID()) {
        uint32_t s = cf_u32(spd);
        snprintf(hub->speed, sizeof(hub->speed), "%u", s);
    } else {
        cf_cstring(spd, hub->speed, sizeof(hub->speed));
    }
    cf_cstring(owner, hub->exclusive_owner, sizeof(hub->exclusive_owner));
    if (man) {
        CFRelease(man);
    }
    if (prod) {
        CFRelease(prod);
    }
    if (ser) {
        CFRelease(ser);
    }
    if (spd) {
        CFRelease(spd);
    }
    if (owner) {
        CFRelease(owner);
    }

    io_iterator_t kids;
    if (IORegistryEntryGetChildIterator(svc, kIOServicePlane, &kids) == KERN_SUCCESS) {
        io_service_t child;
        while ((child = IOIteratorNext(kids))) {
            io_name_t class_name;
            if (IOObjectGetClass(child, class_name) == KERN_SUCCESS &&
                strstr(class_name, "Interface") != NULL) {
                inspect_interface(hub, child);
            }
            IOObjectRelease(child);
        }
        IOObjectRelease(kids);
    }
    return 1;
}

void oizys_hub_print(const OizysHub *hub) {
    printf("Oizys hub\n");
    printf("  usb        %04x:%04x  %s / %s\n", hub->vid, hub->pid, hub->manufacturer,
           hub->product);
    printf("  serial     %s\n", hub->serial);
    printf("  loc        0x%08x  speed %s  bcdUSB %04x  bcdDev %04x\n", hub->location_id,
           hub->speed, hub->bcd_usb, hub->bcd_device);
    if (hub->identity.valid) {
        printf("  identity   %s  family=%s\n", hub->identity.platform,
               oizys_family_name(hub->identity.family));
    } else {
        printf("  identity   (type 0x40 not in registry; claim to read it)\n");
    }
    if (hub->identity.family == OIZYS_FAMILY_RIDGE || oizys_hub_is_dl3(hub)) {
        printf("  profile    2 heads, video OUT 08/0b, strips 64x16 (Ridge)\n");
        printf("  panels     2 × 1920×1080@60 (Dell P2219H)\n");
        OizysDamageMap map;
        oizys_damage_init(&map, 1920, 1080);
        printf("  strips     %u×%u  (%u tiles/head/frame)\n", map.cols, map.rows,
               map.cols * map.rows);
    }
    printf("  dl3        %s   control 0x02/0x84 %s\n", oizys_hub_is_dl3(hub) ? "yes" : "no",
           oizys_hub_has_control(hub) ? "present" : "MISSING");
    uint8_t vouts[8];
    int vn = oizys_hub_video_outs(hub, vouts, 8);
    printf("  video OUT  [");
    for (int i = 0; i < vn && i < 8; i++) {
        printf("%s%02x", i ? " " : "", vouts[i]);
    }
    printf("]\n");
    if (hub->exclusive_owner[0]) {
        printf("  owner      %s\n", hub->exclusive_owner);
        printf("             probe is read-only; `oizys run --takeover` claims the hub\n");
    } else {
        printf("  owner      none — USB is free to claim\n");
    }
    printf("  interfaces\n");
    for (int i = 0; i < hub->iface_count; i++) {
        const OizysInterface *in = &hub->iface[i];
        const char *tag = "";
        if (in->class_code == 0xff && in->protocol == 0x03) {
            tag = "  [dl3 video]";
        } else if (in->class_code == 0xfe && in->subclass == 0x01) {
            tag = "  [dfu]";
        } else if (in->class_code == 0x01) {
            tag = "  [audio]";
        } else if (in->class_code == 0x02 || in->class_code == 0x0a) {
            tag = "  [cdc]";
        }
        printf("    %2u alt %u  class %02x/%02x/%02x%s\n", in->number, in->alt, in->class_code,
               in->subclass, in->protocol, tag);
        for (int e = 0; e < in->ep_count; e++) {
            const OizysEndpoint *ep = &in->ep[e];
            static const char *tr[] = {"ctrl", "iso", "bulk", "int"};
            printf("         ep 0x%02x %-3s %-4s  maxpkt %u\n", ep->address,
                   ep->dir_in ? "IN" : "OUT", tr[ep->transfer & 3], ep->max_packet);
        }
    }
}

int oizys_usb_probe(OizysHub *hubs, int max_hubs) {
    if (!hubs || max_hubs <= 0) {
        return 0;
    }
    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                    IOServiceMatching("IOUSBHostDevice"), &iter);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    int n = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(iter))) {
        if (n < max_hubs && inspect_device(svc, &hubs[n])) {
            n++;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    return n;
}

int oizys_hub_is_dl3(const OizysHub *hub) {
    for (int i = 0; i < hub->iface_count; i++) {
        const OizysInterface *in = &hub->iface[i];
        if (in->class_code == OIZYS_DL3_CLASS && in->subclass == OIZYS_DL3_SUBCLASS &&
            in->protocol == OIZYS_DL3_PROTOCOL) {
            return 1;
        }
    }
    return 0;
}

int oizys_hub_has_control(const OizysHub *hub) {
    int out = 0, in = 0;
    for (int i = 0; i < hub->iface_count; i++) {
        for (int e = 0; e < hub->iface[i].ep_count; e++) {
            const OizysEndpoint *ep = &hub->iface[i].ep[e];
            if (ep->address == OIZYS_EP_CTRL_OUT && !ep->dir_in) {
                out = 1;
            }
            if (ep->address == OIZYS_EP_CTRL_IN && ep->dir_in) {
                in = 1;
            }
        }
    }
    return out && in;
}

int oizys_hub_video_outs(const OizysHub *hub, uint8_t *out, int max_out) {
    int n = 0;
    for (int i = 0; i < hub->iface_count; i++) {
        const OizysInterface *in = &hub->iface[i];
        if (in->class_code != OIZYS_DL3_CLASS || in->protocol != OIZYS_DL3_PROTOCOL) {
            continue;
        }
        for (int e = 0; e < in->ep_count; e++) {
            const OizysEndpoint *ep = &in->ep[e];
            if (!ep->dir_in && ep->transfer == 2 && ep->address != OIZYS_EP_CTRL_OUT) {
                if (n < max_out) {
                    out[n] = ep->address;
                }
                n++;
            }
        }
    }
    return n;
}

int oizys_stop_displaylink(void) {
    /* CrashRestartHelper will revive UserAgent unless both jobs are gone. */
    (void)system("launchctl bootout gui/$(id -u)/com.displaylink.CrashRestartHelper 2>/dev/null");
    (void)system("launchctl bootout gui/$(id -u)/com.displaylink.XpcService 2>/dev/null");
    (void)system("killall DisplayLinkUserAgent DisplayLinkXpcService CrashRestartHelper 2>/dev/null");
    usleep(400000);
    return 0;
}

int oizys_start_displaylink(void) {
#if OIZYS_ALLOW_DISPLAYLINK
    return system("open -a 'DisplayLink Manager' 2>/dev/null");
#else
    return -1;
#endif
}
