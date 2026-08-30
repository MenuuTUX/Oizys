#pragma once
#include "mview_dl3.h"
#include <CoreMedia/CoreMedia.h>
#include <dispatch/dispatch.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MViewCaptureOutput MViewCaptureOutput;
MViewCaptureOutput *mview_output_create(MViewDriver *driver, uint8_t head, dispatch_queue_t queue);
/* Borrows the sample; retains at most one pending complete frame. Status 0 = complete. */
void mview_output_enqueue(MViewCaptureOutput *output, CMSampleBufferRef sample, int status, uint64_t display_time);
void mview_output_fail(MViewCaptureOutput *output, const char *message);
void mview_output_disable(MViewCaptureOutput *output);
void mview_output_destroy(MViewCaptureOutput *output); /* after draining producer/worker queues */
int mview_output_frames(const MViewCaptureOutput *output);
const char *mview_output_failure(const MViewCaptureOutput *output);
int mview_output_needs_refresh(MViewCaptureOutput *output); /* worker queue only */
void mview_output_report(MViewCaptureOutput *output); /* worker queue only */
#ifdef __cplusplus
}
#endif
