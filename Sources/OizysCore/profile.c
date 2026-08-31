#include "oizys_profile.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *const kOizysZoneNames[OIZYS_ZONE_COUNT] = {
    "present frame",  "damage plan",    "  fingerprint",   "encode strips",
    "  one strip",    "    convert",    "    haar",        "    quantize",
    "    entropy",    "submit",         "  usb write",     "control poll",
};

/* Read at every instrumented site, written once before the workload starts. Deliberately
   a plain int: it is only ever 0 or 1, and an atomic load here would put a barrier in the
   path this is supposed to be measuring. */
int oizys_profile_active;

typedef struct {
    uint64_t calls;
    uint64_t ticks;
    uint64_t child_ticks;
} ZoneStats;

/*
 * Per-thread accumulators, linked into a list that the report walks.
 *
 * The strip encoder runs on every core, so shared counters meant eight threads contending
 * on the same cache lines a hundred times per strip. That cost landed inside the very
 * zones being measured and swamped them. Thread-local blocks make recording a plain
 * increment; only the one-time registration touches an atomic.
 */
typedef struct ThreadStats {
    ZoneStats zones[OIZYS_ZONE_COUNT];
    struct ThreadStats *next;
} ThreadStats;

static _Atomic(ThreadStats *) g_threads;
static _Thread_local ThreadStats *g_local;
/* Open zones on this thread, innermost last, so a zone can add its elapsed time to its
   parent's child total and the report can show self time. */
static _Thread_local OizysZone g_stack[32];
static _Thread_local int g_depth;

static ThreadStats *local_stats(void) {
    if (!g_local) {
        g_local = calloc(1, sizeof(*g_local));
        if (!g_local) {
            return NULL;
        }
        ThreadStats *head = atomic_load(&g_threads);
        do {
            g_local->next = head;
        } while (!atomic_compare_exchange_weak(&g_threads, &head, g_local));
    }
    return g_local;
}

static double ticks_to_ms(uint64_t ticks) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return (double)ticks * timebase.numer / timebase.denom / 1e6;
}

void oizys_profile_enable(int enabled) {
    oizys_profile_active = OIZYS_DIAGNOSTICS && enabled ? 1 : 0;
}

void oizys_profile_reset(void) {
    for (ThreadStats *t = atomic_load(&g_threads); t; t = t->next) {
        memset(t->zones, 0, sizeof(t->zones));
    }
    g_depth = 0;
}

uint64_t oizys_profile_push(OizysZone zone) {
    if (zone < OIZYS_ZONE_COUNT && g_depth < (int)(sizeof(g_stack) / sizeof(g_stack[0]))) {
        g_stack[g_depth++] = zone;
    }
    return mach_absolute_time();
}

void oizys_profile_pop(OizysZone zone, uint64_t start_ticks) {
    uint64_t end = mach_absolute_time();
    if (g_depth > 0) {
        g_depth--;
    }
    oizys_profile_record(zone, start_ticks, end);
}

void oizys_profile_record(OizysZone zone, uint64_t start_ticks, uint64_t end_ticks) {
    ThreadStats *stats = local_stats();
    if (!stats || zone >= OIZYS_ZONE_COUNT || end_ticks <= start_ticks) {
        return;
    }
    uint64_t elapsed = end_ticks - start_ticks;
    stats->zones[zone].calls++;
    stats->zones[zone].ticks += elapsed;
    /* g_depth already stepped back past this zone, so the top of the stack is its parent. */
    if (g_depth > 0 && g_stack[g_depth - 1] != zone) {
        stats->zones[g_stack[g_depth - 1]].child_ticks += elapsed;
    }
}

static void merge(ZoneStats *out) {
    memset(out, 0, sizeof(*out) * OIZYS_ZONE_COUNT);
    for (ThreadStats *t = atomic_load(&g_threads); t; t = t->next) {
        for (int i = 0; i < OIZYS_ZONE_COUNT; i++) {
            out[i].calls += t->zones[i].calls;
            out[i].ticks += t->zones[i].ticks;
            out[i].child_ticks += t->zones[i].child_ticks;
        }
    }
}

double oizys_profile_total_ms(OizysZone zone) {
    if (zone >= OIZYS_ZONE_COUNT) {
        return 0.0;
    }
    ZoneStats totals[OIZYS_ZONE_COUNT];
    merge(totals);
    return ticks_to_ms(totals[zone].ticks);
}

uint64_t oizys_profile_calls(OizysZone zone) {
    if (zone >= OIZYS_ZONE_COUNT) {
        return 0;
    }
    ZoneStats totals[OIZYS_ZONE_COUNT];
    merge(totals);
    return totals[zone].calls;
}

/* Raw numbers for one zone, so an analysis layer outside this file can do the arithmetic
   and the presentation. The printed report below stays for the CLI. */
void oizys_profile_zone_stats(OizysZone zone, uint64_t *calls, double *total_ms, double *self_ms) {
    ZoneStats totals[OIZYS_ZONE_COUNT];
    merge(totals);
    if (zone >= OIZYS_ZONE_COUNT) {
        return;
    }
    if (calls) {
        *calls = totals[zone].calls;
    }
    if (total_ms) {
        *total_ms = ticks_to_ms(totals[zone].ticks);
    }
    if (self_ms) {
        *self_ms = ticks_to_ms(totals[zone].ticks > totals[zone].child_ticks
                                   ? totals[zone].ticks - totals[zone].child_ticks
                                   : 0);
    }
}

const char *oizys_profile_zone_name(OizysZone zone) {
    return zone < OIZYS_ZONE_COUNT ? kOizysZoneNames[zone] : "";
}

int oizys_profile_zone_count(void) {
    return OIZYS_ZONE_COUNT;
}

void oizys_profile_report(const char *title) {
    ZoneStats totals[OIZYS_ZONE_COUNT];
    merge(totals);
    double total = ticks_to_ms(totals[OIZYS_ZONE_PRESENT].ticks);
    if (total <= 0) {
        for (int i = 0; i < OIZYS_ZONE_COUNT; i++) {
            double value = ticks_to_ms(totals[i].ticks);
            total = value > total ? value : total;
        }
    }
    int threads = 0;
    for (ThreadStats *t = atomic_load(&g_threads); t; t = t->next) {
        threads++;
    }

    printf("\n%s  (%d threads recorded)\n", title ? title : "profile", threads);
    printf("%-16s %10s %10s %10s %8s %10s\n", "zone", "calls", "total ms", "self ms", "share",
           "ns/call");
    printf("%-16s %10s %10s %10s %8s %10s\n", "----------------", "----------", "----------",
           "----------", "--------", "----------");
    for (int i = 0; i < OIZYS_ZONE_COUNT; i++) {
        if (totals[i].calls == 0) {
            continue;
        }
        double zone_total = ticks_to_ms(totals[i].ticks);
        double self = ticks_to_ms(totals[i].ticks > totals[i].child_ticks
                                      ? totals[i].ticks - totals[i].child_ticks
                                      : 0);
        printf("%-16s %10llu %10.3f %10.3f %7.1f%% %10.0f\n", kOizysZoneNames[i],
               (unsigned long long)totals[i].calls, zone_total, self,
               total > 0 ? 100.0 * zone_total / total : 0.0,
               zone_total * 1e6 / (double)totals[i].calls);
    }
}
