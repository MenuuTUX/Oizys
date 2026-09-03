#include "oizys_config.h"
#include "oizys_usb.h"

#include "oizys_platform.h"
#include "oizys_build.h"
#include <math.h>
#include <pwd.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/*
 * Flat dotted keys, not nested objects. The file is meant to be edited by hand and read by
 * the menu-bar app, and a flat map means get and set are a dictionary lookup instead of a
 * path walk. One table below drives parsing, clamping, listing and writing.
 */

typedef enum {
    FIELD_INT,
    FIELD_DOUBLE,
    FIELD_BOOL,
    FIELD_HEADS,   /* "left", "right", "left,right" */
    FIELD_HEADREF, /* "none", "left", "right" */
    FIELD_STRING,  /* one of a fixed set of words */
    FIELD_TEXT,    /* free-form; a device name is whatever the owner called it */
} FieldType;

typedef struct {
    const char *key;
    FieldType type;
    size_t offset;
    size_t capacity; /* FIELD_STRING and FIELD_TEXT only */
    const char *fallback;
    double low;
    double high;
} Field;

#define F(key, type, member, fallback, low, high) \
    {key, type, offsetof(OizysConfig, member), 0, fallback, low, high}
#define FS(key, member, fallback) \
    {key, FIELD_STRING, offsetof(OizysConfig, member), sizeof(((OizysConfig *)0)->member), \
     fallback, 0, 0}
#define FT(key, member, fallback) \
    {key, FIELD_TEXT, offsetof(OizysConfig, member), sizeof(((OizysConfig *)0)->member), \
     fallback, 0, 0}

static const Field FIELDS[] = {
    F("heads.active", FIELD_HEADS, heads_active, "left,right", 0, 0),
    F("heads.native", FIELD_HEADREF, heads_native, "none", 0, 0),
    F("head.width", FIELD_INT, head_width, "1920", 640, 7680),
    F("head.height", FIELD_INT, head_height, "1080", 480, 4320),
    F("head.refresh_hz", FIELD_DOUBLE, head_refresh_hz, "60", 24, 240),
    F("capture.fps", FIELD_INT, capture_fps, "60", 1, 240),
    F("capture.queue_depth", FIELD_INT, capture_queue_depth, "3", 1, 8),
    F("capture.dump_frames", FIELD_BOOL, capture_dump_frames, "false", 0, 1),
    /*
     * Per-head power behaviour. Two opposite problems, one per key, because a pair of
     * monitors does not necessarily have the same one.
     *
     * keepalive_s: a panel drops to standby on its own once its input stops changing, and an
     * idle desktop puts zero bytes on the video endpoint by design. Repainting the cached
     * strips every N seconds costs no capture and no encode, and stops that happening.
     *
     * standby_min: the opposite. Blank the head after this long still, so a monitor that
     * would otherwise stay lit on an unused desk goes dark. Blanking is instant to undo,
     * unlike deactivating the head, because the display itself never goes away.
     */
    F("head.left.keepalive_s", FIELD_INT, head_keepalive_s[0], "0", 0, 600),
    F("head.right.keepalive_s", FIELD_INT, head_keepalive_s[1], "0", 0, 600),
    F("head.left.standby_min", FIELD_INT, head_standby_min[0], "0", 0, 240),
    F("head.right.standby_min", FIELD_INT, head_standby_min[1], "0", 0, 240),
    /* Capture, encode and USB all scale with frame rate, so the cheapest thing an idle
     * desktop can do is ask for fewer frames. Nothing is lost: a still desktop has nothing
     * to send either way, and the first change restores the full rate. */
    F("power.saving", FIELD_BOOL, power_saving, "true", 0, 1),
    F("power.idle_fps", FIELD_INT, power_idle_fps, "10", 1, 240),
    F("power.idle_after_s", FIELD_INT, power_idle_after_s, "20", 1, 600),
    /* Dims the signal Oizys encodes for a head. A DisplayLink output has no I2C path to the
     * monitor, so its backlight is not reachable; this is the only brightness control that
     * works on a dock-driven panel. It can only darken -- above unity would clip. */
    F("head.left.brightness", FIELD_INT, head_brightness[0], "100", 10, 100),
    F("head.right.brightness", FIELD_INT, head_brightness[1], "100", 10, 100),
    /* Contrast is the other half of the same encoder pass, and the range is not the same
     * shape: brightness scales from black so unity is its ceiling, while contrast pivots on
     * mid-grey and has to go both ways to mean anything. Above 100 clips highlights. */
    F("head.left.contrast", FIELD_INT, head_contrast[0], "100", 50, 150),
    F("head.right.contrast", FIELD_INT, head_contrast[1], "100", 50, 150),
    /* Load-bearing. Polling the dock harder than this reads back as a false disconnect. */
    F("control.poll_ms", FIELD_INT, control_poll_ms, "13", 8, 50),
    F("control.heartbeat_s", FIELD_INT, control_heartbeat_s, "3", 1, 10),
    F("refresh_clock_hz", FIELD_INT, refresh_clock_hz, "100", 20, 1000),
    F("codec.ceiling.sync", FIELD_INT, codec_ceiling_sync, "7", 1, 15),
    F("codec.ceiling.dc", FIELD_INT, codec_ceiling_dc, "10", 1, 15),
    F("codec.ceiling.chroma_ac", FIELD_INT, codec_ceiling_chroma_ac, "10", 1, 15),
    F("codec.ceiling.luma_ac", FIELD_INT, codec_ceiling_luma_ac, "9", 1, 15),
    F("encode.parallel_threshold", FIELD_INT, encode_parallel_threshold, "64", 1, 2040),
    /* The dock rotates over this many buffers; 2 and 3 are the only values it has shown. */
    F("dock.buffers", FIELD_INT, dock_buffers, "2", 2, 3),
    F("displaylink.auto_stop", FIELD_BOOL, displaylink_auto_stop, "true", 0, 1),
    /*
     * Creating a virtual display makes the window server re-lay-out every screen, and it
     * does not only move them: for a combination of screens it has seen before it restores
     * that combination's stored resolution, and "built-in + Sidecar + two Oizys heads" is a
     * combination almost nobody has deliberately configured. The built-in panel comes back
     * a scaled step smaller, and because the layout that follows is committed permanently,
     * the smaller size is then what that combination means from then on. Putting every
     * display's mode back alongside its origin is what stops one attach shrinking a desktop
     * for good. Off leaves whatever macOS chose.
     */
    F("display.keep_modes", FIELD_BOOL, display_keep_modes, "true", 0, 1),
    /*
     * Sidecar. Off by default: attaching a display is not something to start doing to
     * someone who only installed a dock driver. On, the iPad is connected when it turns up
     * and the Mac looks like a desk -- see sidecar.require_desk, which is the difference
     * between a docked Mac and one on a sofa. A disconnect made by hand is respected.
     */
    F("sidecar.auto_connect", FIELD_BOOL, sidecar_auto_connect, "false", 0, 1),
    F("sidecar.require_desk", FIELD_BOOL, sidecar_require_desk, "true", 0, 1),
    FT("sidecar.device", sidecar_device, ""),
    /*
     * An iPad's backlight is not reachable from this Mac: macOS reports the Sidecar display
     * as not brightness-changeable, and Oizys never sees those pixels either -- Apple
     * composites and sends them. What is reachable is the display's transfer table, which
     * every display has, so these two are a gamma ramp rather than a backlight or an encoder
     * gain. Same arithmetic as the heads: brightness scales from black, contrast pivots on
     * mid-grey and runs either side of unity.
     */
    F("sidecar.brightness", FIELD_INT, sidecar_brightness, "100", 10, 100),
    F("sidecar.contrast", FIELD_INT, sidecar_contrast, "100", 50, 150),
    FS("log.level", log_level, "info"),
};

static const size_t FIELD_COUNT = sizeof(FIELDS) / sizeof(FIELDS[0]);

/* Offsets come from offsetof, so they are aligned by construction -- but the compiler
 * cannot see that through a char*, and -Wcast-align is on for good reasons elsewhere. */
static void *member(OizysConfig *config, size_t offset) {
    return (char *)config + offset;
}

static const void *member_const(const OizysConfig *config, size_t offset) {
    return (const char *)config + offset;
}

static const Field *find_field(const char *key) {
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        if (strcmp(FIELDS[i].key, key) == 0) {
            return &FIELDS[i];
        }
    }
    return NULL;
}

static const char *const LOG_LEVELS[] = {"debug", "info", "warn", "error", NULL};

/* -- parse ---------------------------------------------------------------------------- */

static int parse_bool(const char *text, int *out) {
    static const char *const yes[] = {"1", "true", "yes", "on", NULL};
    static const char *const no[] = {"0", "false", "no", "off", NULL};
    for (int i = 0; yes[i]; i++) {
        if (strcasecmp(text, yes[i]) == 0) {
            *out = 1;
            return 0;
        }
    }
    for (int i = 0; no[i]; i++) {
        if (strcasecmp(text, no[i]) == 0) {
            *out = 0;
            return 0;
        }
    }
    return -1;
}

static int parse_heads(const char *text, uint32_t *out) {
    uint32_t mask = 0;
    const char *cursor = text;
    while (*cursor) {
        while (*cursor == ',' || *cursor == ' ') {
            cursor++;
        }
        if (strncasecmp(cursor, "left", 4) == 0) {
            mask |= OIZYS_HEAD_LEFT;
            cursor += 4;
        } else if (strncasecmp(cursor, "right", 5) == 0) {
            mask |= OIZYS_HEAD_RIGHT;
            cursor += 5;
        } else if (strncasecmp(cursor, "both", 4) == 0) {
            mask |= OIZYS_HEAD_BOTH;
            cursor += 4;
        } else if (*cursor) {
            return -1;
        }
    }
    if (mask == 0) {
        return -1;
    }
    *out = mask;
    return 0;
}

static int parse_headref(const char *text, int *out) {
    if (strcasecmp(text, "none") == 0 || strcasecmp(text, "null") == 0 || text[0] == '\0') {
        *out = -1;
        return 0;
    }
    if (strcasecmp(text, "left") == 0 || strcmp(text, "0") == 0) {
        *out = 0;
        return 0;
    }
    if (strcasecmp(text, "right") == 0 || strcmp(text, "1") == 0) {
        *out = 1;
        return 0;
    }
    return -1;
}

static double clamp(double value, const Field *field, const char *key, int *clamped) {
    if (field->low == field->high) {
        return value;
    }
    if (value < field->low) {
        *clamped = 1;
        oizys_log("config %s=%g below the safe range, clamped to %g", key, value, field->low);
        return field->low;
    }
    if (value > field->high) {
        *clamped = 1;
        oizys_log("config %s=%g above the safe range, clamped to %g", key, value, field->high);
        return field->high;
    }
    return value;
}

/* 0 on success, -2 when the text will not parse. Out-of-range values clamp and succeed. */
static int apply(OizysConfig *config, const Field *field, const char *text) {
    int clamped = 0;
    switch (field->type) {
    case FIELD_INT: {
        char *end = NULL;
        double value = strtod(text, &end);
        if (end == text || *end || !isfinite(value)) {
            return -2;
        }
        *(int *)member(config, field->offset) = (int)clamp(value, field, field->key, &clamped);
        return 0;
    }
    case FIELD_DOUBLE: {
        char *end = NULL;
        double value = strtod(text, &end);
        if (end == text || *end || !isfinite(value)) {
            return -2;
        }
        *(double *)member(config, field->offset) = clamp(value, field, field->key, &clamped);
        return 0;
    }
    case FIELD_BOOL: {
        int value = 0;
        if (parse_bool(text, &value) != 0) {
            return -2;
        }
        *(int *)member(config, field->offset) = value;
        return 0;
    }
    case FIELD_HEADS: {
        uint32_t mask = 0;
        if (parse_heads(text, &mask) != 0) {
            return -2;
        }
        *(uint32_t *)member(config, field->offset) = mask;
        return 0;
    }
    case FIELD_HEADREF: {
        int value = -1;
        if (parse_headref(text, &value) != 0) {
            return -2;
        }
        *(int *)member(config, field->offset) = value;
        return 0;
    }
    case FIELD_TEXT:
        snprintf((char *)member(config, field->offset), field->capacity, "%s", text);
        return 0;
    case FIELD_STRING: {
        for (int i = 0; LOG_LEVELS[i]; i++) {
            if (strcasecmp(text, LOG_LEVELS[i]) == 0) {
                snprintf((char *)member(config, field->offset), field->capacity, "%s",
                         LOG_LEVELS[i]);
                return 0;
            }
        }
        return -2;
    }
    }
    return -2;
}

static void render(const OizysConfig *config, const Field *field, char *out, size_t capacity) {
    switch (field->type) {
    case FIELD_INT:
        snprintf(out, capacity, "%d", *(const int *)member_const(config, field->offset));
        return;
    case FIELD_DOUBLE:
        snprintf(out, capacity, "%g", *(const double *)member_const(config, field->offset));
        return;
    case FIELD_BOOL:
        snprintf(out, capacity, "%s", *(const int *)member_const(config, field->offset) ? "true" : "false");
        return;
    case FIELD_HEADS: {
        uint32_t mask = *(const uint32_t *)member_const(config, field->offset);
        snprintf(out, capacity, "%s",
                 mask == OIZYS_HEAD_BOTH  ? "left,right"
                 : mask == OIZYS_HEAD_LEFT ? "left"
                                           : "right");
        return;
    }
    case FIELD_HEADREF: {
        int value = *(const int *)member_const(config, field->offset);
        snprintf(out, capacity, "%s", value == 0 ? "left" : value == 1 ? "right" : "none");
        return;
    }
    case FIELD_STRING:
    case FIELD_TEXT:
        snprintf(out, capacity, "%s", (const char *)member_const(config, field->offset));
        return;
    }
    snprintf(out, capacity, "?");
}

static void load_defaults(OizysConfig *config) {
    memset(config, 0, sizeof(*config));
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        int rc = apply(config, &FIELDS[i], FIELDS[i].fallback);
        assert(rc == 0 && "a built-in default must parse");
        (void)rc;
    }
}

/* -- file ----------------------------------------------------------------------------- */

const char *oizys_config_path(void) {
    static char cached[4096];
    if (!cached[0]) {
        const char *override = getenv("OIZYS_CONFIG_PATH");
        struct passwd *user = getpwuid(getuid());
        const char *home = user ? user->pw_dir : getenv("HOME");
        if (override && *override) snprintf(cached, sizeof(cached), "%s", override);
        else {
#if OIZYS_DIAGNOSTICS
            const char *variant = OIZYS_ALLOW_DISPLAYLINK ? "debug-fallback" :
                                  OIZYS_VERBOSE ? "debug-verbose" : "debug-minimal";
            snprintf(cached, sizeof(cached), "%s/Library/Application Support/Oizys/Debug/%s/config.json",
                     home ? home : "/nonexistent", variant);
#else
            snprintf(cached, sizeof(cached), "%s/Library/Application Support/Oizys/config.json",
                     home ? home : "/nonexistent");
#endif
        }
    }
    return cached;
}

static void read_value(void *context, const char *key, const char *value) {
    OizysConfig *config = context;
    const Field *field = find_field(key);
    if (!field || apply(config, field, value) != 0)
        oizys_log("config: ignoring invalid key/value for %s", key);
}

/* -- public --------------------------------------------------------------------------- */

static OizysConfig g_config;
static int g_loaded;

const OizysConfig *oizys_config(void) {
    if (g_loaded) {
        return &g_config;
    }
    load_defaults(&g_config);
    oizys_settings_read(oizys_config_path(), &g_config, read_value);
#if !OIZYS_DIAGNOSTICS
    g_config.capture_dump_frames = 0;
    snprintf(g_config.log_level, sizeof(g_config.log_level), "error");
#elif OIZYS_VERBOSE
    snprintf(g_config.log_level, sizeof(g_config.log_level), "debug");
#endif
    g_loaded = 1;
    return &g_config;
}

void oizys_config_reload(void) {
    g_loaded = 0;
}

/*
 * A running driver reads its settings from the cache, so a change made anywhere else -- the
 * menu bar, `oizys config set`, an editor -- would otherwise wait for a restart. That is the
 * wrong shape for a brightness slider. One stat per second is cheap enough to sit on the
 * control path, and mtime is the only thing that has to be compared: any write to the file
 * moves it, and the read that follows is the same read startup does.
 */
int oizys_config_refresh_if_changed(void) {
    static time_t last_seen;
    static time_t last_checked;
    time_t now = time(NULL);
    if (now == last_checked) {
        return 0;
    }
    last_checked = now;
    struct stat info;
    time_t stamp = stat(oizys_config_path(), &info) == 0 ? info.st_mtime : 0;
    if (stamp == last_seen) {
        return 0;
    }
    last_seen = stamp;
    /* The first observation is the state the cache was already built from. */
    static int primed;
    if (!primed) {
        primed = 1;
        return 0;
    }
    oizys_config_reload();
    return 1;
}

int oizys_config_head_keepalive_s(int head) {
    if (head < 0 || head > 1) {
        return 0;
    }
    return oizys_config()->head_keepalive_s[head];
}

int oizys_config_head_standby_s(int head) {
    if (head < 0 || head > 1) {
        return 0;
    }
    return oizys_config()->head_standby_min[head] * 60;
}

int oizys_config_head_gain_q8(int head) {
    if (head < 0 || head > 1) {
        return 256;
    }
    int percent = oizys_config()->head_brightness[head];
    return percent * 256 / 100;
}

int oizys_config_keep_modes(void) {
    return oizys_config()->display_keep_modes;
}

int oizys_config_head_contrast_q8(int head) {
    if (head < 0 || head > 1) {
        return 256;
    }
    return oizys_config()->head_contrast[head] * 256 / 100;
}

int oizys_config_head_active(int head) {
    if (head < 0 || head > 1) {
        return 0;
    }
    return (oizys_config()->heads_active & (head == 0 ? OIZYS_HEAD_LEFT : OIZYS_HEAD_RIGHT)) != 0;
}

void oizys_config_print(FILE *out) {
    const OizysConfig *config = oizys_config();
    OizysConfig defaults;
    load_defaults(&defaults);
    fprintf(out, "%s\n\n", oizys_config_path());
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        char value[64], fallback[64];
        render(config, &FIELDS[i], value, sizeof(value));
        render(&defaults, &FIELDS[i], fallback, sizeof(fallback));
        if (strcmp(value, fallback) == 0) {
            fprintf(out, "  %-28s %s\n", FIELDS[i].key, value);
        } else {
            fprintf(out, "  %-28s %-14s (default %s)\n", FIELDS[i].key, value, fallback);
        }
    }
}

int oizys_config_get(const char *key, char *out, size_t capacity) {
    const Field *field = key ? find_field(key) : NULL;
    if (!field || !out) {
        return -1;
    }
    render(oizys_config(), field, out, capacity);
    return 0;
}

int oizys_config_set(const char *key, const char *value) {
    const Field *field = key ? find_field(key) : NULL;
    if (!field) {
        return -1;
    }
    /* Parse into a scratch copy first: a value that will not parse must not be persisted. */
    OizysConfig scratch = *oizys_config();
    if (apply(&scratch, field, value ? value : "") != 0) {
        return -2;
    }
    char canonical[64];
    render(&scratch, field, canonical, sizeof(canonical));
    if (oizys_settings_write(oizys_config_path(), key, canonical,
                             field->type == FIELD_INT || field->type == FIELD_DOUBLE ? 1 :
                             field->type == FIELD_BOOL ? 2 : 0) != 0) return -1;
    oizys_config_reload();
    return 0;
}

int oizys_config_reset(void) {
    if (oizys_settings_reset(oizys_config_path()) != 0) return -1;
    oizys_config_reload();
    return 0;
}

/* -- self-test ------------------------------------------------------------------------ */

/*
 * Not assert(): Release defines NDEBUG, and a check that evaporates in the configuration
 * people actually run is not a check. Reports the first failure and keeps going.
 */
static int g_failures;
#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            g_failures++;                                                      \
            fprintf(stderr, "config selftest: %s:%d %s\n", __FILE__, __LINE__, \
                    #condition);                                               \
        }                                                                      \
    } while (0)

int oizys_config_selftest(void) {
    g_failures = 0;
    OizysConfig config;
    load_defaults(&config);

    /* Defaults are the constants the driver used before this file existed. */
    CHECK(config.heads_active == OIZYS_HEAD_BOTH);
    CHECK(config.heads_native == -1);
    CHECK(config.head_width == 1920 && config.head_height == 1080);
    CHECK(config.control_poll_ms == 13);
    CHECK(config.dock_buffers == 2);
    CHECK(config.codec_ceiling_luma_ac == 9);
    CHECK(strcmp(config.log_level, "info") == 0);

    /* A too-aggressive poll clamps up rather than reaching the dock. */
    CHECK(apply(&config, find_field("control.poll_ms"), "5") == 0);
    CHECK(config.control_poll_ms == 8);
    CHECK(apply(&config, find_field("control.poll_ms"), "900") == 0);
    CHECK(config.control_poll_ms == 50);

    /* dock.buffers has exactly two legal values. */
    CHECK(apply(&config, find_field("dock.buffers"), "1") == 0 && config.dock_buffers == 2);
    CHECK(apply(&config, find_field("dock.buffers"), "9") == 0 && config.dock_buffers == 3);

    /* Keepalive and standby are per head and independent: a pair of monitors does not
     * necessarily have the same problem, which is the whole reason these are not one key. */
    CHECK(config.head_keepalive_s[0] == 0 && config.head_standby_min[0] == 0);
    CHECK(apply(&config, find_field("head.left.keepalive_s"), "30") == 0);
    CHECK(config.head_keepalive_s[0] == 30 && config.head_keepalive_s[1] == 0);
    CHECK(apply(&config, find_field("head.right.standby_min"), "4") == 0);
    CHECK(config.head_standby_min[1] == 4 && config.head_standby_min[0] == 0);
    CHECK(apply(&config, find_field("head.left.standby_min"), "9999") == 0);
    CHECK(config.head_standby_min[0] == 240);

    /* Power saving is on by default, and the idle rate is below any sane capture rate. */
    CHECK(config.power_saving == 1);
    CHECK(config.power_idle_fps == 10 && config.power_idle_after_s == 20);

    /* Brightness is a percentage that becomes a Q8 gain, and it can only ever darken. */
    CHECK(config.head_brightness[0] == 100 && config.head_brightness[1] == 100);
    CHECK(apply(&config, find_field("head.left.brightness"), "50") == 0);
    CHECK(config.head_brightness[0] == 50 && config.head_brightness[1] == 100);
    CHECK(apply(&config, find_field("head.left.brightness"), "400") == 0);
    CHECK(config.head_brightness[0] == 100);
    CHECK(apply(&config, find_field("head.right.brightness"), "0") == 0);
    CHECK(config.head_brightness[1] == 10);

    /* Contrast is unity by default and clamps either side of it, because it pivots on
     * mid-grey rather than scaling from black. */
    CHECK(config.head_contrast[0] == 100 && config.head_contrast[1] == 100);
    CHECK(apply(&config, find_field("head.left.contrast"), "140") == 0);
    CHECK(config.head_contrast[0] == 140 && config.head_contrast[1] == 100);
    CHECK(apply(&config, find_field("head.left.contrast"), "900") == 0);
    CHECK(config.head_contrast[0] == 150);
    CHECK(apply(&config, find_field("head.right.contrast"), "1") == 0);
    CHECK(config.head_contrast[1] == 50);

    /* Garbage is refused, and the field keeps what it had. */
    CHECK(apply(&config, find_field("head.width"), "wide") == -2);
    CHECK(apply(&config, find_field("capture.dump_frames"), "maybe") == -2);
    CHECK(apply(&config, find_field("log.level"), "chatty") == -2);
    CHECK(apply(&config, find_field("heads.active"), "middle") == -2);
    CHECK(apply(&config, find_field("heads.active"), "") == -2);
    CHECK(config.head_width == 1920);

    /* Head selection round-trips through its text form. */
    char text[64];
    CHECK(apply(&config, find_field("heads.active"), "left") == 0);
    render(&config, find_field("heads.active"), text, sizeof(text));
    CHECK(strcmp(text, "left") == 0);
    CHECK(apply(&config, find_field("heads.active"), "LEFT, right") == 0);
    CHECK(config.heads_active == OIZYS_HEAD_BOTH);
    CHECK(apply(&config, find_field("heads.native"), "right") == 0 && config.heads_native == 1);
    CHECK(apply(&config, find_field("heads.native"), "none") == 0 && config.heads_native == -1);

    /* Every field renders to something its own parser accepts. */
    OizysConfig round;
    load_defaults(&round);
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        render(&round, &FIELDS[i], text, sizeof(text));
        CHECK(apply(&round, &FIELDS[i], text) == 0);
    }

    /* Keeping other displays' resolutions is on: the shrunken-desktop bug it prevents is
     * silent, permanent and not obviously caused by us. Sidecar stays off until asked. */
    CHECK(config.display_keep_modes == 1);
    CHECK(config.sidecar_auto_connect == 0 && config.sidecar_require_desk == 1);
    CHECK(config.sidecar_device[0] == '\0');
    CHECK(config.sidecar_brightness == 100 && config.sidecar_contrast == 100);
    CHECK(apply(&config, find_field("sidecar.brightness"), "1") == 0);
    CHECK(config.sidecar_brightness == 10);
    CHECK(apply(&config, find_field("sidecar.contrast"), "999") == 0);
    CHECK(config.sidecar_contrast == 150);

    /* A device name is whatever its owner typed, spaces and apostrophes included, and it
     * round-trips unchanged. Longer than the field truncates rather than failing: a name
     * that matches on its first 63 characters is still the right iPad. */
    CHECK(apply(&config, find_field("sidecar.device"), "shib's iPad Pro") == 0);
    CHECK(strcmp(config.sidecar_device, "shib's iPad Pro") == 0);
    render(&config, find_field("sidecar.device"), text, sizeof(text));
    CHECK(strcmp(text, "shib's iPad Pro") == 0);
    CHECK(apply(&config, find_field("sidecar.device"), "") == 0);
    CHECK(config.sidecar_device[0] == '\0');

    CHECK(find_field("no.such.key") == NULL);
    return g_failures;
}
