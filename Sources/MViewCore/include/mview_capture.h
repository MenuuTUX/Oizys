#ifndef MVIEW_CAPTURE_H
#define MVIEW_CAPTURE_H

#include <stdint.h>
#include "mview_dl3.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MViewCapture MViewCapture;

/*
 * Forward each virtual display's desktop to its physical head. `display_ids` holds one
 * CGDirectDisplayID per head. Returns NULL and fills `error` (when non-NULL) if a head is
 * not capturable, is not 1920x1080, or ScreenCaptureKit refuses to start.
 */
MViewCapture *mview_capture_start(const uint32_t *display_ids, int count, MViewDriver *driver,
                                  char *error, size_t error_capacity);

/*
 * The control session's own cadence, which the capture callback cannot carry: ScreenCaptureKit
 * delivers frames only on change, and a still desktop stops it entirely. The dock still expects
 * a 13 ms status poll and a 3 s heartbeat, and tears the link down without them. Also pays any
 * transmission debt a strip owes to the remaining dock buffers. Ticks at `hz`; the driver gates
 * itself on the real intervals, so this only has to be faster than the shorter of them.
 */
void mview_capture_start_refresh_clock(MViewCapture *capture, MViewDriver *driver, int heads,
                                       int hz);

int mview_capture_frames(const MViewCapture *capture, int head);
/* NULL while the head is healthy. */
const char *mview_capture_failure(const MViewCapture *capture, int head);
int mview_capture_head_count(const MViewCapture *capture);
void mview_capture_stop(MViewCapture *capture);

#ifdef __cplusplus
}
#endif
#endif
