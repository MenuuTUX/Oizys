#pragma once

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MVIEW_HEAD_LEFT 0x1u
#define MVIEW_HEAD_RIGHT 0x2u
#define MVIEW_HEAD_BOTH (MVIEW_HEAD_LEFT | MVIEW_HEAD_RIGHT)

/*
 * Every field here was a compile-time constant until the config file existed, and the
 * defaults below still are those constants exactly. An absent or unreadable config file
 * therefore changes nothing about how the driver behaves.
 */
typedef struct {
    uint32_t heads_active;   /* bitmask of MVIEW_HEAD_* */
    int heads_native;        /* intended native head, -1 for none; cannot reroute dock ports */
    int head_width;
    int head_height;
    double head_refresh_hz;
    int capture_fps;
    int capture_queue_depth;
    int capture_dump_frames;
    int control_poll_ms;
    int control_heartbeat_s;
    int refresh_clock_hz;
    int codec_ceiling_sync;
    int codec_ceiling_dc;
    int codec_ceiling_chroma_ac;
    int codec_ceiling_luma_ac;
    int encode_parallel_threshold;
    int dock_buffers;
    int displaylink_auto_stop;
    char log_level[16];
} MViewConfig;

/* Loaded once from disk and cached. Never NULL: a missing file yields the defaults. */
const MViewConfig *mview_config(void);

/* Absolute path of the backing file, whether or not it exists. */
const char *mview_config_path(void);

/* Drop the cache so the next mview_config() re-reads the file. */
void mview_config_reload(void);

/* Every key, its current value and its default, one per line. */
void mview_config_print(FILE *out);

/* 0 on success. Writes the current value of `key` into `out`. */
int mview_config_get(const char *key, char *out, size_t capacity);

/*
 * Parse, clamp and persist. Returns 0 on success, -1 for an unknown key and -2 for a value
 * that will not parse. A value outside the safe range is clamped rather than rejected, and
 * the clamp is logged: control.poll_ms in particular is load-bearing, and a too-aggressive
 * poll shows up as a false disconnect rather than as an error.
 */
int mview_config_set(const char *key, const char *value);

/* Delete the file and return to defaults. */
int mview_config_reset(void);

/* Non-zero when this head should be driven over the dock. */
int mview_config_head_active(int head);

/* Asserts over the parse, clamp and round-trip paths. Returns 0 when everything holds. */
int mview_config_selftest(void);

#ifdef __cplusplus
}
#endif
