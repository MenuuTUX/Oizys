#include "mview_config.h"
#include "mview_usb.h"

#include "mview_platform.h"
#include "mview_build.h"
#include <math.h>
#include <pwd.h>
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
    FIELD_STRING,
} FieldType;

typedef struct {
    const char *key;
    FieldType type;
    size_t offset;
    size_t capacity; /* FIELD_STRING only */
    const char *fallback;
    double low;
    double high;
} Field;

#define F(key, type, member, fallback, low, high) \
    {key, type, offsetof(MViewConfig, member), 0, fallback, low, high}
#define FS(key, member, fallback) \
    {key, FIELD_STRING, offsetof(MViewConfig, member), sizeof(((MViewConfig *)0)->member), \
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
    FS("log.level", log_level, "info"),
};

static const size_t FIELD_COUNT = sizeof(FIELDS) / sizeof(FIELDS[0]);

/* Offsets come from offsetof, so they are aligned by construction -- but the compiler
 * cannot see that through a char*, and -Wcast-align is on for good reasons elsewhere. */
static void *member(MViewConfig *config, size_t offset) {
    return (char *)config + offset;
}

static const void *member_const(const MViewConfig *config, size_t offset) {
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
            mask |= MVIEW_HEAD_LEFT;
            cursor += 4;
        } else if (strncasecmp(cursor, "right", 5) == 0) {
            mask |= MVIEW_HEAD_RIGHT;
            cursor += 5;
        } else if (strncasecmp(cursor, "both", 4) == 0) {
            mask |= MVIEW_HEAD_BOTH;
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
        mview_log("config %s=%g below the safe range, clamped to %g", key, value, field->low);
        return field->low;
    }
    if (value > field->high) {
        *clamped = 1;
        mview_log("config %s=%g above the safe range, clamped to %g", key, value, field->high);
        return field->high;
    }
    return value;
}

/* 0 on success, -2 when the text will not parse. Out-of-range values clamp and succeed. */
static int apply(MViewConfig *config, const Field *field, const char *text) {
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

static void render(const MViewConfig *config, const Field *field, char *out, size_t capacity) {
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
                 mask == MVIEW_HEAD_BOTH  ? "left,right"
                 : mask == MVIEW_HEAD_LEFT ? "left"
                                           : "right");
        return;
    }
    case FIELD_HEADREF: {
        int value = *(const int *)member_const(config, field->offset);
        snprintf(out, capacity, "%s", value == 0 ? "left" : value == 1 ? "right" : "none");
        return;
    }
    case FIELD_STRING:
        snprintf(out, capacity, "%s", (const char *)member_const(config, field->offset));
        return;
    }
    snprintf(out, capacity, "?");
}

static void load_defaults(MViewConfig *config) {
    memset(config, 0, sizeof(*config));
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        int rc = apply(config, &FIELDS[i], FIELDS[i].fallback);
        assert(rc == 0 && "a built-in default must parse");
        (void)rc;
    }
}

/* -- file ----------------------------------------------------------------------------- */

const char *mview_config_path(void) {
    static char cached[4096];
    if (!cached[0]) {
        const char *override = getenv("MVIEW_CONFIG_PATH");
        struct passwd *user = getpwuid(getuid());
        const char *home = user ? user->pw_dir : getenv("HOME");
        if (override && *override) snprintf(cached, sizeof(cached), "%s", override);
        else snprintf(cached, sizeof(cached), "%s/Library/Application Support/MView/config.json",
                      home ? home : "/nonexistent");
    }
    return cached;
}

static void read_value(void *context, const char *key, const char *value) {
    MViewConfig *config = context;
    const Field *field = find_field(key);
    if (!field || apply(config, field, value) != 0)
        mview_log("config: ignoring invalid key/value for %s", key);
}

/* -- public --------------------------------------------------------------------------- */

static MViewConfig g_config;
static int g_loaded;

const MViewConfig *mview_config(void) {
    if (g_loaded) {
        return &g_config;
    }
    load_defaults(&g_config);
    mview_settings_read(mview_config_path(), &g_config, read_value);
#if !MVIEW_DIAGNOSTICS
    g_config.capture_dump_frames = 0;
    snprintf(g_config.log_level, sizeof(g_config.log_level), "error");
#elif MVIEW_VERBOSE
    snprintf(g_config.log_level, sizeof(g_config.log_level), "debug");
#endif
    g_loaded = 1;
    return &g_config;
}

void mview_config_reload(void) {
    g_loaded = 0;
}

int mview_config_head_active(int head) {
    if (head < 0 || head > 1) {
        return 0;
    }
    return (mview_config()->heads_active & (head == 0 ? MVIEW_HEAD_LEFT : MVIEW_HEAD_RIGHT)) != 0;
}

void mview_config_print(FILE *out) {
    const MViewConfig *config = mview_config();
    MViewConfig defaults;
    load_defaults(&defaults);
    fprintf(out, "%s\n\n", mview_config_path());
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

int mview_config_get(const char *key, char *out, size_t capacity) {
    const Field *field = key ? find_field(key) : NULL;
    if (!field || !out) {
        return -1;
    }
    render(mview_config(), field, out, capacity);
    return 0;
}

int mview_config_set(const char *key, const char *value) {
    const Field *field = key ? find_field(key) : NULL;
    if (!field) {
        return -1;
    }
    /* Parse into a scratch copy first: a value that will not parse must not be persisted. */
    MViewConfig scratch = *mview_config();
    if (apply(&scratch, field, value ? value : "") != 0) {
        return -2;
    }
    char canonical[64];
    render(&scratch, field, canonical, sizeof(canonical));
    if (mview_settings_write(mview_config_path(), key, canonical,
                             field->type == FIELD_INT || field->type == FIELD_DOUBLE ? 1 :
                             field->type == FIELD_BOOL ? 2 : 0) != 0) return -1;
    mview_config_reload();
    return 0;
}

int mview_config_reset(void) {
    if (mview_settings_reset(mview_config_path()) != 0) return -1;
    mview_config_reload();
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

int mview_config_selftest(void) {
    g_failures = 0;
    MViewConfig config;
    load_defaults(&config);

    /* Defaults are the constants the driver used before this file existed. */
    CHECK(config.heads_active == MVIEW_HEAD_BOTH);
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
    CHECK(config.heads_active == MVIEW_HEAD_BOTH);
    CHECK(apply(&config, find_field("heads.native"), "right") == 0 && config.heads_native == 1);
    CHECK(apply(&config, find_field("heads.native"), "none") == 0 && config.heads_native == -1);

    /* Every field renders to something its own parser accepts. */
    MViewConfig round;
    load_defaults(&round);
    for (size_t i = 0; i < FIELD_COUNT; i++) {
        render(&round, &FIELDS[i], text, sizeof(text));
        CHECK(apply(&round, &FIELDS[i], text) == 0);
    }

    CHECK(find_field("no.such.key") == NULL);
    return g_failures;
}
