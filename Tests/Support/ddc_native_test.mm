// Compile the shipping backend with synthetic display identities, never live I2C.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

static const uint32_t *test_displays;
static CFDataRef test_edid;
static uint32_t test_vendor(uint32_t id) { return test_displays[(id - 1) * 5]; }
static uint32_t test_model(uint32_t id) { return test_displays[(id - 1) * 5 + 1]; }
static uint32_t test_serial(uint32_t id) { return test_displays[(id - 1) * 5 + 2]; }
static boolean_t test_builtin(uint32_t id) { return test_displays[(id - 1) * 5 + 3]; }

#define CGDisplayVendorNumber test_vendor
#define CGDisplayModelNumber test_model
#define CGDisplaySerialNumber test_serial
#define CGDisplayIsBuiltin test_builtin
#include "../../Sources/MViewCore/ddc_native.mm"

void mview_log(const char *, ...) {}
int mview_display_is_sidecar(uint32_t id) { return test_displays[(id - 1) * 5 + 4]; }

static IOReturn test_copy_edid(IOAVServiceRef, CFDataRef *out) {
    *out = (CFDataRef)CFRetain(test_edid);
    return kIOReturnSuccess;
}

extern "C" uint32_t test_match(const uint8_t *edid, size_t length,
                                const uint32_t *displays, uint32_t count) {
    if (count > 16) return 0;
    test_displays = displays;
    test_edid = CFDataCreate(NULL, edid, (CFIndex)length);
    av_edid = test_copy_edid;
    uint32_t ids[16];
    for (uint32_t i = 0; i < count; i++) ids[i] = i + 1;
    uint32_t id = av_service_display_id(NULL, ids, count);
    CFRelease(test_edid);
    return id;
}

extern "C" int test_reply(const uint8_t *reply, size_t length) {
    return valid_ddc_reply(reply, length);
}
