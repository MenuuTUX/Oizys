#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include "oizys_display.h"
#include "oizys_config.h"
#include "oizys_ddc.h"
#include "oizys_usb.h"   /* oizys_log */
#include <stdlib.h>
#include <time.h>

/*
 * Apple's own virtual panels: Sidecar iPads and AirPlay receivers both report the vendor
 * 'aapl' and are not built in. They matter here for one reason — macOS will fold a freshly
 * created virtual display into a mirror set with one of them, and then the dock scans out
 * the iPad's framebuffer at the iPad's aspect ratio instead of its own desktop.
 */
int oizys_display_is_sidecar(uint32_t id) {
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
 * Every display's origin and mode, taken before anything is created and put back afterwards.
 *
 * Creating a virtual display makes macOS re-lay-out the whole desktop, and the heads are
 * not the only thing it moves — a Sidecar iPad gets shoved along the row too. Restoring
 * the lot is what keeps the arrangement the user built.
 *
 * The mode matters for the same reason and is the more damaging half. macOS stores a
 * resolution per *set* of attached displays, and a set it has not seen before gets a
 * conservative default rather than the one the user picked for a smaller set. Adding two
 * Oizys heads makes a new set every time the rest of the desk changes, so a laptop panel
 * the owner runs at its "More Space" scaled mode comes back a step smaller. Nothing here
 * used to notice: the origins were put back, the layout was then committed permanently,
 * and the write cemented the smaller mode as what that set means. One attach, and the main
 * display is smaller until somebody sets it by hand again.
 */
#define OIZYS_SNAPSHOT_CAP 16
static struct {
    uint32_t id;
    int32_t x, y;
    CGDisplayModeRef mode; /* retained; NULL when the display would not report one */
} g_snapshot[OIZYS_SNAPSHOT_CAP];
static uint32_t g_snapshot_count;

/* A mode copied now is a different object from the same mode copied a second ago, so the
   comparison is on what a mode actually is: its point size, its backing pixels — the two
   differ on a scaled Retina mode, and that is exactly the pair that shifts here — and its
   refresh rate. */
static int modes_differ(CGDisplayModeRef a, CGDisplayModeRef b) {
    if (!a || !b) {
        return a != b;
    }
    return CGDisplayModeGetWidth(a) != CGDisplayModeGetWidth(b) ||
           CGDisplayModeGetHeight(a) != CGDisplayModeGetHeight(b) ||
           CGDisplayModeGetPixelWidth(a) != CGDisplayModeGetPixelWidth(b) ||
           CGDisplayModeGetPixelHeight(a) != CGDisplayModeGetPixelHeight(b) ||
           CGDisplayModeGetRefreshRate(a) != CGDisplayModeGetRefreshRate(b);
}

static void forget_snapshot(void) {
    for (uint32_t i = 0; i < g_snapshot_count; i++) {
        if (g_snapshot[i].mode) {
            CGDisplayModeRelease(g_snapshot[i].mode);
            g_snapshot[i].mode = NULL;
        }
    }
    g_snapshot_count = 0;
}

void oizys_displays_snapshot(void) {
    uint32_t ids[OIZYS_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, OIZYS_SNAPSHOT_CAP);
    forget_snapshot();
    for (uint32_t i = 0; i < count; i++) {
        CGRect bounds = CGDisplayBounds(ids[i]);
        g_snapshot[g_snapshot_count].id = ids[i];
        g_snapshot[g_snapshot_count].x = (int32_t)bounds.origin.x;
        g_snapshot[g_snapshot_count].y = (int32_t)bounds.origin.y;
        g_snapshot[g_snapshot_count].mode = CGDisplayCopyDisplayMode(ids[i]);
        g_snapshot_count++;
    }
}

/*
 * Stage the snapshot into an open transaction. Returns how many changes were staged, so a
 * caller that stages several plans can commit once and blank the desk once.
 */
static int plan_restore(CGDisplayConfigRef config) {
    if (g_snapshot_count == 0) {
        return 0;
    }
    int keep_modes = oizys_config_keep_modes();
    uint32_t ids[OIZYS_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, OIZYS_SNAPSHOT_CAP);
    int changed = 0;
    for (uint32_t i = 0; i < g_snapshot_count; i++) {
        for (uint32_t j = 0; j < count; j++) {
            if (ids[j] != g_snapshot[i].id) {
                continue;
            }
            CGRect now = CGDisplayBounds(ids[j]);
            if ((int32_t)now.origin.x != g_snapshot[i].x ||
                (int32_t)now.origin.y != g_snapshot[i].y) {
                CGConfigureDisplayOrigin(config, ids[j], g_snapshot[i].x, g_snapshot[i].y);
                changed = 1;
            }
            if (keep_modes && g_snapshot[i].mode) {
                CGDisplayModeRef current = CGDisplayCopyDisplayMode(ids[j]);
                if (modes_differ(current, g_snapshot[i].mode)) {
                    oizys_log("display %u came back at %zux%zu; putting %zux%zu back",
                              ids[j], current ? CGDisplayModeGetWidth(current) : (size_t)0,
                              current ? CGDisplayModeGetHeight(current) : (size_t)0,
                              CGDisplayModeGetWidth(g_snapshot[i].mode),
                              CGDisplayModeGetHeight(g_snapshot[i].mode));
                    CGConfigureDisplayWithDisplayMode(config, ids[j], g_snapshot[i].mode, NULL);
                    changed = 1;
                }
                if (current) {
                    CGDisplayModeRelease(current);
                }
            }
            break;
        }
    }
    return changed;
}

/* Commit a transaction, or drop it when nothing was staged. Cancelling is not a failure:
   it is the case where the desk is already right and must not be blanked to prove it. */
static int commit(CGDisplayConfigRef config, int staged) {
    if (staged <= 0) {
        CGCancelDisplayConfiguration(config);
        return staged < 0 ? -1 : 0;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently) == kCGErrorSuccess ? 0
                                                                                             : -1;
}

int oizys_displays_restore(void) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return -1;
    }
    return commit(config, plan_restore(config));
}

/*
 * Two displays sharing a unit number are one framebuffer as far as the window server is
 * concerned, and ScreenCaptureKit resolves a stream that way: a head that lands on the
 * Sidecar iPad's unit scans out the iPad's desktop instead of its own. Nothing else
 * reports this — CGDisplayMirrorsDisplay says no mirror set exists, both displays report
 * their own bounds and their own mode, and the head looks healthy right up until you
 * notice the panel is showing an iPad.
 */
int oizys_display_unit_is_shared(uint32_t id) {
    uint32_t ids[OIZYS_SNAPSHOT_CAP];
    uint32_t count = online_displays(ids, OIZYS_SNAPSHOT_CAP);
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
    for (int i = 0; i < count && i < OIZYS_MAX_LAYOUT_HEADS; i++) {
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
    uint32_t native = oizys_ddc_native_display_id();
    if (!native) return 0;
    for (int i = 0; i < count; i++) {
        if (ids[i] == native) return 0;
    }
    *out = CGDisplayBounds(native);
    return 1;
}

/*
 * Stage the head layout into an open transaction. Returns 1 when it staged anything, 0 when
 * the heads are already seated the way they should be, -1 on a bad argument. Nothing here
 * commits: seating and restoring belong in the same transaction, and the pending seats are
 * only recorded once the caller's commit succeeds.
 */
static int32_t g_pending_x[OIZYS_MAX_LAYOUT_HEADS], g_pending_y[OIZYS_MAX_LAYOUT_HEADS];
static int g_pending_count;

static int plan_arrange(CGDisplayConfigRef config, const uint32_t *ids, int count,
                        uint32_t width, uint32_t height) {
    g_pending_count = 0;
    if (!ids || count <= 0 || count > OIZYS_MAX_LAYOUT_HEADS) {
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
        g_pending_x[i] = x + (int32_t)width * i;
        g_pending_y[i] = y;
    }
    g_pending_count = count;
    return 1;
}

/* Adopt the seats a committed plan actually put the heads in. */
static void seats_committed(void) {
    for (int i = 0; i < g_pending_count; i++) {
        g_seat_x[i] = g_pending_x[i];
        g_seat_y[i] = g_pending_y[i];
    }
    if (g_pending_count > 0) {
        g_seated = 1;
    }
    g_pending_count = 0;
}

int oizys_displays_arrange(const uint32_t *ids, int count, uint32_t width, uint32_t height) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return -1;
    }
    int staged = plan_arrange(config, ids, count, width, height);
    int rc = commit(config, staged);
    if (rc == 0) {
        seats_committed();
    }
    return rc;
}

/*
 * Both plans, one commit.
 *
 * Restoring and seating are two writes to the same thing, and every commit is a mode set:
 * the whole desk goes black for a beat, every window server client redraws, and the dock's
 * heads renegotiate. Running them as separate transactions is what made a boot blink several
 * times in a row. Staged together they are one blank, and a desk that is already correct
 * stages nothing and does not blink at all.
 */
int oizys_displays_settle(const uint32_t *ids, int count, uint32_t width, uint32_t height) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return -1;
    }
    int staged = plan_restore(config);
    int seating = plan_arrange(config, ids, count, width, height);
    if (seating < 0) {
        CGCancelDisplayConfiguration(config);
        return -1;
    }
    int rc = commit(config, staged + seating);
    if (rc == 0) {
        seats_committed();
    }
    return rc;
}

struct WatchState {
    uint32_t ids[OIZYS_MAX_LAYOUT_HEADS];
    int count;
    uint32_t width, height;
};
static struct WatchState g_watch;

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

/*
 * A resolution changing has two entirely different causes and the same callback, so telling
 * them apart is the whole job here.
 *
 * A display arriving or leaving makes macOS pick the stored resolution for the new set of
 * screens, which is where the shrunken laptop panel comes from. That is fallout, and it is
 * put back. Somebody choosing a resolution in System Settings is not fallout, and putting
 * that back would be a menu-bar app fighting the user's own hands.
 *
 * The separator is time: fallout lands in the same breath as the attach. Beyond this many
 * seconds past a topology change, a mode that has moved is taken as intentional and becomes
 * the new snapshot.
 */
#define OIZYS_TOPOLOGY_SETTLE_S 5.0
static double g_topology_at;

/*
 * One settle per burst, not one per callback.
 *
 * A single display arriving raises this callback many times -- once for the begin phase and
 * once for the end phase of every display in the set, and again for each of macOS's own
 * intermediate steps. Booting with the dock attached raised dozens. Each one used to
 * schedule its own restore and its own arrange, so the desk was still being reconfigured
 * when the next batch landed, and every one of those reconfigurations is a screen blank: the
 * flicker was Oizys answering itself.
 *
 * So the callbacks re-arm a single deadline instead of stacking work behind it. The block
 * that eventually runs checks whether the deadline moved while it was waiting and, if it
 * did, waits out the remainder rather than acting on a state that is still changing. What
 * comes out the far side is exactly one settle per burst, and that settle is one
 * transaction, so a topology change costs one blank however many callbacks announced it.
 */
#define OIZYS_SETTLE_DELAY_S 0.4
static double g_settle_deadline;
static int g_settle_armed;

static void settle_after(double seconds);

static void settle_now(void) {
    if (monotonic_seconds() < g_settle_deadline) {
        settle_after(g_settle_deadline - monotonic_seconds());
        return;
    }
    g_settle_armed = 0;
    struct WatchState watch = g_watch;
    if (watch.count <= 0) {
        return;
    }
    /* A mode that moved in the same breath as an attach is fallout and is put back; one that
       moved long after it is the user's own choice and becomes the new snapshot. */
    if (monotonic_seconds() - g_topology_at >= OIZYS_TOPOLOGY_SETTLE_S) {
        oizys_displays_snapshot();
    }
    oizys_displays_settle(watch.ids, watch.count, watch.width, watch.height);
}

static void settle_after(double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ settle_now(); });
}

static void reconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags,
                         void *userInfo) {
    (void)display;
    (void)userInfo;
    /* Only the settled half of the notification. Reconfiguring from inside the "about to
       change" phase deadlocks against the transaction already in flight. */
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                 kCGDisplayDisabledFlag)) {
        g_topology_at = monotonic_seconds();
    }
    if (g_watch.count <= 0) {
        return;
    }
    g_settle_deadline = monotonic_seconds() + OIZYS_SETTLE_DELAY_S;
    if (!g_settle_armed) {
        g_settle_armed = 1;
        settle_after(OIZYS_SETTLE_DELAY_S);
    }
}

void oizys_displays_watch(const uint32_t *ids, int count, uint32_t width, uint32_t height) {
    if (!ids || count <= 0 || count > OIZYS_MAX_LAYOUT_HEADS) {
        return;
    }
    for (int i = 0; i < count; i++) {
        g_watch.ids[i] = ids[i];
    }
    g_watch.count = count;
    g_watch.width = width;
    g_watch.height = height;
    /* Arming happens moments after the heads were created, which is itself the topology
       change everything below is about. Without this the first callback to arrive would be
       read as somebody choosing a resolution and the shrunken mode adopted as intended. */
    g_topology_at = monotonic_seconds();
    static int registered;
    if (!registered) {
        registered = CGDisplayRegisterReconfigurationCallback(reconfigured, NULL) == kCGErrorSuccess;
    }
}

int oizys_display_mode(uint32_t id, uint32_t *width, uint32_t *height, double *refresh_hz) {
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
int oizys_display_is_mirrored(uint32_t id) {
    return CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay;
}

