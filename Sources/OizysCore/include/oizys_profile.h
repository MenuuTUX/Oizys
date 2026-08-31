#ifndef OIZYS_PROFILE_H
#define OIZYS_PROFILE_H

#include "oizys_build.h"

#include <mach/mach_time.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Zone profiler for the scanout path.
 *
 * Gated at runtime rather than compile time so the shipped binary can profile itself:
 * `oizys profile` turns it on, and when it is off each site costs one predictable branch
 * on a global. Zones nest — a child's time is included in its parent's — and the report
 * prints self time alongside total so the nesting does not double-count in the reader's
 * head.
 *
 * Zones are a fixed enum rather than string keys so the hot path does no hashing and no
 * allocation. Adding one means adding it here and to kOizysZoneNames.
 */
typedef enum {
    OIZYS_ZONE_PRESENT,        /* one call into present_bgra_mosaic */
    OIZYS_ZONE_DAMAGE_PLAN,    /* fingerprint the surface, charge macro tiles */
    OIZYS_ZONE_DAMAGE_HASH,    /* the fingerprint pass alone */
    OIZYS_ZONE_ENCODE_STRIPS,  /* every strip owed this frame */
    OIZYS_ZONE_STRIP,          /* one strip, end to end */
    OIZYS_ZONE_CONVERT,        /* BGRA to the three planes */
    OIZYS_ZONE_HAAR,           /* the 8x8 pyramid */
    OIZYS_ZONE_QUANTIZE,       /* quantise into scan order, find last significant */
    OIZYS_ZONE_ENTROPY,        /* symbol coding and strip assembly */
    OIZYS_ZONE_SUBMIT,         /* build records, seal, hand to USB */
    OIZYS_ZONE_USB_WRITE,      /* the bulk transfer itself */
    OIZYS_ZONE_CONTROL,        /* status poll and heartbeat */
    OIZYS_ZONE_COUNT
} OizysZone;

extern const char *const kOizysZoneNames[OIZYS_ZONE_COUNT];
extern int oizys_profile_active;

void oizys_profile_enable(int enabled);
void oizys_profile_reset(void);
void oizys_profile_record(OizysZone zone, uint64_t start_ticks, uint64_t end_ticks);
/* Prints a table to stdout: calls, total ms, self ms, share, and ns per call. */
void oizys_profile_report(const char *title);
/* Totals for one zone, for tests and regression thresholds. */
double oizys_profile_total_ms(OizysZone zone);
uint64_t oizys_profile_calls(OizysZone zone);
/* Raw per-zone numbers, for an analysis layer outside the library. */
void oizys_profile_zone_stats(OizysZone zone, uint64_t *calls, double *total_ms, double *self_ms);
const char *oizys_profile_zone_name(OizysZone zone);
int oizys_profile_zone_count(void);

/* Zones must be pushed and popped in order on one thread; the pair is what gives self
 * time. Recording without nesting (a zone that spans threads, say) is still fine via
 * oizys_profile_record, it just reports no parent. */
uint64_t oizys_profile_push(OizysZone zone);
void oizys_profile_pop(OizysZone zone, uint64_t start_ticks);

#if OIZYS_DIAGNOSTICS
#define OIZYS_PROFILE_BEGIN(name, zone)                                                            \
    uint64_t oizys_zone_##name = oizys_profile_active ? oizys_profile_push(zone) : 0
#define OIZYS_PROFILE_END(name, zone)                                                              \
    do {                                                                                           \
        if (oizys_profile_active) {                                                                \
            oizys_profile_pop((zone), oizys_zone_##name);                                          \
        }                                                                                          \
    } while (0)

#else
#define OIZYS_PROFILE_BEGIN(name, zone) ((void)0)
#define OIZYS_PROFILE_END(name, zone) ((void)0)
#endif

#ifdef __cplusplus
}
#endif
#endif
