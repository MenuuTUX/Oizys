#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The dock has two heads; the layout code never seats more than that. Kept here so
   display.mm needs nothing from the DL3 protocol headers. */
#define MVIEW_MAX_LAYOUT_HEADS 2

typedef struct MViewVirtualDisplay MViewVirtualDisplay;

typedef struct {
    const char *name;
    uint32_t width;
    uint32_t height;
    double refresh_hz;
    uint32_t vendor_id;
    uint32_t product_id;
    uint32_t serial;
    double mm_width;
    double mm_height;
} MViewVirtualDisplayDesc;

MViewVirtualDisplay *mview_virtual_display_create(const MViewVirtualDisplayDesc *desc);
uint32_t mview_virtual_display_id(const MViewVirtualDisplay *display);
void mview_virtual_display_destroy(MViewVirtualDisplay *display);
/* Break any mirror set the heads were folded into and seat them in a left-to-right run.
 * A layout the user has already arranged themselves is left alone. With a single head and
 * a natively attached external display present, the head is seated beside that display
 * rather than above the main one. */
int mview_displays_arrange(const uint32_t *ids, int count, uint32_t width, uint32_t height);
/* The mode a display actually ended up in, which is not always the one it was asked for. */
int mview_display_mode(uint32_t id, uint32_t *width, uint32_t *height, double *refresh_hz);
/* Non-zero when this display is showing another display's framebuffer. */
int mview_display_is_mirrored(uint32_t id);
/* Non-zero for an Apple virtual panel — a Sidecar iPad or an AirPlay receiver. macOS folds
 * a newly created virtual display into a mirror set with one of these, which puts the
 * iPad's framebuffer on the dock at the iPad's aspect ratio. */
int mview_display_is_sidecar(uint32_t id);
/* Re-assert the arrangement whenever macOS reconfigures the displays. Sidecar attaching or
 * detaching mid-session is the case this exists for: it remirrors a head and reseats both,
 * and nothing else notices. */
void mview_displays_watch(const uint32_t *ids, int count, uint32_t width, uint32_t height);
/* Non-zero when another display shares this one's unit number. Two displays on one unit are
 * one framebuffer to the window server, and ScreenCaptureKit will hand back the other
 * display's desktop for a stream opened on this one. */
int mview_display_unit_is_shared(uint32_t id);
/* Record every display's origin, and put them all back. Creating a virtual display makes
 * macOS re-lay-out the desktop and move displays that have nothing to do with the dock. */
void mview_displays_snapshot(void);
int mview_displays_restore(void);

#ifdef __cplusplus
}
#endif
