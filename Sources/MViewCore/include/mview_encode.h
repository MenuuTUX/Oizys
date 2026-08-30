#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MVIEW_STRIP_W 64
#define MVIEW_STRIP_H 16
#define MVIEW_MAX_STRIPS (30 * 68)

typedef struct {
    uint32_t col, row, x, y, w, h;
} MViewStrip;

/* Buffers the dock rotates through as it presents. A keyframe must reach every one,
   so it is presented this many times with an advancing trailer phase. */
#define MVIEW_DOCK_BUFFERS 2
/* Frames a changed strip must ride on before every dock buffer holds it: the ring
   depth plus one frame of margin for a presentation the dock applies to the buffer it
   just used. Consecutive copies within one frame land in the same buffer, so the
   repeats have to be spread across later frames. */
#define MVIEW_DAMAGE_REPEATS (MVIEW_DOCK_BUFFERS + 1)
/* The dock rotates its backing store over 4x4-strip macro tiles, so a strip that moved
   drags its whole macro tile onto the wire with it. */
#define MVIEW_MACRO_STRIPS 4

/* A rectangle the compositor reports as changed, in surface pixels, top-left origin. */
typedef struct {
    uint32_t x, y, w, h;
} MViewDirtyRect;

/* ScreenCaptureKit's dirty rectangles are a hint from the compositor, not a contract. A
   rect it omits would leave a strip stale until something else happened to disturb it,
   which is a failure this driver has already been through once. So one row in this many
   is re-fingerprinted unconditionally on every frame, on a rotating phase: a missed rect
   costs at most this many frames of staleness instead of never repairing, for an eighth
   of the full-surface cost. */
#define MVIEW_DAMAGE_SWEEP 8

typedef struct {
    uint32_t width, height, cols, rows;
    /* Rotating phase for the verification sweep above. */
    uint32_t sweep;
    uint64_t hashes[MVIEW_MAX_STRIPS];
    /* This frame's hashes, published to `hashes` only once the frame reached the dock,
       so a failed transfer leaves the dock-visible state intact and the next frame
       repairs it. */
    uint64_t pending[MVIEW_MAX_STRIPS];
    uint8_t debt[MVIEW_MAX_STRIPS];
    uint8_t keyframe_owed;
} MViewDamageMap;

void mview_damage_init(MViewDamageMap *map, uint32_t width, uint32_t height);
MViewStrip mview_damage_geom(const MViewDamageMap *map, uint32_t col, uint32_t row);
int mview_damage_update(MViewDamageMap *map, const uint8_t *bgra, size_t stride,
                        MViewStrip *out, int max_out);

/* Decide what one frame should put on the wire. Charges every macro tile whose content
   moved and returns the strips that still owe a transmission, with `*presentations` set
   to how many times the frame must be sent. A return of 0 means send nothing at all —
   the dock holds the last image itself. Call mview_damage_presented only after the
   frame actually reached the dock. */
int mview_damage_plan(MViewDamageMap *map, const uint8_t *bgra, size_t stride,
                      MViewStrip *out, int max_out, int *presentations);
/* As mview_damage_plan, but re-fingerprints only the strips `rects` covers plus this
   frame's verification sweep, carrying every other strip's previous fingerprint forward.
   Falls back to the full pass when a keyframe is owed, when no rects were supplied, or
   when any rect falls outside the surface. Hashing the whole surface every frame is where
   this driver's CPU went; the compositor already knows what moved. */
int mview_damage_plan_dirty(MViewDamageMap *map, const uint8_t *bgra, size_t stride,
                            const MViewDirtyRect *rects, int rect_count, MViewStrip *out,
                            int max_out, int *presentations);
/* The strips that still owe a transmission, without re-reading the surface. */
int mview_damage_owed(const MViewDamageMap *map, MViewStrip *out, int max_out);
void mview_damage_presented(MViewDamageMap *map);

void mview_rgb_to_ycc(int r, int g, int b, int *y, int *cb, int *cr);

#ifdef __cplusplus
}
#endif

/* Encoder throughput on a synthetic desktop; prints to stdout, returns 0 on success. */
int mview_bench_encoder(void);
/* Per-zone profile of a realistic scanout sequence; prints to stdout. */
int mview_profile_encoder(void);
