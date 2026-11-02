#include "terminal.h"
#include "oizys.h"
#include <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int oizys_service_command(const char *action);

static int number(const char *text, long low, long high, long *value) {
    char *end = NULL;
    errno = 0;
    long n = strtol(text, &end, 0);
    if (errno || end == text || *end || n < low || n > high) return 0;
    *value = n;
    return 1;
}

static int monitors(void) {
    CGDirectDisplayID ids[64];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(64, ids, &count) != kCGErrorSuccess) return 1;
    puts("ID         Pixels        Desktop pts   Hz       Position       Type");
    for (uint32_t i = 0; i < count; i++) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        CGRect bounds = CGDisplayBounds(ids[i]);
        double hz = mode ? CGDisplayModeGetRefreshRate(mode) : 0;
        char refresh[32];
        if (hz > 0) snprintf(refresh, sizeof(refresh), "%.2f", hz);
        else snprintf(refresh, sizeof(refresh), "unknown");
        printf("%-10u %5zu×%-5zu %5.0f×%-5.0f %-8s %6.0f,%6.0f  %s%s\n",
               ids[i], mode ? CGDisplayModeGetPixelWidth(mode) : 0,
               mode ? CGDisplayModeGetPixelHeight(mode) : 0,
               bounds.size.width, bounds.size.height, refresh, bounds.origin.x, bounds.origin.y,
               CGDisplayIsBuiltin(ids[i]) ? "built-in" :
               CGDisplayVendorNumber(ids[i]) == 0x4d56 ? "Oizys" : "external",
               CGDisplayIsMain(ids[i]) ? " (main)" : "");
        if (mode) CGDisplayModeRelease(mode);
    }
    puts("Hz is the reported display mode, not measured capture FPS. Unknown means macOS did not report it.");
    return 0;
}

static int monitor(int argc, char **argv) {
    long rawID;
    if (argc < 2 || !number(argv[0], 1, UINT32_MAX, &rawID) || !CGDisplayIsOnline((uint32_t)rawID)) {
        fputs("Choose an online display ID from `oizys monitors`.\n", stderr); return 1;
    }
    CGDirectDisplayID id = (uint32_t)rawID;
    const char *action = argv[1];
    if (!strcmp(action, "modes") || !strcmp(action, "mode")) {
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, NULL);
        if (!modes) return 1;
        CFIndex count = CFArrayGetCount(modes);
        if (!strcmp(action, "modes")) {
            for (CFIndex i = 0; i < count; i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                printf("%ld: %zu×%zu pt, %zu×%zu px, %.2f Hz\n", i,
                       CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                       CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode),
                       CGDisplayModeGetRefreshRate(mode));
            }
            CFRelease(modes); return 0;
        }
        long index;
        if (argc != 3 || !number(argv[2], 0, count - 1, &index)) {
            CFRelease(modes); fputs("Choose a mode index from `monitor <id> modes`.\n", stderr); return 1;
        }
        CGError result = CGDisplaySetDisplayMode(id, (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index), NULL);
        CFRelease(modes);
        if (result) fprintf(stderr, "macOS refused the display mode (%d).\n", result);
        return result ? 1 : 0;
    }
    long x = 0, y = 0;
    int position = !strcmp(action, "position");
    int mirror = !strcmp(action, "mirror");
    if ((!position && !mirror) ||
        (position && (argc != 4 || !number(argv[2], -32768, 32767, &x) || !number(argv[3], -32768, 32767, &y))) ||
        (mirror && (argc != 3 || (strcmp(argv[2], "off") &&
            (!number(argv[2], 1, UINT32_MAX, &x) || x == id || !CGDisplayIsOnline((uint32_t)x)))))) {
        fputs("oizys monitor <id> modes | mode <index> | position <x> <y> | mirror <other-id|off>\n", stderr);
        return 1;
    }
    CGDisplayConfigRef config;
    CGError result = CGBeginDisplayConfiguration(&config);
    if (result) return 1;
    if (position) result = CGConfigureDisplayOrigin(config, id, (int)x, (int)y);
    else result = CGConfigureDisplayMirrorOfDisplay(config, id,
                               !strcmp(argv[2], "off") ? kCGNullDirectDisplay : (CGDirectDisplayID)x);
    if (result) CGCancelDisplayConfiguration(config);
    else result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (result) fprintf(stderr, "macOS refused the display configuration (%d).\n", result);
    return result ? 1 : 0;
}

int oizys_terminal_command(int argc, char **argv) {
    if ((argc == 1 && isatty(STDIN_FILENO)) || (argc > 1 && !strcmp(argv[1], "tui"))) {
        return oizys_tui();
    }
    if (argc < 2) return -1;
    if (!strcmp(argv[1], "monitors")) return monitors();
    if (!strcmp(argv[1], "monitor")) return monitor(argc - 2, argv + 2);
    if (!strcmp(argv[1], "service")) return oizys_service_command(argc > 2 ? argv[2] : "status");
    return -1;
}
