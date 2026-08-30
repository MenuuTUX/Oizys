// Exercise the shipping capture delegate with real CoreMedia buffers, no live display.
#include <initializer_list>
#define MViewCaptureOutput MViewTestCaptureOutput
#define mview_driver_present_bgra_mosaic test_present
#define mview_config test_config
#include "../../Sources/MViewCore/capture.mm"

static int presented;
static int last_pixel;
static MViewConfig config;
const MViewConfig *test_config(void) { return &config; }
int test_present(MViewDriver *, uint8_t, const uint8_t *pixels, size_t, uint32_t, uint32_t) {
    presented++;
    last_pixel = pixels[0];
    return 0;
}

static CMSampleBufferRef sample(uint8_t value, SCFrameStatus status) {
    CVPixelBufferRef pixels = NULL;
    CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &pixels);
    CVPixelBufferLockBaseAddress(pixels, 0);
    memset(CVPixelBufferGetBaseAddress(pixels), value, CVPixelBufferGetDataSize(pixels));
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixels, &format);
    CMSampleTimingInfo timing = {CMTimeMake(1, 60), CMTimeMake(1, 60), kCMTimeInvalid};
    CMSampleBufferRef buffer = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(NULL, pixels, format, &timing, &buffer);
    NSMutableArray *attachments = (__bridge NSMutableArray *)CMSampleBufferGetSampleAttachmentsArray(buffer, true);
    attachments[0][SCStreamFrameInfoStatus] = @(status);
    attachments[0][SCStreamFrameInfoDisplayTime] = @(mach_absolute_time());
    CFRelease(format);
    CFRelease(pixels);
    return buffer;
}

extern "C" int test_capture_queue(void) {
    @autoreleasepool {
        config.capture_fps = 60;
        strcpy(config.log_level, "info");
        presented = last_pixel = 0;
        dispatch_queue_t worker = dispatch_queue_create("mview.test.capture", DISPATCH_QUEUE_SERIAL);
        MViewCaptureOutput *output = [[MViewCaptureOutput alloc] initWithHead:0 driver:NULL];
        output.worker = worker;
        // Saturate a stopped worker with 200 frames. Only the latest may survive.
        dispatch_suspend(worker);
        for (int i = 1; i <= 200; i++) {
            CMSampleBufferRef buffer = sample((uint8_t)i, SCFrameStatusComplete);
            [output stream:nil didOutputSampleBuffer:buffer ofType:SCStreamOutputTypeScreen];
            CFRelease(buffer);
        }
        dispatch_resume(worker);
        dispatch_sync(worker, ^{});
        if (presented != 1 || last_pixel != 200) return 1;
        // Idle/blank callbacks must not replay an old surface.
        for (SCFrameStatus status : {SCFrameStatusIdle, SCFrameStatusBlank, SCFrameStatusSuspended}) {
            CMSampleBufferRef buffer = sample(50, status);
            [output stream:nil didOutputSampleBuffer:buffer ofType:SCStreamOutputTypeScreen];
            CFRelease(buffer);
        }
        dispatch_sync(worker, ^{});
        if (presented != 1) return 2;
        // A shutdown discards the pending frame before the driver can be destroyed.
        dispatch_suspend(worker);
        CMSampleBufferRef buffer = sample(77, SCFrameStatusComplete);
        [output stream:nil didOutputSampleBuffer:buffer ofType:SCStreamOutputTypeScreen];
        [output disable];
        [output stream:nil didOutputSampleBuffer:buffer ofType:SCStreamOutputTypeScreen];
        CFRelease(buffer);
        dispatch_resume(worker);
        dispatch_sync(worker, ^{});
        if (presented != 1) return 3;
        // Only the first complete failure message is published.
        [output recordFailure:"first failure"];
        [output recordFailure:"second failure"];
        if (strcmp([output failure], "first failure")) return 4;
        return 0;
    }
}
