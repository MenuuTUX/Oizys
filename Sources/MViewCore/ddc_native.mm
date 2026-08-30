#include "mview_ddc.h"
#include "mview_display.h"
#include "mview_usb.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * On Apple Silicon the Intel IOFramebuffer/IOI2C path is gone: IOFramebuffer became
 * IOMobileFramebuffer and the IOI2C calls silently succeed while doing nothing. The
 * replacement is a private, unheadered set inside IOKit, resolved here by name. Nothing
 * about it is guaranteed across releases, so a missing symbol is a clean "no DDC" rather
 * than a crash.
 */
typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*IOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceReadI2CFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVServiceWriteI2CFn)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVServiceCopyEDIDFn)(IOAVServiceRef, CFDataRef *);

static IOAVServiceCreateWithServiceFn av_create;
static IOAVServiceReadI2CFn av_read;
static IOAVServiceWriteI2CFn av_write;
static IOAVServiceCopyEDIDFn av_edid;

static int load_ioav(void) {
    static int attempted;
    if (attempted) {
        return av_create && av_read && av_write && av_edid;
    }
    attempted = 1;
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit) {
        return 0;
    }
    av_create = (IOAVServiceCreateWithServiceFn)dlsym(iokit, "IOAVServiceCreateWithService");
    av_read = (IOAVServiceReadI2CFn)dlsym(iokit, "IOAVServiceReadI2C");
    av_write = (IOAVServiceWriteI2CFn)dlsym(iokit, "IOAVServiceWriteI2C");
    av_edid = (IOAVServiceCopyEDIDFn)dlsym(iokit, "IOAVServiceCopyEDID");
    if (!av_create || !av_read || !av_write || !av_edid) {
        mview_log("IOAVService is not available in this IOKit; DDC/CI is off");
        return 0;
    }
    return 1;
}

/* DDC/CI lives at 7-bit I2C address 0x37. The host writes as 0x51 and the display as 0x6e. */
#define DDC_CHIP 0x37
#define DDC_HOST 0x51
#define DDC_DISPLAY 0x6e

#define DDC_OP_GET 0x01
#define DDC_OP_REPLY 0x02
#define DDC_OP_SET 0x03
#define DDC_OP_CAPS_REQUEST 0xf3
#define DDC_OP_CAPS_REPLY 0xe3

/*
 * Reads over this channel fail perhaps a third of the time on Apple Silicon and always
 * have; every working implementation retries. These are the intervals that have been
 * measured to work rather than derived from anything.
 */
#define DDC_ATTEMPTS 5
#define DDC_RETRY_US 50000
#define DDC_SETTLE_US 45000

struct MViewDDCDisplay {
    IOAVServiceRef service;
    uint32_t display_id;
    /* Whether the frame this display answers to carries its own source byte. Settled once,
     * on the first successful exchange, and then reused. */
    int framing;
};

static uint8_t checksum(uint8_t seed, const uint8_t *bytes, size_t length) {
    uint8_t value = seed;
    for (size_t i = 0; i < length; i++) {
        value ^= bytes[i];
    }
    return value;
}

/*
 * Two framings are in circulation for IOAVServiceWriteI2C, differing only in whether the
 * caller repeats the 0x51 source byte that it also passes as the data address. Writing the
 * wrong one produces a checksum the monitor rejects, which is inert -- it ignores the
 * frame. Both are tried on the first exchange and the one that answers is kept.
 */
static IOReturn ddc_write_framed(MViewDDCDisplay *display, int framing, const uint8_t *payload,
                                 size_t payload_len) {
    uint8_t frame[40];
    if (!payload || payload_len > sizeof(frame) - 3) return kIOReturnBadArgument;
    size_t at = 0;
    if (framing) {
        frame[at++] = DDC_HOST;
    }
    frame[at++] = (uint8_t)(0x80 | payload_len);
    memcpy(frame + at, payload, payload_len);
    at += payload_len;
    /* The checksum seed is the address the display sees this frame arrive on. */
    frame[at] = checksum(framing ? 0x6e : (uint8_t)(DDC_HOST ^ 0x6e), frame, at);
    at++;
    return av_write(display->service, DDC_CHIP, DDC_HOST, frame, (uint32_t)at);
}

static int valid_ddc_reply(const uint8_t *reply, size_t capacity) {
    if (!reply || capacity < 3 || reply[0] != DDC_DISPLAY || !(reply[1] & 0x80)) return 0;
    size_t length = (reply[1] & 0x7f) + 3u;
    /* Replies include source, length and checksum; 0x50 is the virtual host address. */
    return length <= capacity && checksum(0x50, reply, length) == 0;
}

static int ddc_exchange(MViewDDCDisplay *display, const uint8_t *payload, size_t payload_len,
                        uint8_t *reply, size_t reply_len) {
    if (!display || !display->service) {
        return -1;
    }
    for (int attempt = 0; attempt < DDC_ATTEMPTS; attempt++) {
        for (int framing = 0; framing < 2; framing++) {
            /* Once a framing has answered, stop paying for the other one. */
            if (display->framing >= 0 && framing != display->framing) {
                continue;
            }
            if (ddc_write_framed(display, framing, payload, payload_len) != kIOReturnSuccess) {
                continue;
            }
            if (!reply || reply_len == 0) {
                display->framing = framing;
                return 0;
            }
            usleep(DDC_SETTLE_US);
            memset(reply, 0, reply_len);
            if (av_read(display->service, DDC_CHIP, DDC_HOST, reply, (uint32_t)reply_len) !=
                kIOReturnSuccess) {
                continue;
            }
            if (valid_ddc_reply(reply, reply_len)) {
                display->framing = framing;
                return 0;
            }
        }
        usleep(DDC_RETRY_US);
    }
    return -1;
}

/* -- the display's I2C service -------------------------------------------------------- */

/*
 * A DisplayLink head forwards the real monitor's EDID, so a dock-driven Dell and a natively
 * attached one can have the same vendor and model. Require a unique EDID match to an
 * external AV service. Guessing a display when matching fails can send a command to the
 * wrong physical monitor, particularly when changing its input or power state.
 */
static uint32_t av_service_display_id(IOAVServiceRef service, const uint32_t *ids,
                                       uint32_t count) {
    CFDataRef edid = NULL;
    if (av_edid(service, &edid) != kIOReturnSuccess || !edid) {
        if (edid) CFRelease(edid);
        return 0;
    }
    uint32_t match = 0;
    static const uint8_t header[] = {0, 255, 255, 255, 255, 255, 255, 0};
    if (CFDataGetLength(edid) >= 128) {
        const uint8_t *bytes = CFDataGetBytePtr(edid);
        unsigned sum = 0;
        for (size_t i = 0; i < 128; i++) sum += bytes[i];
        if (memcmp(bytes, header, sizeof(header)) == 0 && (sum & 255) == 0) {
            uint32_t vendor = ((uint32_t)bytes[8] << 8) | bytes[9];
            uint32_t model = bytes[10] | ((uint32_t)bytes[11] << 8);
            uint32_t serial = bytes[12] | ((uint32_t)bytes[13] << 8) |
                              ((uint32_t)bytes[14] << 16) | ((uint32_t)bytes[15] << 24);
            for (uint32_t i = 0; i < count; i++) {
                if (CGDisplayIsBuiltin(ids[i]) || mview_display_is_sidecar(ids[i]) ||
                    CGDisplayVendorNumber(ids[i]) == 0x4d56) continue;
                if (CGDisplayVendorNumber(ids[i]) == vendor &&
                    CGDisplayModelNumber(ids[i]) == model &&
                    CGDisplaySerialNumber(ids[i]) == serial) {
                    if (match) {
                        match = 0; /* Identical EDIDs: do not choose a monitor by list order. */
                        break;
                    }
                    match = ids[i];
                }
            }
        }
    }
    CFRelease(edid);
    return match;
}

/* Returns a retained service. A zero requested ID selects the first verified native panel. */
static IOAVServiceRef matching_av_service(uint32_t requested, uint32_t *matched) {
    if (!load_ioav()) return NULL;
    uint32_t ids[16], count = 0;
    if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess || !count) return NULL;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("DCPAVServiceProxy"),
                                     &iterator) != kIOReturnSuccess) return NULL;
    IOAVServiceRef found = NULL;
    io_service_t candidate;
    while ((candidate = IOIteratorNext(iterator))) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(
            candidate, CFSTR("Location"), kCFAllocatorDefault, 0);
        int external = location && CFGetTypeID(location) == CFStringGetTypeID() &&
                       CFEqual(location, CFSTR("External"));
        if (location) CFRelease(location);
        IOAVServiceRef av = external ? av_create(kCFAllocatorDefault, candidate) : NULL;
        IOObjectRelease(candidate);
        if (!av) continue;
        uint32_t id = av_service_display_id(av, ids, count);
        if (id && (!requested || requested == id)) {
            found = av;
            if (matched) *matched = id;
            break;
        }
        CFRelease(av);
    }
    IOObjectRelease(iterator);
    return found;
}

uint32_t mview_ddc_native_display_id(void) {
    uint32_t id = 0;
    IOAVServiceRef av = matching_av_service(0, &id);
    if (av) CFRelease(av);
    return id;
}

MViewDDCDisplay *mview_ddc_open(uint32_t display_id) {
    if (!display_id) return NULL;
    IOAVServiceRef av = matching_av_service(display_id, NULL);
    if (!av) {
        return NULL;
    }
    MViewDDCDisplay *display = (MViewDDCDisplay *)calloc(1, sizeof(*display));
    if (!display) {
        CFRelease(av);
        return NULL;
    }
    display->service = av;
    display->display_id = display_id;
    display->framing = -1; /* undecided until the first exchange answers */
    return display;
}

void mview_ddc_close(MViewDDCDisplay *display) {
    if (!display) {
        return;
    }
    if (display->service) {
        CFRelease(display->service);
    }
    free(display);
}

/* -- VCP ------------------------------------------------------------------------------ */

int mview_ddc_get_vcp(MViewDDCDisplay *display, uint8_t code, uint16_t *current,
                      uint16_t *maximum) {
    uint8_t request[2] = {DDC_OP_GET, code};
    uint8_t reply[12];
    if (ddc_exchange(display, request, sizeof(request), reply, sizeof(reply)) != 0) {
        return -1;
    }
    /* 6e 88 02 <result> <code> <type> <max_hi> <max_lo> <cur_hi> <cur_lo> <cksum> */
    if ((reply[1] & 0x7f) != 8 || reply[2] != DDC_OP_REPLY || reply[4] != code) {
        return -1;
    }
    if (reply[3] != 0x00) {
        return -1; /* the display reports this feature as unsupported */
    }
    if (maximum) {
        *maximum = (uint16_t)((reply[6] << 8) | reply[7]);
    }
    if (current) {
        *current = (uint16_t)((reply[8] << 8) | reply[9]);
    }
    return 0;
}

int mview_ddc_set_vcp(MViewDDCDisplay *display, uint8_t code, uint16_t value) {
    if (!display) return -1;
    if (display->framing < 0) {
        /* A successful I2C write is not an acknowledgement from the monitor. Establish
           framing with a read before sending a command that changes settings. */
        mview_ddc_get_vcp(display, MVIEW_VCP_VERSION, NULL, NULL);
        if (display->framing < 0) return -1;
    }
    uint8_t request[4] = {DDC_OP_SET, code, (uint8_t)(value >> 8), (uint8_t)(value & 0xff)};
    if (ddc_exchange(display, request, sizeof(request), NULL, 0) != 0) {
        return -1;
    }
    /* A set is not acknowledged, so the only proof it landed is reading it back. Some
       features are write-only or clamp the value, and neither is an error. */
    usleep(DDC_SETTLE_US);
    return 0;
}

int mview_ddc_capabilities(MViewDDCDisplay *display, char *out, size_t capacity) {
    if (!out || capacity == 0) {
        return -1;
    }
    out[0] = '\0';
    size_t written = 0;
    for (uint16_t offset = 0; offset < 4096;) {
        uint8_t request[3] = {DDC_OP_CAPS_REQUEST, (uint8_t)(offset >> 8), (uint8_t)(offset & 0xff)};
        uint8_t reply[40];
        if (ddc_exchange(display, request, sizeof(request), reply, sizeof(reply)) != 0) {
            return -1;
        }
        if ((reply[1] & 0x7f) < 3 || reply[2] != DDC_OP_CAPS_REPLY ||
            (((uint16_t)reply[3] << 8) | reply[4]) != offset) {
            return -1;
        }
        /* Length byte counts the opcode and the two offset bytes as well as the text. */
        size_t payload = (size_t)(reply[1] & 0x7f);
        size_t text = payload - 3;
        if (text == 0) {
            return 0;
        }
        if (text >= capacity - written) return -1;
        for (size_t i = 0; i < text && written + 1 < capacity; i++) {
            out[written++] = (char)reply[5 + i];
        }
        out[written] = '\0';
        offset = (uint16_t)(offset + text);
    }
    return -1; /* No terminating fragment within the bounded capabilities length. */
}

/* -- naming and reporting -------------------------------------------------------------- */

const char *mview_ddc_vcp_name(uint8_t code) {
    switch (code) {
    case MVIEW_VCP_RESTORE_FACTORY: return "restore factory defaults";
    case MVIEW_VCP_RESTORE_LUMINANCE: return "restore brightness and contrast";
    case MVIEW_VCP_RESTORE_COLOUR: return "restore colour defaults";
    case MVIEW_VCP_LUMINANCE: return "brightness";
    case MVIEW_VCP_CONTRAST: return "contrast";
    case MVIEW_VCP_COLOUR_PRESET: return "colour preset";
    case MVIEW_VCP_GAIN_RED: return "video gain red";
    case MVIEW_VCP_GAIN_GREEN: return "video gain green";
    case MVIEW_VCP_GAIN_BLUE: return "video gain blue";
    case MVIEW_VCP_AUTO_SETUP: return "auto setup";
    case MVIEW_VCP_INPUT_SOURCE: return "input source";
    case MVIEW_VCP_AUDIO_VOLUME: return "speaker volume";
    case MVIEW_VCP_BLACK_RED: return "black level red";
    case MVIEW_VCP_BLACK_GREEN: return "black level green";
    case MVIEW_VCP_BLACK_BLUE: return "black level blue";
    case MVIEW_VCP_AUDIO_MUTE: return "audio mute / screen blank";
    case MVIEW_VCP_USAGE_HOURS: return "display usage hours";
    case MVIEW_VCP_CONTROLLER_TYPE: return "controller type";
    case MVIEW_VCP_FIRMWARE: return "firmware level";
    case MVIEW_VCP_OSD_LOCK: return "OSD button lock";
    case MVIEW_VCP_OSD_LANGUAGE: return "OSD language";
    case MVIEW_VCP_POWER_MODE: return "power mode";
    case MVIEW_VCP_VERSION: return "MCCS version";
    default: return NULL;
    }
}

static const uint8_t STANDARD_CODES[] = {
    MVIEW_VCP_LUMINANCE,    MVIEW_VCP_CONTRAST,    MVIEW_VCP_COLOUR_PRESET,
    MVIEW_VCP_GAIN_RED,     MVIEW_VCP_GAIN_GREEN,  MVIEW_VCP_GAIN_BLUE,
    MVIEW_VCP_BLACK_RED,    MVIEW_VCP_BLACK_GREEN, MVIEW_VCP_BLACK_BLUE,
    MVIEW_VCP_INPUT_SOURCE, MVIEW_VCP_AUDIO_VOLUME, MVIEW_VCP_AUDIO_MUTE,
    MVIEW_VCP_OSD_LOCK,     MVIEW_VCP_OSD_LANGUAGE, MVIEW_VCP_POWER_MODE,
    MVIEW_VCP_USAGE_HOURS,  MVIEW_VCP_CONTROLLER_TYPE, MVIEW_VCP_FIRMWARE,
    MVIEW_VCP_VERSION,
};

void mview_ddc_dump(MViewDDCDisplay *display, FILE *out) {
    for (size_t i = 0; i < sizeof(STANDARD_CODES); i++) {
        uint8_t code = STANDARD_CODES[i];
        uint16_t current = 0, maximum = 0;
        if (mview_ddc_get_vcp(display, code, &current, &maximum) != 0) {
            continue;
        }
        fprintf(out, "  0x%02x  %-32s %5u / %u\n", code, mview_ddc_vcp_name(code), current,
                maximum);
    }
}

void mview_ddc_list(FILE *out) {
    uint32_t ids[16], count = 0;
    if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess) {
        fputs("could not enumerate displays\n", out);
        return;
    }
    if (!count) {
        fputs("no online displays visible to this process; check WindowServer access\n", out);
        return;
    }
    int available = 0;
    for (uint32_t i = 0; i < count; i++) {
        MViewDDCDisplay *display = mview_ddc_open(ids[i]);
        available += display != NULL;
        const char *kind = CGDisplayIsBuiltin(ids[i])          ? "built-in"
                           : mview_display_is_sidecar(ids[i])  ? "Sidecar/AirPlay"
                           : CGDisplayVendorNumber(ids[i]) == 0x4d56 ? "MView virtual head"
                                                                     : "external";
        CGRect bounds = CGDisplayBounds(ids[i]);
        fprintf(out, "  display %-4u %-20s %4dx%-4d  %s\n", ids[i], kind,
                (int)bounds.size.width, (int)bounds.size.height,
                display ? "native I2C path matched (DDC/CI untested)"
                        : "no verified native I2C path");
        mview_ddc_close(display);
    }
    if (!available) {
        fputs("\n  No native I2C path could be verified. This backend requires an external\n"
              "  DCPAVServiceProxy and a unique EDID match. DisplayLink outputs need a\n"
              "  separate USB DDC/CI tunnel, which MView does not yet implement.\n", out);
    }
}
