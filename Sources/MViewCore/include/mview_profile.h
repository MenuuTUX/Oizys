#ifndef MVIEW_PROFILE_H
#define MVIEW_PROFILE_H

#include "mview_build.h"

#include <mach/mach_time.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Zone profiler for the scanout path.
 *
 * Gated at runtime rather than compile time so the shipped binary can profile itself:
 * `mview profile` turns it on, and when it is off each site costs one predictable branch
 * on a global. Zones nest — a child's time is included in its parent's — and the report
 * prints self time alongside total so the nesting does not double-count in the reader's
 * head.
 *
 * Zones are a fixed enum rather than string keys so the hot path does no hashing and no
 * allocation. Adding one means adding it here and to kMViewZoneNames.
 */
typedef enum {
    MVIEW_ZONE_PRESENT,        /* one call into present_bgra_mosaic */
    MVIEW_ZONE_DAMAGE_PLAN,    /* fingerprint the surface, charge macro tiles */
    MVIEW_ZONE_DAMAGE_HASH,    /* the fingerprint pass alone */
    MVIEW_ZONE_ENCODE_STRIPS,  /* every strip owed this frame */
    MVIEW_ZONE_STRIP,          /* one strip, end to end */
    MVIEW_ZONE_CONVERT,        /* BGRA to the three planes */
    MVIEW_ZONE_HAAR,           /* the 8x8 pyramid */
    MVIEW_ZONE_QUANTIZE,       /* quantise into scan order, find last significant */
    MVIEW_ZONE_ENTROPY,        /* symbol coding and strip assembly */
    MVIEW_ZONE_SUBMIT,         /* build records, seal, hand to USB */
    MVIEW_ZONE_USB_WRITE,      /* the bulk transfer itself */
    MVIEW_ZONE_CONTROL,        /* status poll and heartbeat */
    MVIEW_ZONE_COUNT
} MViewZone;

extern const char *const kMViewZoneNames[MVIEW_ZONE_COUNT];
extern int mview_profile_active;

void mview_profile_enable(int enabled);
void mview_profile_reset(void);
void mview_profile_record(MViewZone zone, uint64_t start_ticks, uint64_t end_ticks);
/* Prints a table to stdout: calls, total ms, self ms, share, and ns per call. */
void mview_profile_report(const char *title);
/* Totals for one zone, for tests and regression thresholds. */
double mview_profile_total_ms(MViewZone zone);
uint64_t mview_profile_calls(MViewZone zone);
/* Raw per-zone numbers, for an analysis layer outside the library. */
void mview_profile_zone_stats(MViewZone zone, uint64_t *calls, double *total_ms, double *self_ms);
const char *mview_profile_zone_name(MViewZone zone);
int mview_profile_zone_count(void);

/* Zones must be pushed and popped in order on one thread; the pair is what gives self
 * time. Recording without nesting (a zone that spans threads, say) is still fine via
 * mview_profile_record, it just reports no parent. */
uint64_t mview_profile_push(MViewZone zone);
void mview_profile_pop(MViewZone zone, uint64_t start_ticks);

#if MVIEW_DIAGNOSTICS
#define MVIEW_PROFILE_BEGIN(name, zone)                                                            \
    uint64_t mview_zone_##name = mview_profile_active ? mview_profile_push(zone) : 0
#define MVIEW_PROFILE_END(name, zone)                                                              \
    do {                                                                                           \
        if (mview_profile_active) {                                                                \
            mview_profile_pop((zone), mview_zone_##name);                                          \
        }                                                                                          \
    } while (0)

#else
#define MVIEW_PROFILE_BEGIN(name, zone) ((void)0)
#define MVIEW_PROFILE_END(name, zone) ((void)0)
#endif

#ifdef __cplusplus
}
#endif
#endif
