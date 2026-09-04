#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The dock has two heads; the layout code never seats more than that. Kept here so
   display.mm needs nothing from the DL3 protocol headers. */
#define OIZYS_MAX_LAYOUT_HEADS 2

typedef struct OizysVirtualDisplay OizysVirtualDisplay;

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
} OizysVirtualDisplayDesc;

OizysVirtualDisplay *oizys_virtual_display_create(const OizysVirtualDisplayDesc *desc);
uint32_t oizys_virtual_display_id(const OizysVirtualDisplay *display);
void oizys_virtual_display_destroy(OizysVirtualDisplay *display);
/* Break any mirror set the heads were folded into and seat them in a left-to-right run.
 * A layout the user has already arranged themselves is left alone. With a single head and
 * a natively attached external display present, the head is seated beside that display
 * rather than above the main one. */
int oizys_displays_arrange(const uint32_t *ids, int count, uint32_t width, uint32_t height);
/* The mode a display actually ended up in, which is not always the one it was asked for. */
int oizys_display_mode(uint32_t id, uint32_t *width, uint32_t *height, double *refresh_hz);
/* Non-zero when this display is showing another display's framebuffer. */
int oizys_display_is_mirrored(uint32_t id);
/* Non-zero for an Apple virtual panel — a Sidecar iPad or an AirPlay receiver. macOS folds
 * a newly created virtual display into a mirror set with one of these, which puts the
 * iPad's framebuffer on the dock at the iPad's aspect ratio. */
int oizys_display_is_sidecar(uint32_t id);
/* Re-assert the arrangement whenever macOS reconfigures the displays. Sidecar attaching or
 * detaching mid-session is the case this exists for: it remirrors a head and reseats both,
 * and nothing else notices. */
void oizys_displays_watch(const uint32_t *ids, int count, uint32_t width, uint32_t height);
/* Non-zero when another display shares this one's unit number. Two displays on one unit are
 * one framebuffer to the window server, and ScreenCaptureKit will hand back the other
 * display's desktop for a stream opened on this one. */
int oizys_display_unit_is_shared(uint32_t id);
/* Record every display's origin, and put them all back. Creating a virtual display makes
 * macOS re-lay-out the desktop and move displays that have nothing to do with the dock. */
void oizys_displays_snapshot(void);
int oizys_displays_restore(void);
/* Restore and arrange in one display transaction, and therefore one mode set. Two commits
 * are two screen blanks, and the desk blinks once for each; every caller that wants both
 * wants them together. */
int oizys_displays_settle(const uint32_t *ids, int count, uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif
