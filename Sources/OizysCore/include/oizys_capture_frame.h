#pragma once
#include "oizys_dl3.h"
#include <CoreMedia/CoreMedia.h>
#include <dispatch/dispatch.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct OizysCaptureOutput OizysCaptureOutput;
OizysCaptureOutput *oizys_output_create(OizysDriver *driver, uint8_t head, dispatch_queue_t queue);
/* Borrows the sample; retains at most one pending complete frame. Status 0 = complete.
   `rects` is the compositor's changed-rectangle list for this frame, copied by value; a
   count of 0 means the whole surface must be re-fingerprinted. Rects beyond
   OIZYS_CAPTURE_MAX_RECTS are not worth carrying -- that many small rects cost more to
   walk than the strips they would save -- so the list is dropped and the frame falls back
   to a full pass. */
#define OIZYS_CAPTURE_MAX_RECTS 64
void oizys_output_enqueue(OizysCaptureOutput *output, CMSampleBufferRef sample, int status,
                          uint64_t display_time, const OizysDirtyRect *rects, int rect_count);
void oizys_output_fail(OizysCaptureOutput *output, const char *message);
void oizys_output_disable(OizysCaptureOutput *output);
void oizys_output_destroy(OizysCaptureOutput *output); /* after draining producer/worker queues */
int oizys_output_frames(const OizysCaptureOutput *output);
const char *oizys_output_failure(const OizysCaptureOutput *output);
int oizys_output_needs_refresh(OizysCaptureOutput *output); /* worker queue only */
/* Present the last frame again, as if it had just arrived. ScreenCaptureKit delivers only
   what changed, so a desktop nobody is touching produces no frames at all -- and a setting
   that changes how a frame is encoded, rather than what is in it, would otherwise not reach
   the panel until something moved on it. Worker queue only. */
void oizys_output_repaint(OizysCaptureOutput *output);
void oizys_output_report(OizysCaptureOutput *output); /* worker queue only */
#ifdef __cplusplus
}
#endif
