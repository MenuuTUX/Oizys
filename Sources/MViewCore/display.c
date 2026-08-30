#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include "mview_display.h"
#include "mview_ddc.h"
#include <stdlib.h>

/*
 * Apple's own virtual panels: Sidecar iPads and AirPlay receivers both report the vendor
 * 'aapl' and are not built in. They matter here for one reason — macOS will fold a freshly
 * created virtual display into a mirror set with one of them, and then the dock scans out
 * the iPad's framebuffer at the iPad's aspect ratio instead of its own desktop.
 */
int mview_display_is_sidecar(uint32_t id) {
    return !CGDisplayIsBuiltin(id) && CGDisplayVendorNumber(id) == 0x6161706c;
}

static uint32_t online_displays(uint32_t *ids, uint32_t capacity) {
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(capacity, ids, &count) != kCGErrorSuccess) {
        return 0;
    }
    return count;
}

/*
 * A head is in a mirror set two different ways and only one of them is visible from the
 * head itself. CGDisplayMirrorsDisplay(head) names the master when the head is the copy;
 * when the head is the master — which is what Sidecar produced, the iPad joining onto our
 * head — the head reports nothing and the other display has to be found by asking every
 * display who it mirrors.
 */
static int head_in_mirror_set(uint32_t head) {
    if (CGDisplayMirrorsDisplay(head) != kCGNullDirectDisplay) {
        return 1;
    }
    uint32_t ids[16];
    uint32_t count = online_displays(ids, 16);
    for (uint32_t i = 0; i < count; i++) {
        if (ids[i] != head && CGDisplayMirrorsDisplay(ids[i]) == head) {
            return 1;
        }
    }
    return 0;
}

static void detach_mirror_set(CGDisplayConfigRef config, uint32_t head) {
    if (CGDisplayMirrorsDisplay(head) != kCGNullDirectDisplay) {
        CGConfigureDisplayMirrorOfDisplay(config, head, kCGNullDirectDisplay);
    }
    uint32_t ids[16];
    uint32_t count = online_displays(ids, 16);
    for (uint32_t i = 0; i < count; i++) {
        if (ids[i] != head && CGDisplayMirrorsDisplay(ids[i]) == head) {
            /* Detach the other display, not ours: asking a master to stop mirroring is a
               no-op, and the set survives with the dock still driving the wrong desktop. */
            CGConfigureDisplayMirrorOfDisplay(config, ids[i], kCGNullDirectDisplay);
        }
    }
}

/*
 * Every display's origin, taken before anything is created and put back afterwards.
 * Creating a virtual display makes macOS re-lay-out the whole desktop, and the heads are
 * not the only thing it moves — a Sidecar iPad gets shoved along the row too. Restoring
 * the lot is what keeps the arrangement the user built.
 */
#define MVIEW_SNAPSHOT_CAP 16
static struct {
    uint32_t id;
    int32_t x, y;
} g_snapshot[MVIEW_SNAPSHOT_CAP];
static uint32_t g_snapshot_count;

void mview_displays_snapshot(void) {
    uint32_t ids[MVIEW_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, MVIEW_SNAPSHOT_CAP);
    g_snapshot_count = 0;
    for (uint32_t i = 0; i < count; i++) {
        CGRect bounds = CGDisplayBounds(ids[i]);
        g_snapshot[g_snapshot_count].id = ids[i];
        g_snapshot[g_snapshot_count].x = (int32_t)bounds.origin.x;
        g_snapshot[g_snapshot_count].y = (int32_t)bounds.origin.y;
        g_snapshot_count++;
    }
}

int mview_displays_restore(void) {
    if (g_snapshot_count == 0) {
        return 0;
    }
    uint32_t ids[MVIEW_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, MVIEW_SNAPSHOT_CAP);
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return -1;
    }
    int moved = 0;
    for (uint32_t i = 0; i < g_snapshot_count; i++) {
        for (uint32_t j = 0; j < count; j++) {
            if (ids[j] != g_snapshot[i].id) {
                continue;
            }
            CGRect now = CGDisplayBounds(ids[j]);
            if ((int32_t)now.origin.x != g_snapshot[i].x ||
                (int32_t)now.origin.y != g_snapshot[i].y) {
                CGConfigureDisplayOrigin(config, ids[j], g_snapshot[i].x, g_snapshot[i].y);
                moved = 1;
            }
            break;
        }
    }
    if (!moved) {
        CGCancelDisplayConfiguration(config);
        return 0;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) == kCGErrorSuccess ? 0
                                                                                             : -1;
}

/*
 * Two displays sharing a unit number are one framebuffer as far as the window server is
 * concerned, and ScreenCaptureKit resolves a stream that way: a head that lands on the
 * Sidecar iPad's unit scans out the iPad's desktop instead of its own. Nothing else
 * reports this — CGDisplayMirrorsDisplay says no mirror set exists, both displays report
 * their own bounds and their own mode, and the head looks healthy right up until you
 * notice the panel is showing an iPad.
 */
int mview_display_unit_is_shared(uint32_t id) {
    uint32_t ids[MVIEW_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, MVIEW_SNAPSHOT_CAP);
    uint32_t unit = CGDisplayUnitNumber(id);
    for (uint32_t i = 0; i < count; i++) {
        if (ids[i] != id && CGDisplayUnitNumber(ids[i]) == unit) {
            return 1;
        }
    }
    return 0;
}

/*
 * The arrangement the user last had, in whole pixels. Sidecar attaching or detaching
 * reconfigures every display, and macOS reseats a virtual display wherever it likes when
 * it does; recomputing a default at that point throws away a layout the user arranged by
 * hand. Remembering it means a Sidecar event costs the mirror break and nothing else.
 */
static int32_t g_seat_x[2], g_seat_y[2];
static int g_seated;

/* Already a contiguous left-to-right run, in whole pixels: each head exactly touching the
   next, no gap and no overlap, and all level with each other. A single head is trivially
   a run of one. */
static int heads_are_paired(const uint32_t *ids, int count) {
    for (int i = 1; i < count; i++) {
        CGRect previous = CGDisplayBounds(ids[i - 1]), current = CGDisplayBounds(ids[i]);
        if ((int32_t)current.origin.x != (int32_t)(previous.origin.x + previous.size.width) ||
            (int32_t)current.origin.y != (int32_t)previous.origin.y) {
            return 0;
        }
    }
    return 1;
}

/* Seated the way they should be and scanning out their own desktops. A freshly created
   head is neither — macOS drops new displays at the end of the bottom row — so this is
   what tells a layout the user built from one nobody has arranged yet. */
static int heads_are_healthy(const uint32_t *ids, int count) {
    for (int i = 0; i < count; i++) {
        if (head_in_mirror_set(ids[i])) {
            return 0;
        }
    }
    return heads_are_paired(ids, count);
}

static void remember_seats(const uint32_t *ids, int count) {
    for (int i = 0; i < count && i < MVIEW_MAX_LAYOUT_HEADS; i++) {
        CGRect bounds = CGDisplayBounds(ids[i]);
        g_seat_x[i] = (int32_t)bounds.origin.x;
        g_seat_y[i] = (int32_t)bounds.origin.y;
    }
    g_seated = 1;
}

/*
 * Use a verified native panel as the layout anchor. DisplayLink forwards Dell EDIDs,
 * so excluding built-in and Apple virtual displays does not establish a native route.
 */
static int native_external_bounds(const uint32_t *ids, int count, CGRect *out) {
    uint32_t native = mview_ddc_native_display_id();
    if (!native) return 0;
    for (int i = 0; i < count; i++) {
        if (ids[i] == native) return 0;
    }
    *out = CGDisplayBounds(native);
    return 1;
}

int mview_displays_arrange(const uint32_t *ids, int count, uint32_t width, uint32_t height) {
    if (!ids || count <= 0 || count > MVIEW_MAX_LAYOUT_HEADS) {
        return -1;
    }
    for (int i = 0; i < count; i++) {
        if (!ids[i]) {
            return -1;
        }
    }
    /* Leave a layout the user chose alone, and take a note of it: this is the only moment
       the heads are known to be seated the way the user wants them. */
    if (heads_are_healthy(ids, count)) {
        remember_seats(ids, count);
        return 0;
    }
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return -1;
    }
    /*
     * A head has to scan out its own desktop. macOS will fold a newly created virtual
     * display into an existing mirror set — with Sidecar active one head mirrored the
     * iPad, so the dock drove the iPad's framebuffer at the iPad's aspect ratio.
     */
    for (int i = 0; i < count; i++) {
        detach_mirror_set(config, ids[i]);
    }

    int32_t x, y;
    CGRect native;
    if (g_seated) {
        x = g_seat_x[0];
        y = g_seat_y[0];
    } else if (native_external_bounds(ids, count, &native)) {
        /* Immediately left of the natively attached panel, top-aligned with it. */
        x = (int32_t)CGRectGetMinX(native) - (int32_t)width * count;
        y = (int32_t)CGRectGetMinY(native);
    } else {
        /*
         * Side by side above the main display. macOS otherwise appends each new display to
         * the end of one long row, which puts the dock heads nowhere near each other and
         * nowhere near where they physically sit.
         */
        CGRect main = CGDisplayBounds(CGMainDisplayID());
        x = (int32_t)CGRectGetMidX(main) - (int32_t)width;
        y = (int32_t)CGRectGetMinY(main) - (int32_t)height;
    }
    /* Whole pixels, each head exactly one width along from the last: a gap or an overlap of
       even one pixel is a seam the cursor catches on. */
    for (int i = 0; i < count; i++) {
        CGConfigureDisplayOrigin(config, ids[i], x + (int32_t)width * i, y);
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) != kCGErrorSuccess) {
        return -1;
    }
    for (int i = 0; i < count; i++) {
        g_seat_x[i] = x + (int32_t)width * i;
        g_seat_y[i] = y;
    }
    g_seated = 1;
    return 0;
}

struct WatchState {
    uint32_t ids[MVIEW_MAX_LAYOUT_HEADS];
    int count;
    uint32_t width, height;
};
static struct WatchState g_watch;

static void reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags,
                         void *userInfo) {
    (void)display;
    (void)userInfo;
    /* Only the settled half of the notification. Reconfiguring from inside the "about to
       change" phase deadlocks against the transaction already in flight. */
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    if (g_watch.count <= 0) {
        return;
    }
    struct WatchState watch = g_watch;
    /* Sidecar reports through several callbacks as it attaches, and the mirror set is not
       in place until the last of them. Re-asserting a beat later sees the final state. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     struct WatchState settled = watch;
                     mview_displays_arrange(settled.ids, settled.count, settled.width,
                                            settled.height);
                   });
}

void mview_displays_watch(const uint32_t *ids, int count, uint32_t width, uint32_t height) {
    if (!ids || count <= 0 || count > MVIEW_MAX_LAYOUT_HEADS) {
        return;
    }
    for (int i = 0; i < count; i++) {
        g_watch.ids[i] = ids[i];
    }
    g_watch.count = count;
    g_watch.width = width;
    g_watch.height = height;
    static int registered;
    if (!registered) {
        registered = CGDisplayRegisterReconfigurationCallback(reconfigured, NULL) == kCGErrorSuccess;
    }
}

int mview_display_mode(uint32_t id, uint32_t *width, uint32_t *height, double *refresh_hz) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
    if (!mode) {
        return -1;
    }
    if (width) {
        *width = (uint32_t)CGDisplayModeGetPixelWidth(mode);
    }
    if (height) {
        *height = (uint32_t)CGDisplayModeGetPixelHeight(mode);
    }
    if (refresh_hz) {
        *refresh_hz = CGDisplayModeGetRefreshRate(mode);
    }
    CGDisplayModeRelease(mode);
    return 0;
}

/* Non-zero when `id` is showing another display's framebuffer. */
int mview_display_is_mirrored(uint32_t id) {
    return CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay;
}

