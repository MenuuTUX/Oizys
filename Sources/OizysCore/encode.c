#include "oizys_encode.h"

#include <arm_acle.h>

#include "oizys_profile.h"

#include <dispatch/dispatch.h>

#include <string.h>

void oizys_damage_init(OizysDamageMap *map, uint32_t width, uint32_t height) {
    memset(map, 0, sizeof(*map));
    map->width = width;
    map->height = height;
    map->cols = (width + OIZYS_STRIP_W - 1) / OIZYS_STRIP_W;
    map->rows = (height + OIZYS_STRIP_H - 1) / OIZYS_STRIP_H;
    /* The dock's framebuffer is undefined until the first full frame lands. */
    map->keyframe_owed = 1;
}

OizysStrip oizys_damage_geom(const OizysDamageMap *map, uint32_t col, uint32_t row) {
    OizysStrip s;
    s.col = col;
    s.row = row;
    s.x = col * OIZYS_STRIP_W;
    s.y = row * OIZYS_STRIP_H;
    s.w = OIZYS_STRIP_W;
    s.h = OIZYS_STRIP_H;
    if (s.x + s.w > map->width) {
        s.w = map->width - s.x;
    }
    if (s.y + s.h > map->height) {
        s.h = map->height - s.y;
    }
    return s;
}

#define OIZYS_HASH_PRIME 0x9e3779b185ebca87ull

static inline uint64_t rotl64(uint64_t value, unsigned bits) {
    return (value << bits) | (value >> (64 - bits));
}

/*
 * Strip fingerprint, two CRC32 lanes.
 *
 * The CRC32 instruction retires one 8-byte word per cycle, against three dependent
 * operations for the multiply-and-rotate this replaced: 1.66 ms per 1080p surface became
 * 0.84 ms, which is memory bandwidth rather than arithmetic.
 *
 * Both lanes see every word. The obvious arrangement -- one lane taking even words and the
 * other odd -- is twice as fast again, and wrong: a change confined to one lane's bytes
 * leaves the other lane untouched, so the collision probability is a single lane's 2^-32
 * rather than 2^-64. Measured, a one-bit change moved both lanes 0 times out of 4000 that
 * way. A missed change here is a tile that stays stale until something else disturbs it,
 * which is the failure this driver has already been through once.
 *
 * The second lane rotates its input so the two are not the same linear function of the
 * data; CRC is linear, and without it the lanes would agree about more than they should.
 */
static uint64_t hash_strip(const uint8_t *bgra, size_t stride, OizysStrip s) {
    uint32_t low = 0xffffffffu ^ s.col;
    uint32_t high = 0x12345678u ^ s.row;
    size_t span = (size_t)s.w * 4;
    for (uint32_t dy = 0; dy < s.h; dy++) {
        const uint8_t *row = bgra + (size_t)(s.y + dy) * stride + (size_t)s.x * 4;
        size_t i = 0;
        for (; i + 16 <= span; i += 16) {
            uint64_t first, second;
            memcpy(&first, row + i, sizeof(first));
            memcpy(&second, row + i + 8, sizeof(second));
            low = __crc32d(__crc32d(low, first), second);
            high = __crc32d(__crc32d(high, rotl64(second, 29)), rotl64(first, 17));
        }
        for (; i + 8 <= span; i += 8) {
            uint64_t word;
            memcpy(&word, row + i, sizeof(word));
            low = __crc32d(low, word);
            high = __crc32d(high, rotl64(word, 17));
        }
        for (; i < span; i++) {
            low = __crc32b(low, row[i]);
            high = __crc32b(high, row[i]);
        }
    }
    return ((uint64_t)low << 32) | high;
}

int oizys_damage_update(OizysDamageMap *map, const uint8_t *bgra, size_t stride, OizysStrip *out,
                        int max_out) {
    int n = 0;
    for (uint32_t row = 0; row < map->rows; row++) {
        for (uint32_t col = 0; col < map->cols; col++) {
            OizysStrip s = oizys_damage_geom(map, col, row);
            uint32_t idx = row * map->cols + col;
            uint64_t h = hash_strip(bgra, stride, s);
            if (map->hashes[idx] != h) {
                map->hashes[idx] = h;
                if (n < max_out) {
                    out[n] = s;
                }
                n++;
            }
        }
    }
    return n;
}

void oizys_rgb_to_ycc(int r, int g, int b, int *y, int *cb, int *cr) {
    *cb = 64 * (r - g);
    *cr = 64 * (b - g);
    *y = 64 * g + 64 * (((r - g) + (b - g)) >> 2);
}

static void charge_macro_tile(OizysDamageMap *map, uint32_t col, uint32_t row) {
    uint32_t first_col = col - col % OIZYS_MACRO_STRIPS;
    uint32_t first_row = row - row % OIZYS_MACRO_STRIPS;
    for (uint32_t r = first_row; r < first_row + OIZYS_MACRO_STRIPS && r < map->rows; r++) {
        for (uint32_t c = first_col; c < first_col + OIZYS_MACRO_STRIPS && c < map->cols; c++) {
            map->debt[r * map->cols + c] = OIZYS_DAMAGE_REPEATS;
        }
    }
}

int oizys_damage_owed(const OizysDamageMap *map, OizysStrip *out, int max_out) {
    int n = 0;
    for (uint32_t row = 0; row < map->rows; row++) {
        for (uint32_t col = 0; col < map->cols; col++) {
            if (!map->keyframe_owed && !map->debt[row * map->cols + col]) {
                continue;
            }
            if (n < max_out) {
                out[n] = oizys_damage_geom(map, col, row);
            }
            n++;
        }
    }
    return n;
}

/*
 * Charge every macro tile whose fingerprint moved, then report what is owed. Shared by
 * both plan entry points; it reads `pending` and touches no pixels.
 *
 * Split from fingerprinting because the two have different sharing. Fingerprinting writes
 * one slot per strip and spreads across cores freely; charging writes a 4x4 neighbourhood
 * of debt counters that neighbouring strips overlap, so it stays on one thread. This pass
 * costs almost nothing next to the first.
 */
static int settle_plan(OizysDamageMap *map, OizysStrip *out, int max_out, int *presentations) {
    uint32_t cols = map->cols;
    for (uint32_t row = 0; row < map->rows; row++) {
        for (uint32_t col = 0; col < cols; col++) {
            if (map->pending[row * cols + col] != map->hashes[row * cols + col]) {
                charge_macro_tile(map, col, row);
            }
        }
    }
    /* A keyframe has to reach every dock buffer at once: it clears the ledger on its own
       strength, so one that comes up short leaves stale pixels nothing will repair. The
       trailer phase cycles over three slots and a presentation advances it by one, so it
       takes the same count a delta is charged. Upstream presents a keyframe
       OIZYS_DOCK_BUFFERS times; at that count the third slot kept the black training
       frame and the panels alternated between the desktop and it. A delta goes once and
       its repeats ride on later frames. */
    *presentations = map->keyframe_owed ? OIZYS_DAMAGE_REPEATS : 1;
    return oizys_damage_owed(map, out, max_out);
}

int oizys_damage_plan(OizysDamageMap *map, const uint8_t *bgra, size_t stride, OizysStrip *out,
                      int max_out, int *presentations) {
    OIZYS_PROFILE_BEGIN(plan, OIZYS_ZONE_DAMAGE_PLAN);
    OIZYS_PROFILE_BEGIN(hash, OIZYS_ZONE_DAMAGE_HASH);
    uint32_t cols = map->cols;
    dispatch_apply(map->rows, DISPATCH_APPLY_AUTO, ^(size_t row) {
      for (uint32_t col = 0; col < cols; col++) {
          map->pending[row * cols + col] =
              hash_strip(bgra, stride, oizys_damage_geom(map, col, (uint32_t)row));
      }
    });
    OIZYS_PROFILE_END(hash, OIZYS_ZONE_DAMAGE_HASH);
    map->sweep++;
    int owed = settle_plan(map, out, max_out, presentations);
    OIZYS_PROFILE_END(plan, OIZYS_ZONE_DAMAGE_PLAN);
    return owed;
}

/* Strips `rect` covers, clamped to the map. Returns 0 if the rect leaves the surface, in
   which case the caller must not trust the rect list at all. */
static int mark_rect(const OizysDamageMap *map, OizysDirtyRect rect, uint8_t *mark) {
    if (rect.w == 0 || rect.h == 0) {
        return 1; /* an empty rect marks nothing and impeaches nothing */
    }
    if (rect.x >= map->width || rect.y >= map->height || rect.w > map->width - rect.x ||
        rect.h > map->height - rect.y) {
        return 0;
    }
    uint32_t first_col = rect.x / OIZYS_STRIP_W;
    uint32_t first_row = rect.y / OIZYS_STRIP_H;
    uint32_t last_col = (rect.x + rect.w - 1) / OIZYS_STRIP_W;
    uint32_t last_row = (rect.y + rect.h - 1) / OIZYS_STRIP_H;
    for (uint32_t row = first_row; row <= last_row && row < map->rows; row++) {
        for (uint32_t col = first_col; col <= last_col && col < map->cols; col++) {
            mark[row * map->cols + col] = 1;
        }
    }
    return 1;
}

int oizys_damage_plan_dirty(OizysDamageMap *map, const uint8_t *bgra, size_t stride,
                            const OizysDirtyRect *rects, int rect_count, OizysStrip *out,
                            int max_out, int *presentations) {
    /* A keyframe has no previous fingerprint to carry forward, and an absent rect list is
       no information at all. Both mean read everything. */
    if (map->keyframe_owed || !rects || rect_count <= 0) {
        return oizys_damage_plan(map, bgra, stride, out, max_out, presentations);
    }
    uint8_t mark[OIZYS_MAX_STRIPS];
    memset(mark, 0, sizeof(mark));
    for (int i = 0; i < rect_count; i++) {
        if (!mark_rect(map, rects[i], mark)) {
            return oizys_damage_plan(map, bgra, stride, out, max_out, presentations);
        }
    }
    /* This frame's share of the verification sweep. See OIZYS_DAMAGE_SWEEP. */
    for (uint32_t row = map->sweep % OIZYS_DAMAGE_SWEEP; row < map->rows;
         row += OIZYS_DAMAGE_SWEEP) {
        memset(&mark[row * map->cols], 1, map->cols);
    }
    map->sweep++;

    OIZYS_PROFILE_BEGIN(plan, OIZYS_ZONE_DAMAGE_PLAN);
    OIZYS_PROFILE_BEGIN(hash, OIZYS_ZONE_DAMAGE_HASH);
    uint32_t cols = map->cols;
    const uint8_t *marked = mark; /* a block cannot capture an array by value */
    dispatch_apply(map->rows, DISPATCH_APPLY_AUTO, ^(size_t row) {
      for (uint32_t col = 0; col < cols; col++) {
          uint32_t index = (uint32_t)row * cols + col;
          map->pending[index] =
              marked[index] ? hash_strip(bgra, stride, oizys_damage_geom(map, col, (uint32_t)row))
                            : map->hashes[index];
      }
    });
    OIZYS_PROFILE_END(hash, OIZYS_ZONE_DAMAGE_HASH);
    int owed = settle_plan(map, out, max_out, presentations);
    OIZYS_PROFILE_END(plan, OIZYS_ZONE_DAMAGE_PLAN);
    return owed;
}

void oizys_damage_presented(OizysDamageMap *map) {
    if (map->keyframe_owed) {
        memset(map->debt, 0, sizeof(map->debt));
        map->keyframe_owed = 0;
    } else {
        for (uint32_t index = 0; index < map->rows * map->cols; index++) {
            if (map->debt[index]) {
                map->debt[index]--;
            }
        }
    }
    memcpy(map->hashes, map->pending, sizeof(map->hashes));
}
