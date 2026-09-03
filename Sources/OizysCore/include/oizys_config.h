#pragma once

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OIZYS_HEAD_LEFT 0x1u
#define OIZYS_HEAD_RIGHT 0x2u
#define OIZYS_HEAD_BOTH (OIZYS_HEAD_LEFT | OIZYS_HEAD_RIGHT)

/*
 * Every field here was a compile-time constant until the config file existed, and the
 * defaults below still are those constants exactly. An absent or unreadable config file
 * therefore changes nothing about how the driver behaves.
 */
typedef struct {
    uint32_t heads_active;   /* bitmask of OIZYS_HEAD_* */
    int heads_native;        /* intended native head, -1 for none; cannot reroute dock ports */
    int head_width;
    int head_height;
    double head_refresh_hz;
    int capture_fps;
    int capture_queue_depth;
    int capture_dump_frames;
    int head_brightness[2];   /* percent, per head; dims the signal, not a backlight */
    int head_contrast[2];     /* percent, per head; pivots on mid-grey, so it goes both ways */
    int head_keepalive_s[2];  /* repaint an idle head this often; 0 lets the panel sleep */
    int head_standby_min[2];  /* blank an idle head after this long; 0 never blanks */
    int power_saving;         /* drop to power.idle_fps once every head is idle */
    int power_idle_fps;
    int power_idle_after_s;
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
    int display_keep_modes;   /* put every other display's resolution back after we relayout */
    int sidecar_auto_connect; /* attach the iPad by itself when it turns up at the desk */
    int sidecar_require_desk; /* ...but only on AC with an external display attached */
    char sidecar_device[64];  /* which iPad, by name; empty means the first one offered */
    int sidecar_brightness;   /* percent; a gamma ramp, not the iPad's backlight */
    int sidecar_contrast;     /* percent; same ramp, pivoting on mid-grey */
    char log_level[16];
} OizysConfig;

/* Loaded once from disk and cached. Never NULL: a missing file yields the defaults. */
const OizysConfig *oizys_config(void);

/* Absolute path of the backing file, whether or not it exists. */
const char *oizys_config_path(void);

/* Drop the cache so the next oizys_config() re-reads the file. */
void oizys_config_reload(void);

/* Reload when the file changed since the last check, at most once a second.
 * Returns non-zero when it actually reloaded. Safe to call on a hot path. */
int oizys_config_refresh_if_changed(void);

/* Every key, its current value and its default, one per line. */
void oizys_config_print(FILE *out);

/* 0 on success. Writes the current value of `key` into `out`. */
int oizys_config_get(const char *key, char *out, size_t capacity);

/*
 * Parse, clamp and persist. Returns 0 on success, -1 for an unknown key and -2 for a value
 * that will not parse. A value outside the safe range is clamped rather than rejected, and
 * the clamp is logged: control.poll_ms in particular is load-bearing, and a too-aggressive
 * poll shows up as a false disconnect rather than as an error.
 */
int oizys_config_set(const char *key, const char *value);

/* Delete the file and return to defaults. */
int oizys_config_reset(void);

/* Non-zero when this head should be driven over the dock. */
int oizys_config_head_active(int head);

/* This head's output gain in Q8, 256 = unity, for oizys_video_set_gain. */
int oizys_config_head_gain_q8(int head);

/* This head's contrast in Q8, 256 = unity, for oizys_video_set_contrast. */
int oizys_config_head_contrast_q8(int head);

/* Seconds between idle repaints for this head, 0 when it should be left to sleep. */
int oizys_config_head_keepalive_s(int head);

/* Seconds of stillness before this head is blanked, 0 when it should never blank. */
int oizys_config_head_standby_s(int head);

/* Non-zero when a display's resolution should be put back after macOS moves it. */
int oizys_config_keep_modes(void);

/* Asserts over the parse, clamp and round-trip paths. Returns 0 when everything holds. */
int oizys_config_selftest(void);

#ifdef __cplusplus
}
#endif
