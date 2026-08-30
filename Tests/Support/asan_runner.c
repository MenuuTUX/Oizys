/*
 * Native memory-safety runner for the CPU-bound C.
 *
 * ASan cannot be injected into the suite's Python host: the interpreter is Apple-signed,
 * and macOS refuses to load a sanitizer runtime into a platform binary ("Sanitizer load
 * violates platform policy"). That is a property of the host process, not of our code, so
 * the fix is to stop borrowing someone else's process. This runner is our own ad-hoc
 * binary; the sanitizer loads into it with no policy problem, identically on a laptop and
 * on a CI runner.
 *
 * It compiles the pure-logic sources directly (no dock, no display server, no frameworks)
 * with -fsanitize=address,undefined and drives the paths where the buffer math lives:
 * the config parser, the encoder self-check, and a fuzz loop over the damage ledger and
 * the strip encoder -- including the dirty-rectangle fast path, whose bounds arithmetic is
 * exactly what a sanitizer is here to check.
 */
#include "mview_config.h"
#include "mview_dl3.h"
#include "mview_encode.h"
#include "mview_platform.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A small deterministic PRNG. Deterministic so a sanitizer failure reproduces from the
   seed printed below rather than vanishing on the next run. */
static uint64_t rng_state = 0x2545F4914F6CDD1Dull;
static uint32_t rng(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return (uint32_t)(rng_state >> 32);
}

static int32_t coeff_gen(void *context, unsigned index) {
    (void)context;
    (void)index;
    /* Full category range, both signs, so the vector quantiser sees saturating inputs. */
    return (int32_t)(rng() % 4096) - 2048;
}

/* config.c serializes through Foundation, which lives in Swift (ConfigStore.swift). This
   runner has no Swift, so it stands in with a no-op store: config_selftest exercises the
   parsing and validation in config.c, which is the C worth sanitising, and never depends
   on anything actually persisting. */
void mview_settings_read(const char *path, void *context,
                         void (*value)(void *, const char *, const char *)) {
    (void)path; (void)context; (void)value;
}
int mview_settings_write(const char *path, const char *key, const char *value, int type) {
    (void)path; (void)key; (void)value; (void)type; return 0;
}
int mview_settings_reset(const char *path) { (void)path; return 0; }

#define W 1920u
#define H 1080u
#define STRIDE (W * 4u)

int main(void) {
    printf("asan runner seed 0x%llx\n", (unsigned long long)rng_state);

    if (mview_config_selftest() != 0) {
        fprintf(stderr, "config selftest failed\n");
        return 1;
    }
    /* The vector quantiser against the scalar one, many rounds of generated coefficients. */
    if (mview_encode_selftest(coeff_gen, NULL, 20000) != 0) {
        fprintf(stderr, "encode selftest disagreed with the reference\n");
        return 1;
    }

    uint8_t *surface = malloc(STRIDE * H);
    if (!surface) return 2;
    for (size_t i = 0; i < STRIDE * (size_t)H; i++) surface[i] = (uint8_t)rng();

    MViewDamageMap *map = calloc(1, sizeof(*map));
    if (!map) return 2;
    mview_damage_init(map, W, H);

    MViewStrip owed[MVIEW_MAX_STRIPS];
    /* One frame's worth of output for the encoder, sized as the driver sizes it. */
    uint8_t *out = malloc(1u << 20);
    if (!out) return 2;

    for (int frame = 0; frame < 400; frame++) {
        /* Scribble on a random band so a real set of strips changes each frame. */
        uint32_t y0 = rng() % H;
        uint32_t bh = 1 + rng() % (H - y0);
        for (uint32_t y = y0; y < y0 + bh; y++) {
            uint32_t x0 = (rng() % W) * 4;
            surface[(size_t)y * STRIDE + (x0 % STRIDE)] ^= 0xFF;
        }

        /* Alternate the two entry points, and feed the dirty path both honest rectangles
           covering the band and deliberately ragged ones (zero-size, edge-touching, and
           one past the edge to force the out-of-range fallback). */
        int presentations = 1;
        int count;
        if (frame & 1) {
            MViewDirtyRect rects[8];
            int n = 0;
            rects[n++] = (MViewDirtyRect){0, y0, W, bh};
            rects[n++] = (MViewDirtyRect){rng() % W, rng() % H, 0, 0};
            rects[n++] = (MViewDirtyRect){W - 1, H - 1, 1, 1};
            if (frame % 7 == 0) rects[n++] = (MViewDirtyRect){W, 0, 4, 4}; /* off-surface */
            count = mview_damage_plan_dirty(map, surface, STRIDE, rects, n, owed,
                                            MVIEW_MAX_STRIPS, &presentations);
        } else {
            count = mview_damage_plan(map, surface, STRIDE, owed, MVIEW_MAX_STRIPS,
                                      &presentations);
        }
        if (count < 0 || count > MVIEW_MAX_STRIPS) {
            fprintf(stderr, "damage plan returned %d on frame %d\n", count, frame);
            return 1;
        }
        /* Encode every owed strip, which is where the plane math and the entropy coder
           write into fixed buffers. */
        int encode = count < 64 ? count : 64;
        for (int i = 0; i < encode; i++) {
            MViewStrip s = owed[i];
            mview_video_colour_strip_bgra(out, 1u << 20, (uint16_t)s.x, (uint16_t)s.y,
                                          surface, STRIDE, W, H);
        }
        mview_damage_presented(map);
    }

    free(out);
    free(map);
    free(surface);
    puts("asan runner: no memory errors");
    return 0;
}
