#include "terminal.h"
#include "oizys.h"
#include <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
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

static int read_line(const char *prompt, char *buffer, size_t size) {
    fputs(prompt, stdout); fflush(stdout);
    if (!fgets(buffer, (int)size, stdin)) return 0;
    char *newline = strchr(buffer, '\n');
    if (newline) *newline = '\0';
    else {
        int c;
        while ((c = getchar()) != '\n' && c != EOF) {}
        buffer[0] = '\0';
        fputs("Input too long.\n", stderr); return 0;
    }
    return 1;
}

/* argv is passed directly: terminal input is never interpreted by a shell. */
static void invoke(const char *const arguments[]) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size)) return;
    pid_t child;
    int error = posix_spawn(&child, executable, NULL, NULL, (char *const *)arguments, environ);
    if (error) { fprintf(stderr, "Could not run command: %s\n", strerror(error)); return; }
    int status;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

static void monitor_menu(void) {
    char id[32], choice[16], a[64], b[64];
    monitors();
    if (!read_line("Display ID (blank to return): ", id, sizeof(id)) || !id[0]) return;
    while (1) {
        printf("\nDisplay %s\n1 Modes  2 Set mode  3 Position  4 Mirror / unmirror\n"
               "5 Brightness  6 Contrast  7 Volume  8 Input source  9 Power\n"
               "c DDC capabilities  d Read VCP  e Write VCP  q Back\n", id);
        if (!read_line("> ", choice, sizeof(choice)) || !strcmp(choice, "q")) return;
        if (!strcmp(choice, "1")) {
            invoke((const char *const[]){"oizys", "monitor", id, "modes", NULL});
        } else if (!strcmp(choice, "2")) {
            invoke((const char *const[]){"oizys", "monitor", id, "modes", NULL});
            if (read_line("Mode index: ", a, sizeof(a)))
                invoke((const char *const[]){"oizys", "monitor", id, "mode", a, NULL});
        } else if (!strcmp(choice, "3")) {
            if (read_line("X in desktop points: ", a, sizeof(a)) && read_line("Y: ", b, sizeof(b)))
                invoke((const char *const[]){"oizys", "monitor", id, "position", a, b, NULL});
        } else if (!strcmp(choice, "4")) {
            if (read_line("Mirror display ID, or off: ", a, sizeof(a)))
                invoke((const char *const[]){"oizys", "monitor", id, "mirror", a, NULL});
        } else if (!strcmp(choice, "c")) {
            invoke((const char *const[]){"oizys", "ddc", "caps", "--display", id, NULL});
        } else {
            const char *code = !strcmp(choice, "5") ? "0x10" : !strcmp(choice, "6") ? "0x12" :
                               !strcmp(choice, "7") ? "0x62" : !strcmp(choice, "8") ? "0x60" :
                               !strcmp(choice, "9") ? "0xd6" : NULL;
            if (!code && strcmp(choice, "d") && strcmp(choice, "e")) continue;
            if (!code) {
                if (!read_line("VCP code (e.g. 0x10): ", a, sizeof(a))) return;
                code = a;
            }
            invoke((const char *const[]){"oizys", "ddc", "get", (char *)code, "--display", id, NULL});
            if (!strcmp(choice, "d")) continue;
            if (read_line("New raw value (blank cancels; use the monitor's reported range): ", b, sizeof(b)) && b[0])
                invoke((const char *const[]){"oizys", "ddc", "set", (char *)code, b, "--display", id, NULL});
        }
    }
}

static int legacy_menu(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fputs("The TUI needs an interactive terminal. Use `oizys help` for scriptable commands.\n", stderr); return 2;
    }
    char choice[16], key[128], value[128];
    while (1) {
        if (getenv("TERM") && strcmp(getenv("TERM"), "dumb")) fputs("\033[2J\033[H", stdout);
        puts("Oizys · Monitor control\n");
        monitors();
        puts("\n1 Monitor controls    2 All driver settings    3 Change a setting\n"
             "4 Service status      5 Start / resume         6 Stop for this login\n"
             "7 Restart / apply     8 Enable login startup   9 Disable login startup\n"
             "p Screen Recording permission   r Reset settings   q Quit\n"
             "Display settings apply immediately. Driver settings apply on restart.\n"
             "DDC requires a supported native monitor connection; dock heads may not expose DDC.");
        if (!read_line("> ", choice, sizeof(choice)) || !strcmp(choice, "q")) return 0;
        if (!strcmp(choice, "1")) monitor_menu();
        else if (!strcmp(choice, "2")) oizys_config_print(stdout);
        else if (!strcmp(choice, "3")) {
            oizys_config_print(stdout);
            if (read_line("Key: ", key, sizeof(key)) && read_line("Value: ", value, sizeof(value)))
                invoke((const char *const[]){"oizys", "config", "set", key, value, NULL});
        } else if (!strcmp(choice, "4")) oizys_service_command("status");
        else if (!strcmp(choice, "5")) oizys_service_command("start");
        else if (!strcmp(choice, "6")) oizys_service_command("stop");
        else if (!strcmp(choice, "7")) oizys_service_command("restart");
        else if (!strcmp(choice, "8")) oizys_service_command("login-enable");
        else if (!strcmp(choice, "9")) oizys_service_command("login-disable");
        else if (!strcmp(choice, "p")) oizys_service_command("permissions");
        else if (!strcmp(choice, "r") && read_line("Type reset to restore driver defaults: ", value, sizeof(value)) && !strcmp(value, "reset"))
            invoke((const char *const[]){"oizys", "config", "reset", NULL});
        oizys_config_reload();
        if (!read_line("\nPress Return to continue…", value, sizeof(value))) return 0;
    }
}

int oizys_terminal_command(int argc, char **argv) {
    if ((argc == 1 && isatty(STDIN_FILENO)) || (argc > 1 && !strcmp(argv[1], "tui"))) {
        if (argc > 2 && !strcmp(argv[2], "--menu")) return legacy_menu();
        return oizys_tui();
    }
    if (argc < 2) return -1;
    if (!strcmp(argv[1], "monitors")) return monitors();
    if (!strcmp(argv[1], "monitor")) return monitor(argc - 2, argv + 2);
    if (!strcmp(argv[1], "service")) return oizys_service_command(argc > 2 ? argv[2] : "status");
    return -1;
}
