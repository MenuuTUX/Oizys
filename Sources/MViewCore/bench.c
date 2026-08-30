/*
 * Encoder throughput on a synthetic 1920x1080 desktop. The scanout path is the whole
 * performance story — everything else in this driver is USB latency — so the numbers that
 * matter live here rather than in a profiler someone has to remember to run.
 */
#include "mview_dl3.h"
#include "mview_encode.h"
#include "mview_profile.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BENCH_W 1920
#define BENCH_H 1080
#define BENCH_BODY 2048

static double now_ms(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

static double best(double current, double candidate) {
    return candidate < current ? candidate : current;
}

/*
 * A flat or smooth surface quantises to almost nothing and makes the entropy coder look
 * free, which is the mistake that hid the luma cap bug and later made a black frame read
 * as a valid profile. Gradient, hard-edged window chrome and dense text-like rows, so the
 * AC bands carry real energy.
 */
static void paint_desktop(uint8_t *bgra, size_t stride) {
    uint32_t seed = 0x9e3779b9u;
    for (uint32_t y = 0; y < BENCH_H; y++) {
        uint8_t *row = bgra + (size_t)y * stride;
        for (uint32_t x = 0; x < BENCH_W; x++) {
            uint8_t r = (uint8_t)(24 + (x * 90) / BENCH_W);
            uint8_t g = (uint8_t)(28 + (y * 70) / BENCH_H);
            uint8_t b = (uint8_t)(60 + ((x + y) * 60) / (BENCH_W + BENCH_H));
            if (y > 120 && y < 900 && x > 200 && x < 1500) {
                r = g = b = 246;
                if (((y - 130) % 19) < 9 && ((x * 7 + y * 13) & 15) > 6) {
                    r = g = b = 18;
                }
            }
            if (y < 28) {
                r = g = b = 236;
            }
            seed = seed * 1664525u + 1013904223u;
            int noise = (int)((seed >> 24) & 7) - 3;
            int blue = (int)b + noise;
            uint8_t *pixel = row + (size_t)x * 4;
            pixel[0] = (uint8_t)(blue < 0 ? 0 : (blue > 255 ? 255 : blue));
            pixel[1] = g;
            pixel[2] = r;
            pixel[3] = 255;
        }
    }
}

int mview_bench_encoder(void) {
    size_t stride = (size_t)BENCH_W * 4;
    uint8_t *bgra = malloc(stride * BENCH_H);
    MViewDamageMap *map = calloc(1, sizeof(*map));
    MViewStrip *owed = calloc(MVIEW_MAX_STRIPS, sizeof(*owed));
    uint8_t *bodies = malloc((size_t)MVIEW_MAX_STRIPS * BENCH_BODY);
    if (!bgra || !map || !owed || !bodies) {
        free(bgra);
        free(map);
        free(owed);
        free(bodies);
        return 1;
    }
    paint_desktop(bgra, stride);

    const uint32_t cols = BENCH_W / MVIEW_STRIP_W;
    const uint32_t strips = cols * (BENCH_H / MVIEW_STRIP_H);
    const uint32_t macro = MVIEW_MACRO_STRIPS * MVIEW_MACRO_STRIPS;

    /* Best of N. One timed run on a laptop swings wider than most changes worth measuring. */
    const int rounds = 5;
    double plan_first = 1e9, plan_steady = 1e9;
    double serial = 1e9, parallel = 1e9, macro_tile = 1e9;
    int presentations = 0, keyframe_strips = 0;

    for (int round = 0; round < rounds; round++) {
        mview_damage_init(map, BENCH_W, BENCH_H);
        double t = now_ms();
        keyframe_strips =
            mview_damage_plan(map, bgra, stride, owed, MVIEW_MAX_STRIPS, &presentations);
        plan_first = best(plan_first, now_ms() - t);
        mview_damage_presented(map);

        t = now_ms();
        mview_damage_plan(map, bgra, stride, owed, MVIEW_MAX_STRIPS, &presentations);
        plan_steady = best(plan_steady, now_ms() - t);
        mview_damage_presented(map);

        t = now_ms();
        for (uint32_t i = 0; i < strips; i++) {
            mview_video_colour_strip_bgra(bodies + (size_t)i * BENCH_BODY, BENCH_BODY,
                                          (uint16_t)((i % cols) * MVIEW_STRIP_W),
                                          (uint16_t)((i / cols) * MVIEW_STRIP_H), bgra, stride,
                                          BENCH_W, BENCH_H);
        }
        serial = best(serial, now_ms() - t);

        t = now_ms();
        dispatch_apply(strips, DISPATCH_APPLY_AUTO, ^(size_t i) {
          mview_video_colour_strip_bgra(bodies + i * BENCH_BODY, BENCH_BODY,
                                        (uint16_t)((i % cols) * MVIEW_STRIP_W),
                                        (uint16_t)((i / cols) * MVIEW_STRIP_H), bgra, stride,
                                        BENCH_W, BENCH_H);
        });
        parallel = best(parallel, now_ms() - t);

        t = now_ms();
        for (int repeat = 0; repeat < 200; repeat++) {
            for (uint32_t k = 0; k < macro; k++) {
                mview_video_colour_strip_bgra(bodies + (size_t)k * BENCH_BODY, BENCH_BODY,
                                              (uint16_t)((k % MVIEW_MACRO_STRIPS) * MVIEW_STRIP_W),
                                              (uint16_t)((k / MVIEW_MACRO_STRIPS) * MVIEW_STRIP_H),
                                              bgra, stride, BENCH_W, BENCH_H);
            }
        }
        macro_tile = best(macro_tile, (now_ms() - t) / 200);
    }

    printf("surface            %dx%d, %d strips, best of %d\n", BENCH_W, BENCH_H, keyframe_strips,
           rounds);
    printf("damage plan first  %8.2f ms\n", plan_first);
    printf("damage plan steady %8.2f ms\n", plan_steady);
    printf("encode serial      %8.2f ms\n", serial);
    printf("encode parallel    %8.2f ms  %.1fx  (%.0f fps one head, %.0f fps two)\n", parallel,
           serial / parallel, 1000.0 / parallel, 1000.0 / (parallel * 2));
    printf("encode macro tile  %8.3f ms   (a moved window costs about this)\n", macro_tile);
    printf("60 Hz budget       %8.2f ms per head\n", 1000.0 / 60);

    free(bgra);
    free(map);
    free(owed);
    free(bodies);
    return 0;
}

/*
 * Per-zone profile of a real scanout sequence: one keyframe, then frames with the kind of
 * localised damage a moving cursor and a dragged window produce. Runs the same code the
 * driver runs, with the zone profiler switched on, so the shares are measured rather than
 * modelled.
 */
int mview_profile_encoder(void) {
    size_t stride = (size_t)BENCH_W * 4;
    uint8_t *bgra = malloc(stride * BENCH_H);
    MViewDamageMap *map = calloc(1, sizeof(*map));
    MViewStrip *owed = calloc(MVIEW_MAX_STRIPS, sizeof(*owed));
    uint8_t *bodies = malloc((size_t)MVIEW_MAX_STRIPS * BENCH_BODY);
    if (!bgra || !map || !owed || !bodies) {
        free(bgra);
        free(map);
        free(owed);
        free(bodies);
        return 1;
    }
    paint_desktop(bgra, stride);
    mview_damage_init(map, BENCH_W, BENCH_H);
    const uint32_t cols = BENCH_W / MVIEW_STRIP_W;

    mview_profile_reset();
    mview_profile_enable(1);

    const int frames = 120;
    long total_strips = 0;
    for (int frame = 0; frame < frames; frame++) {
        if (frame > 0) {
            /* Move a block of pixels, the way a dragged window or a cursor does. A still
               surface would profile the fingerprint pass and nothing else. */
            uint32_t x = (uint32_t)((frame * 37) % (BENCH_W - 200)) + 8;
            uint32_t y = (uint32_t)((frame * 53) % (BENCH_H - 120)) + 8;
            for (uint32_t dy = 0; dy < 96; dy++) {
                memset(bgra + (size_t)(y + dy) * stride + (size_t)x * 4,
                       (int)((frame * 7 + dy) & 0xff), 180 * 4);
            }
        }
        uint64_t frame_start = mach_absolute_time();
        int presentations = 0;
        int count = mview_damage_plan(map, bgra, stride, owed, MVIEW_MAX_STRIPS, &presentations);
        total_strips += count;

        uint64_t encode_start = mach_absolute_time();
        if (count >= 64) {
            dispatch_apply((size_t)count, DISPATCH_APPLY_AUTO, ^(size_t i) {
              mview_video_colour_strip_bgra(bodies + i * BENCH_BODY, BENCH_BODY,
                                            (uint16_t)owed[i].x, (uint16_t)owed[i].y, bgra, stride,
                                            BENCH_W, BENCH_H);
            });
        } else {
            for (int i = 0; i < count; i++) {
                mview_video_colour_strip_bgra(bodies + (size_t)i * BENCH_BODY, BENCH_BODY,
                                              (uint16_t)owed[i].x, (uint16_t)owed[i].y, bgra,
                                              stride, BENCH_W, BENCH_H);
            }
        }
        mview_profile_record(MVIEW_ZONE_ENCODE_STRIPS, encode_start, mach_absolute_time());
        mview_damage_presented(map);
        mview_profile_record(MVIEW_ZONE_PRESENT, frame_start, mach_absolute_time());
    }
    mview_profile_enable(0);

    printf("%d frames at %dx%d, %ld strips encoded (%.1f per frame)\n", frames, BENCH_W, BENCH_H,
           total_strips, (double)total_strips / frames);
    printf("indentation shows nesting; self excludes nested zones. Strip work runs on all\n"
           "cores, so its total exceeds wall time by roughly the core count.\n");
    mview_profile_report("scanout profile");
    printf("\nper frame: %.3f ms wall, budget at 60 Hz is %.2f ms\n",
           mview_profile_total_ms(MVIEW_ZONE_PRESENT) / frames, 1000.0 / 60);
    (void)cols;
    free(bgra);
    free(map);
    free(owed);
    free(bodies);
    return 0;
}
