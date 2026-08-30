#include "mview.h"
#include "mview_capture.h"
#include "mview_profile.h"

#include <CoreGraphics/CoreGraphics.h>

#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MVIEW_HEADS 2
#define MVIEW_HEAD_W 1920
#define MVIEW_HEAD_H 1080

static void sleep_seconds(double seconds) {
    struct timespec request = {(time_t)seconds, (long)((seconds - (long)seconds) * 1e9)};
    nanosleep(&request, NULL);
}

static void ensure_logs_dir(void) {
    mkdir("logs", 0755);
}

static int has_flag(int argc, char **argv, const char *flag) {
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], flag) == 0) {
            return 1;
        }
    }
    return 0;
}

/* `--seconds N` or `--seconds=N`; `fallback` when absent or unparsable. */
static int seconds_argument(int argc, char **argv, int fallback) {
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "--seconds=", 10) == 0) {
            int value = atoi(argv[i] + 10);
            return value > 0 ? value : fallback;
        }
        if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
            int value = atoi(argv[i + 1]);
            return value > 0 ? value : fallback;
        }
    }
    return fallback;
}

/*
 * JSON string body. The owner and manufacturer strings come off USB descriptors, so they
 * are attacker-adjacent and get escaped rather than trusted.
 */
static void json_puts(FILE *file, const char *value) {
    fputc('"', file);
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", file); break;
        case '\\': fputs("\\\\", file); break;
        case '\n': fputs("\\n", file); break;
        case '\r': fputs("\\r", file); break;
        case '\t': fputs("\\t", file); break;
        default:
            if (*p < 0x20 || *p == 0x7f) {
                fprintf(file, "\\u%04x", *p);
            } else {
                fputc(*p, file);
            }
        }
    }
    fputc('"', file);
}

static const char *json_bool(int value) {
    return value ? "true" : "false";
}

static void iso8601_now(char *out, size_t capacity) {
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    strftime(out, capacity, "%Y-%m-%dT%H:%M:%SZ", &utc);
}

static void print_usage(void) {
    puts("mview — open-source DisplayLink Ridge driver (C)\n\n"
         "  mview probe              identify the USB hub (read-only)\n"
         "  mview displays           two 1920x1080 virtual heads until Ctrl-C\n"
         "  mview diagnose --takeover  authenticate both heads and read physical EDIDs\n"
         "  mview patterns --takeover [--seconds N]  unique physical test patterns\n"
         "  mview verify --takeover [--seconds N]  measured pattern proof -> logs/verify.json\n"
         "  mview bench              encoder throughput on a synthetic surface\n"
         "  mview profile            per-zone profile of a scanout sequence\n"
         "  mview run --takeover [--profile]  stop DLM and forward two Haar-encoded desktops\n"
         "  mview confirm            you looked at both panels and they were right\n\n"
         "  overall_pass in logs/verify.json is only ever set by `mview confirm`,\n"
         "  or by --confirmed on patterns/verify. Nothing this process can measure\n"
         "  distinguishes a faithfully encoded black frame from a broken encoder.\n\n"
         "  mview stop-dlm | start-dlm");
}

static void cmd_probe(void) {
    MViewHub *hubs = calloc(MVIEW_MAX_HUBS, sizeof(*hubs));
    if (!hubs) {
        return;
    }
    int n = mview_usb_probe(hubs, MVIEW_MAX_HUBS);
    if (n == 0) {
        puts("no DisplayLink device (vid 17e9) on USB");
    }
    for (int i = 0; i < n; i++) {
        mview_hub_print(&hubs[i]);
    }
    free(hubs);
}

static MViewVirtualDisplay *make_head(const char *name, uint32_t serial) {
    MViewVirtualDisplayDesc desc = {
        .name = name,
        .width = MVIEW_HEAD_W,
        .height = MVIEW_HEAD_H,
        .refresh_hz = 60,
        .vendor_id = 0x4d56,
        .product_id = 0x0108,
        .serial = serial,
        .mm_width = 478,
        .mm_height = 269,
    };
    return mview_virtual_display_create(&desc);
}

/*
 * Both heads, on display units nobody else holds.
 *
 * With a Sidecar iPad attached the window server hands the second head the unit the iPad
 * already occupies, and ScreenCaptureKit then resolves that head's stream to the iPad: the
 * panel scans out the iPad's desktop, at 60 Hz of full-frame change, and no API reports
 * anything wrong. It will not, however, reuse a unit another virtual display is holding —
 * so a colliding pair kept open while a fresh pair is created walks the new heads onto free
 * units, and they keep those units once the old pair is released.
 */
static int make_head_pair(MViewVirtualDisplay **left, MViewVirtualDisplay **right) {
    *left = make_head("MView Left", 0x4d560001);
    *right = make_head("MView Right", 0x4d560002);
    if (!*left || !*right) {
        mview_virtual_display_destroy(*left);
        mview_virtual_display_destroy(*right);
        *left = *right = NULL;
        return -1;
    }
    /* macOS needs a moment to publish a freshly created virtual display before its bounds,
       mode and unit number can be read. */
    sleep_seconds(0.5);
    if (!mview_display_unit_is_shared(mview_virtual_display_id(*left)) &&
        !mview_display_unit_is_shared(mview_virtual_display_id(*right))) {
        return 0;
    }
    printf("  a head landed on a display unit another display already holds; "
           "recreating both on free units\n");
    /*
     * Decoys go first and take the contested low units, so the heads that follow are given
     * free ones and keep them after the decoys are released. The decoys are the pair that
     * carries a throwaway identity: macOS files a saved arrangement under a display's
     * vendor, product and serial, so the heads the user actually arranges have to keep
     * theirs or their positions come back as defaults every session.
     */
    mview_virtual_display_destroy(*left);
    mview_virtual_display_destroy(*right);
    *left = *right = NULL;
    MViewVirtualDisplay *decoy_left = make_head("MView Spare A", 0xdead0001);
    MViewVirtualDisplay *decoy_right = make_head("MView Spare B", 0xdead0002);
    sleep_seconds(0.5);
    *left = make_head("MView Left", 0x4d560001);
    *right = make_head("MView Right", 0x4d560002);
    sleep_seconds(0.5);
    mview_virtual_display_destroy(decoy_left);
    mview_virtual_display_destroy(decoy_right);
    if (!*left || !*right) {
        mview_virtual_display_destroy(*left);
        mview_virtual_display_destroy(*right);
        *left = *right = NULL;
        return -1;
    }
    sleep_seconds(0.5);
    if (mview_display_unit_is_shared(mview_virtual_display_id(*left)) ||
        mview_display_unit_is_shared(mview_virtual_display_id(*right))) {
        fputs("a head is still sharing a display unit; ScreenCaptureKit will scan out the "
              "wrong desktop\n",
              stderr);
        return -1;
    }
    return 0;
}

/* Sidecar is the reason a head ends up mirrored, and it is invisible in the log otherwise:
   the iPad shows up as an ordinary external display. Name it once at startup. */
static void report_sidecar_displays(void) {
    uint32_t ids[16], count = 0;
    if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess) {
        return;
    }
    for (uint32_t i = 0; i < count; i++) {
        if (mview_display_is_sidecar(ids[i])) {
            CGRect bounds = CGDisplayBounds(ids[i]);
            printf("  Sidecar/AirPlay display %u at (%d,%d) %dx%d — kept out of the dock's "
                   "mirror sets\n",
                   ids[i], (int)bounds.origin.x, (int)bounds.origin.y, (int)bounds.size.width,
                   (int)bounds.size.height);
        }
    }
}

static void report_head_modes(const uint32_t *ids, int count) {
    for (int head = 0; head < count; head++) {
        uint32_t width = 0, height = 0;
        double hz = 0;
        if (mview_display_mode(ids[head], &width, &height, &hz) == 0) {
            printf("  head %d: %ux%u @ %.1f Hz\n", head, width, height, hz == 0 ? 60.0 : hz);
        }
    }
}

static void cmd_displays(void) {
    puts("creating two 1920x1080@60 virtual displays (CGVirtualDisplay)");
    puts("they live only while this process runs — Ctrl-C to drop them");
    MViewVirtualDisplay *left = NULL, *right = NULL;
    mview_displays_snapshot();
    if (make_head_pair(&left, &right) != 0) {
        fputs("CGVirtualDisplay failed\n", stderr);
        exit(1);
    }
    uint32_t ids[MVIEW_HEADS] = {mview_virtual_display_id(left), mview_virtual_display_id(right)};
    printf("  MView Left   CGDirectDisplayID %u\n", ids[0]);
    printf("  MView Right  CGDirectDisplayID %u\n", ids[1]);
    mview_displays_restore();
    mview_displays_arrange(ids[0], ids[1], MVIEW_HEAD_W, MVIEW_HEAD_H);
    report_head_modes(ids, MVIEW_HEADS);
    report_sidecar_displays();

    signal(SIGINT, SIG_IGN);
    dispatch_source_t interrupt =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(interrupt, ^{
      mview_virtual_display_destroy(left);
      mview_virtual_display_destroy(right);
      puts("virtual displays released");
      exit(0);
    });
    dispatch_resume(interrupt);
    dispatch_main();
}

static void cmd_diagnose(int takeover) {
    if (!takeover) {
        puts("refusing to claim USB while DisplayLink Manager may own it");
        puts("re-run: mview diagnose --takeover");
        return;
    }
    ensure_logs_dir();
    mview_log_open("logs/native-diagnose.log");
    puts("stopping DisplayLink Manager for a control-only native diagnostic…");
    mview_stop_displaylink();
    sleep_seconds(0.6);
    MViewSession *session = mview_session_open(1);
    if (!session) {
        fputs("failed to claim the DisplayLink interface\n", stderr);
        mview_start_displaylink();
        return;
    }
    MViewDriver *driver = mview_driver_engage(session, 0x6000);
    if (!driver) {
        fputs("native encrypted-session engagement failed; see logs/native-diagnose.log\n", stderr);
        mview_session_close(session);
        mview_start_displaylink();
        return;
    }
    int fetch_result = mview_driver_fetch_edids(driver);
    for (int head = 0; head < MVIEW_HEADS; head++) {
        MViewHeadStatus status;
        if (mview_driver_get_head(driver, (uint8_t)head, &status) != 0) {
            continue;
        }
        printf("head %d: selector %u, endpoint 0x%02x, authenticated %s, present %s, "
               "EDID %zu bytes, manufacturer %s\n",
               head, status.ddc_selector, status.video_endpoint,
               status.authenticated ? "true" : "false", status.present ? "true" : "false",
               status.edid_len, status.manufacturer);
    }
    puts(fetch_result == 0 ? "both physical EDIDs validated"
                           : "one or more EDIDs failed validation");
    mview_driver_destroy(driver);
    mview_session_close(session);
    mview_start_displaylink();
    puts("USB claim released; DisplayLink Manager relaunched");
}

/*
 * logs/verify.json. `capture_frames` is NULL for the pattern paths, which have no capture.
 * machine_pass covers everything this process can observe; overall_pass additionally needs
 * a human to say they saw both panels, because a faithfully encoded black frame and a
 * broken encoder are indistinguishable from here.
 */
static int write_verification(MViewSession *session, MViewDriver *driver,
                              const char *expected_output, const int *capture_frames,
                              int capture_head_count, int human_confirmed) {
    uint8_t identity_bytes[64];
    int identity_length =
        mview_session_get_identity(session, identity_bytes, (int)sizeof(identity_bytes));
    MViewIdentity identity;
    memset(&identity, 0, sizeof(identity));
    int identity_valid =
        identity_length > 0 && mview_identity_parse(&identity, identity_bytes, identity_length) == 0;
    char firmware[32] = "";
    if (identity_valid) {
        snprintf(firmware, sizeof(firmware), "%u.%u.%u", identity.firmware[0], identity.firmware[1],
                 identity.firmware[2]);
    }

    MViewHub *hubs = calloc(MVIEW_MAX_HUBS, sizeof(*hubs));
    const char *owner = "";
    if (hubs) {
        int hub_count = mview_usb_probe(hubs, MVIEW_MAX_HUBS);
        for (int i = 0; i < hub_count; i++) {
            if (hubs[i].pid == 0x6000) {
                owner = hubs[i].exclusive_owner;
                break;
            }
        }
    }
    int owner_pass = strcasestr(owner, "mview") != NULL;

    MViewDriverVerification native;
    memset(&native, 0, sizeof(native));
    int native_valid = mview_driver_get_verification(driver, &native) == 0;
    int ake_pass =
        native_valid && native.h_prime_verified && native.l_prime_verified && native.v_prime_verified;
    int cp_pass = native_valid && native.cp_ack_frames > 0;

    MViewHeadStatus heads[MVIEW_HEADS];
    int head_valid[MVIEW_HEADS];
    int head_pass[MVIEW_HEADS];
    int heads_pass = 1;
    for (int head = 0; head < MVIEW_HEADS; head++) {
        memset(&heads[head], 0, sizeof(heads[head]));
        head_valid[head] = mview_driver_get_head(driver, (uint8_t)head, &heads[head]) == 0;
        head_pass[head] = head_valid[head] && heads[head].authenticated && heads[head].present &&
                          heads[head].edid_len >= 256 && strcmp(heads[head].manufacturer, "DEL") == 0;
        heads_pass = heads_pass && head_pass[head];
    }

    unsigned head0_writes = native_valid ? native.video_writes[0] : 0;
    unsigned head1_writes = native_valid ? native.video_writes[1] : 0;
    int video_pass = head0_writes > 0 && head1_writes > 0;
    int capture_pass = 1;
    if (capture_frames) {
        capture_pass = capture_head_count == MVIEW_HEADS;
        for (int head = 0; head < capture_head_count; head++) {
            capture_pass = capture_pass && capture_frames[head] > 0;
        }
    }
    int identity_pass = identity_valid && strcmp(identity.platform, "RidgeDoc") == 0;
    int machine_pass =
        owner_pass && identity_pass && ake_pass && cp_pass && heads_pass && video_pass && capture_pass;

    ensure_logs_dir();
    FILE *file = fopen("logs/verify.json", "w");
    if (!file) {
        fputs("could not write logs/verify.json\n", stderr);
        free(hubs);
        return 0;
    }
    char timestamp[32];
    iso8601_now(timestamp, sizeof(timestamp));

    fputs("{\n", file);
    fprintf(file, "  \"ake\": {\"h_prime\": %s, \"l_prime\": %s, \"v_prime\": %s, \"pass\": %s},\n",
            json_bool(native.h_prime_verified), json_bool(native.l_prime_verified),
            json_bool(native.v_prime_verified), json_bool(ake_pass));
    fprintf(file, "  \"cp\": {\"sealed_ep84_frames\": %u, \"pass\": %s},\n", native.cp_ack_frames,
            json_bool(cp_pass));
    fputs("  \"heads\": [\n", file);
    for (int head = 0; head < MVIEW_HEADS; head++) {
        char endpoint[8] = "";
        if (head_valid[head]) {
            snprintf(endpoint, sizeof(endpoint), "0x%02x", heads[head].video_endpoint);
        }
        fputs("    {", file);
        fprintf(file, "\"logical_head\": %d, \"ddc_selector\": %d, \"video_endpoint\": ", head,
                head_valid[head] ? heads[head].ddc_selector : -1);
        json_puts(file, endpoint);
        fprintf(file, ", \"authenticated\": %s, \"present_bit\": %s, \"edid_bytes\": %zu, ",
                json_bool(head_valid[head] && heads[head].authenticated),
                json_bool(head_valid[head] && heads[head].present),
                head_valid[head] ? heads[head].edid_len : (size_t)0);
        fputs("\"manufacturer\": ", file);
        json_puts(file, head_valid[head] ? heads[head].manufacturer : "");
        fprintf(file, ", \"pass\": %s}%s\n", json_bool(head_pass[head]),
                head + 1 < MVIEW_HEADS ? "," : "");
    }
    fputs("  ],\n", file);
    fputs("  \"identity\": {\"platform\": ", file);
    json_puts(file, identity_valid ? identity.platform : "");
    fputs(", \"firmware\": ", file);
    json_puts(file, firmware);
    fprintf(file, ", \"pass\": %s},\n", json_bool(identity_pass));
    fprintf(file, "  \"machine_pass\": %s,\n", json_bool(machine_pass));
    fprintf(file, "  \"overall_note\": ");
    json_puts(file, human_confirmed
                        ? "a human confirmed both physical Dells for this run"
                        : "overall_pass remains false until a human confirms both physical Dells");
    fprintf(file, ",\n  \"overall_pass\": %s,\n", json_bool(machine_pass && human_confirmed));
    fputs("  \"physical_output\": {\"expected\": ", file);
    json_puts(file, expected_output);
    fprintf(file, ", \"transport_pass\": %s, \"physical_confirmed\": %s", json_bool(video_pass),
            json_bool(human_confirmed));
    if (capture_frames) {
        fputs(", \"capture_frames\": [", file);
        for (int head = 0; head < capture_head_count; head++) {
            fprintf(file, "%s%d", head ? ", " : "", capture_frames[head]);
        }
        fprintf(file, "], \"capture_pass\": %s", json_bool(capture_pass));
    }
    fputs("},\n", file);
    fputs("  \"timestamp\": ", file);
    json_puts(file, timestamp);
    fputs(",\n", file);
    fputs("  \"usb_owner\": {\"value\": ", file);
    json_puts(file, owner);
    fprintf(file, ", \"pass\": %s},\n", json_bool(owner_pass));
    fprintf(file,
            "  \"video\": {\"endpoint_0x08_writes\": %u, \"endpoint_0x0b_writes\": %u, "
            "\"pass\": %s}\n",
            head0_writes, head1_writes, json_bool(video_pass));
    fputs("}\n", file);
    fclose(file);
    free(hubs);

    puts(machine_pass ? "machine verification PASS → logs/verify.json"
                      : "machine verification FAIL → logs/verify.json");
    return machine_pass;
}

/*
 * Record that a human looked at both panels. Deliberately a separate command run after
 * the fact: a --confirmed flag on `run` would be attesting to something the person has
 * not seen yet. The machine writes what it measured; this adds the only claim the machine
 * cannot make, and refuses to add it to a run the machine already knows failed.
 */
static int cmd_confirm(void) {
    FILE *file = fopen("logs/verify.json", "r");
    if (!file) {
        fputs("no logs/verify.json; run `mview run --takeover` or `mview verify` first\n", stderr);
        return 0;
    }
    char text[8192];
    size_t length = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    text[length] = '\0';

    if (!strstr(text, "\"machine_pass\": true")) {
        fputs("machine_pass is false in logs/verify.json; the run failed its own checks and\n"
              "cannot be confirmed. Look at logs/run.log for why.\n",
              stderr);
        return 0;
    }
    char *pass = strstr(text, "\"overall_pass\": false");
    if (!pass) {
        puts("logs/verify.json is already confirmed");
        return 1;
    }
    /* The file is written by write_verification just above, so both spans are fixed-width
       and known; "false" -> "true " keeps every offset stable. */
    memcpy(pass + strlen("\"overall_pass\": "), "true ", 5);
    /* Space-padded to the pending note's exact length rather than counted by hand, so
       every later offset in the buffer stays put. */
    static const char kPending[] =
        "overall_pass remains false until a human confirms both physical Dells";
    static const char kConfirmed[] = "a human confirmed both physical Dells for this run";
    char *note = strstr(text, kPending);
    if (note && sizeof(kConfirmed) <= sizeof(kPending)) {
        size_t written = sizeof(kConfirmed) - 1;
        memcpy(note, kConfirmed, written);
        memset(note + written, ' ', (sizeof(kPending) - 1) - written);
    }
    file = fopen("logs/verify.json", "w");
    if (!file) {
        fputs("could not rewrite logs/verify.json\n", stderr);
        return 0;
    }
    fwrite(text, 1, strlen(text), file);
    fclose(file);
    puts("confirmed → logs/verify.json overall_pass is true");
    return 1;
}

static int cmd_patterns(int takeover, int seconds, int confirmed) {
    if (!takeover) {
        puts("refusing to claim USB while DisplayLink Manager may own it");
        puts("re-run: mview patterns --takeover --seconds 90");
        return 0;
    }
    ensure_logs_dir();
    mview_log_open("logs/native-patterns.log");
    puts("stopping DisplayLink Manager and claiming the Ridge dock…");
    mview_stop_displaylink();
    sleep_seconds(0.6);
    MViewSession *session = mview_session_open(1);
    if (!session) {
        fputs("failed to claim the DisplayLink interface\n", stderr);
        mview_start_displaylink();
        return 0;
    }
    int ok = 0;
    MViewDriver *driver = mview_driver_engage(session, 0x6000);
    if (!driver) {
        fputs("native encrypted-session engagement failed; see logs/native-patterns.log\n", stderr);
        goto release;
    }
    for (int head = 0; head < MVIEW_HEADS; head++) {
        if (mview_driver_fetch_edid(driver, (uint8_t)head) != 0) {
            fprintf(stderr, "head %d did not return a valid physical EDID\n", head);
            goto destroy;
        }
        printf("training physical head %d at 1920x1080@60…\n", head);
        if (mview_driver_activate_1080p60(driver, (uint8_t)head) != 0) {
            fprintf(stderr, "head %d mode activation failed; see logs/native-patterns.log\n", head);
            goto destroy;
        }
    }
    printf("native video active for %ds: head 0 red/blue, head 1 green/yellow\n", seconds);
    time_t deadline = time(NULL) + (seconds > 0 ? seconds : 1);
    int phase = 0;
    while (time(NULL) < deadline) {
        uint8_t h0[3] = {phase ? 0 : 255, 0, phase ? 255 : 0};
        uint8_t h1[3] = {phase ? 255 : 0, 255, 0};
        if (mview_driver_present_solid(driver, 0, h0[0], h0[1], h0[2]) < 0 ||
            mview_driver_present_solid(driver, 1, h1[0], h1[1], h1[2]) < 0) {
            fputs("video presentation failed; see logs/native-patterns.log\n", stderr);
            goto destroy;
        }
        phase = !phase;
        sleep_seconds(1);
    }
    ok = write_verification(session, driver,
                            "head 0 red/blue; head 1 green/yellow, alternating each second", NULL,
                            0, confirmed);
destroy:
    mview_driver_destroy(driver);
release:
    mview_session_close(session);
    mview_start_displaylink();
    puts("USB claim released; DisplayLink Manager relaunched");
    return ok;
}

/* run() owns these so the signal and watchdog handlers can tear down from any thread. */
static struct {
    MViewCapture *capture;
    MViewVirtualDisplay *left;
    MViewVirtualDisplay *right;
    MViewDriver *driver;
    MViewSession *session;
    int shutting_down;
} g_run;

static void run_shutdown(const char *reason, int code) {
    if (g_run.shutting_down) {
        return;
    }
    g_run.shutting_down = 1;
    puts(reason);
    if (g_run.capture) {
        mview_capture_stop(g_run.capture);
        g_run.capture = NULL;
    }
    mview_virtual_display_destroy(g_run.left);
    mview_virtual_display_destroy(g_run.right);
    g_run.left = g_run.right = NULL;
    if (g_run.driver) {
        mview_driver_destroy(g_run.driver);
        g_run.driver = NULL;
    }
    if (g_run.session) {
        mview_session_close(g_run.session);
        g_run.session = NULL;
    }
    mview_start_displaylink();
    puts("released hub, DisplayLink Manager relaunched");
    exit(code);
}

static int cmd_run(int takeover, int profile) {
    if (!takeover) {
        puts("refusing to claim USB while DisplayLink Manager may own it");
        puts("re-run: mview run --takeover");
        return 0;
    }
    ensure_logs_dir();
    mview_log_open("logs/run.log");
    puts("logging to logs/run.log");
    puts("stopping DisplayLink Manager…");
    mview_stop_displaylink();
    sleep_seconds(0.6);

    g_run.session = mview_session_open(1);
    if (!g_run.session) {
        fputs("failed to claim IOUSBHostInterface ff/00/03\n", stderr);
        mview_start_displaylink();
        return 0;
    }
    g_run.driver = mview_driver_engage(g_run.session, 0x6000);
    if (!g_run.driver) {
        fputs("native encrypted-session engagement failed; see logs/run.log\n", stderr);
        mview_session_close(g_run.session);
        mview_start_displaylink();
        return 0;
    }
    for (int head = 0; head < MVIEW_HEADS; head++) {
        if (mview_driver_fetch_edid(g_run.driver, (uint8_t)head) != 0 ||
            mview_driver_activate_1080p60(g_run.driver, (uint8_t)head) != 0) {
            fprintf(stderr, "physical head %d failed EDID or mode activation; see logs/run.log\n",
                    head);
            run_shutdown("aborting", 1);
        }
    }
    /* Creating virtual displays re-lays-out the whole desktop, the iPad included. Take the
       arrangement first so it can be put back. */
    mview_displays_snapshot();
    if (make_head_pair(&g_run.left, &g_run.right) != 0) {
        fputs("could not create the MView CGVirtualDisplays on unshared display units\n", stderr);
        run_shutdown("aborting", 1);
    }
    uint32_t ids[MVIEW_HEADS] = {mview_virtual_display_id(g_run.left),
                                 mview_virtual_display_id(g_run.right)};
    mview_displays_restore();
    if (mview_displays_arrange(ids[0], ids[1], MVIEW_HEAD_W, MVIEW_HEAD_H) != 0) {
        fputs("could not seat the MView heads; check System Settings > Displays\n", stderr);
    }
    printf("physical endpoints trained; virtual displays %u, %u\n", ids[0], ids[1]);
    report_head_modes(ids, MVIEW_HEADS);
    /* Sidecar reports through several reconfiguration callbacks as it attaches and the
       mirror set is not in place until the last of them, so one arrange at startup can land
       before the state it is meant to fix even exists. Retry, then keep watching. */
    for (int attempt = 0; attempt < 5; attempt++) {
        int mirrored = 0;
        for (int head = 0; head < MVIEW_HEADS; head++) {
            mirrored = mirrored || mview_display_is_mirrored(ids[head]);
        }
        if (!mirrored) {
            break;
        }
        sleep_seconds(0.4);
        mview_displays_arrange(ids[0], ids[1], MVIEW_HEAD_W, MVIEW_HEAD_H);
    }
    for (int head = 0; head < MVIEW_HEADS; head++) {
        /* Encoding a mirror would drive the dock with some other display's desktop, at that
           display's aspect ratio. */
        if (mview_display_is_mirrored(ids[head])) {
            fprintf(stderr, "head %d is still in a mirror set; turn mirroring off for it\n", head);
            run_shutdown("aborting", 1);
        }
    }
    mview_displays_watch(ids[0], ids[1], MVIEW_HEAD_W, MVIEW_HEAD_H);
    report_sidecar_displays();

    puts("starting ScreenCaptureKit desktop forwarding…");
    char capture_error[256] = "";
    g_run.capture =
        mview_capture_start(ids, MVIEW_HEADS, g_run.driver, capture_error, sizeof(capture_error));
    if (!g_run.capture) {
        fprintf(stderr, "ScreenCaptureKit start failed: %s\n", capture_error);
        fputs("grant Screen Recording access to mview, then retry\n", stderr);
        run_shutdown("aborting", 1);
    }
    for (int waited = 0; waited < 50; waited++) {
        int ready = 1;
        for (int head = 0; head < MVIEW_HEADS; head++) {
            ready = ready && mview_capture_frames(g_run.capture, head) > 0;
        }
        if (ready) {
            break;
        }
        sleep_seconds(0.1);
    }
    int frames[MVIEW_HEADS];
    for (int head = 0; head < MVIEW_HEADS; head++) {
        frames[head] = mview_capture_frames(g_run.capture, head);
        if (frames[head] == 0) {
            fputs("ScreenCaptureKit delivered no initial frame for both heads\n", stderr);
            run_shutdown("aborting", 1);
        }
    }
    mview_capture_start_refresh_clock(g_run.capture, g_run.driver, MVIEW_HEADS, 100);
    write_verification(g_run.session, g_run.driver,
                       "head 0 MView Left Haar desktop; head 1 MView Right Haar desktop", frames,
                       MVIEW_HEADS, 0);
    puts("");
    puts("live extended desktop active. Look at both Dells now:");
    puts("  - each panel shows its own half of the desktop, not a copy of the other");
    puts("  - dragging a window across updates without smearing or stale blocks");
    puts("  - the picture survives a still desktop for a minute (that is the keepalive)");
    puts("");
    puts("Ctrl-C restores DisplayLink Manager. If both panels were right, then run:");
    puts("  build/mview confirm");

    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    dispatch_queue_t main_queue = dispatch_get_main_queue();
    dispatch_source_t interrupt =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, main_queue);
    dispatch_source_set_event_handler(interrupt, ^{
      run_shutdown("interrupt received", 0);
    });
    dispatch_resume(interrupt);
    dispatch_source_t terminate =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, main_queue);
    dispatch_source_set_event_handler(terminate, ^{
      run_shutdown("termination requested", 0);
    });
    dispatch_resume(terminate);

    dispatch_source_t watchdog =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, main_queue);
    dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(watchdog, ^{
      for (int head = 0; head < MVIEW_HEADS; head++) {
          if (mview_capture_failure(g_run.capture, head)) {
              char reason[96];
              snprintf(reason, sizeof(reason),
                       "head %d forwarding failed; restoring vendor driver", head);
              run_shutdown(reason, 1);
          }
      }
    });
    dispatch_resume(watchdog);

    /* Live-path profile. The encoder zones alone say nothing about why a desktop feels
       sluggish: the capture callbacks, the control clocks and the USB writes all share one
       serial queue, and it is the sum of their wall time against the wall clock that says
       whether that queue is saturated. */
    dispatch_source_t reporter = NULL;
    if (profile) {
        mview_profile_enable(1);
        mview_profile_reset();
        reporter = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, main_queue);
        dispatch_source_set_timer(reporter, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(reporter, ^{
          static int window;
          char title[96];
          int frames0 = mview_capture_frames(g_run.capture, 0);
          int frames1 = mview_capture_frames(g_run.capture, 1);
          snprintf(title, sizeof(title), "5 s window %d — capture frames %d / %d", ++window,
                   frames0, frames1);
          mview_profile_report(title);
          mview_profile_reset();
        });
        dispatch_resume(reporter);
    }
    dispatch_main();
    return 1;
}

int main(int argc, char **argv) {
    const char *command = argc > 1 ? argv[1] : "help";
    int rest_argc = argc > 2 ? argc - 2 : 0;
    char **rest = argv + 2;
    int takeover = has_flag(rest_argc, rest, "--takeover");
    int confirmed = has_flag(rest_argc, rest, "--confirmed");

    if (strcmp(command, "probe") == 0) {
        cmd_probe();
    } else if (strcmp(command, "displays") == 0) {
        cmd_displays();
    } else if (strcmp(command, "diagnose") == 0) {
        cmd_diagnose(takeover);
    } else if (strcmp(command, "patterns") == 0) {
        return cmd_patterns(takeover, seconds_argument(rest_argc, rest, 90), confirmed) ? 0 : 1;
    } else if (strcmp(command, "verify") == 0) {
        return cmd_patterns(takeover, seconds_argument(rest_argc, rest, 3), confirmed) ? 0 : 1;
    } else if (strcmp(command, "run") == 0) {
        return cmd_run(takeover, has_flag(rest_argc, rest, "--profile")) ? 0 : 1;
    } else if (strcmp(command, "confirm") == 0) {
        return cmd_confirm() ? 0 : 1;
    } else if (strcmp(command, "bench") == 0) {
        return mview_bench_encoder();
    } else if (strcmp(command, "profile") == 0) {
        return mview_profile_encoder();
    } else if (strcmp(command, "stop-dlm") == 0) {
        mview_stop_displaylink();
        puts("DisplayLink Manager jobs stopped");
    } else if (strcmp(command, "start-dlm") == 0) {
        mview_start_displaylink();
        puts("asked LaunchServices to open DisplayLink Manager");
    } else {
        print_usage();
    }
    return 0;
}
