// Test the shipping C queue with real CoreMedia surfaces, without a screen or dock.
#define mview_driver_present_bgra_mosaic test_present
#define mview_config test_config
#include "../../Sources/MViewCore/capture_frame.c"
static int presented, last_pixel;
static MViewConfig config;
const MViewConfig *test_config(void) { return &config; }
int test_present(MViewDriver *driver, uint8_t head, const uint8_t *pixels, size_t stride, uint32_t width, uint32_t height) {
    presented++; last_pixel = pixels[0]; return 0;
}
static CMSampleBufferRef sample(uint8_t value) {
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
    CFRelease(format); CFRelease(pixels); return buffer;
}
int test_capture_queue(void) {
    config.capture_fps = 60; strcpy(config.log_level, "info"); presented = last_pixel = 0;
    dispatch_queue_t worker = dispatch_queue_create("mview.test.capture", DISPATCH_QUEUE_SERIAL);
    MViewCaptureOutput *output = mview_output_create(NULL, 0, worker);
    dispatch_suspend(worker);
    for (int i = 1; i <= 200; i++) {
        CMSampleBufferRef buffer = sample((uint8_t)i);
        mview_output_enqueue(output, buffer, 0, mach_absolute_time()); CFRelease(buffer);
    }
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    int failure = presented != 1 || last_pixel != 200 ? 1 : 0;
    for (int status = 1; status <= 5; status++) {
        CMSampleBufferRef buffer = sample(50);
        mview_output_enqueue(output, buffer, status, 0); CFRelease(buffer);
    }
    dispatch_sync(worker, ^{});
    if (presented != 1) failure |= 2;
    dispatch_suspend(worker);
    CMSampleBufferRef buffer = sample(77);
    mview_output_enqueue(output, buffer, 0, 0); mview_output_disable(output);
    mview_output_enqueue(output, buffer, 0, 0); CFRelease(buffer);
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    if (presented != 1) failure |= 4;
    mview_output_fail(output, "first failure"); mview_output_fail(output, "second failure");
    if (strcmp(mview_output_failure(output), "first failure")) failure |= 8;
    mview_output_destroy(output); dispatch_release(worker); return failure;
}
