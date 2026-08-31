// Test the shipping C queue with real CoreMedia surfaces, without a screen or dock.
#define oizys_driver_present_bgra_dirty test_present
#define oizys_config test_config
#include "../../Sources/OizysCore/capture_frame.c"
static int presented, last_pixel;
static OizysConfig config;
const OizysConfig *test_config(void) { return &config; }
static int last_rect_count;
int test_present(OizysDriver *driver, uint8_t head, const uint8_t *pixels, size_t stride,
                 uint32_t width, uint32_t height, const OizysDirtyRect *rects, int rect_count) {
    presented++; last_pixel = pixels[0]; last_rect_count = rect_count; return 0;
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
    dispatch_queue_t worker = dispatch_queue_create("oizys.test.capture", DISPATCH_QUEUE_SERIAL);
    OizysCaptureOutput *output = oizys_output_create(NULL, 0, worker);
    dispatch_suspend(worker);
    for (int i = 1; i <= 200; i++) {
        CMSampleBufferRef buffer = sample((uint8_t)i);
        oizys_output_enqueue(output, buffer, 0, mach_absolute_time(), NULL, 0); CFRelease(buffer);
    }
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    int failure = presented != 1 || last_pixel != 200 ? 1 : 0;
    for (int status = 1; status <= 5; status++) {
        CMSampleBufferRef buffer = sample(50);
        oizys_output_enqueue(output, buffer, status, 0, NULL, 0); CFRelease(buffer);
    }
    dispatch_sync(worker, ^{});
    if (presented != 1) failure |= 2;
    dispatch_suspend(worker);
    CMSampleBufferRef buffer = sample(77);
    oizys_output_enqueue(output, buffer, 0, 0, NULL, 0); oizys_output_disable(output);
    oizys_output_enqueue(output, buffer, 0, 0, NULL, 0); CFRelease(buffer);
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    if (presented != 1) failure |= 4;
    oizys_output_fail(output, "first failure"); oizys_output_fail(output, "second failure");
    if (strcmp(oizys_output_failure(output), "first failure")) failure |= 8;
    oizys_output_destroy(output);

    /* A replaced frame's dirty rects have to survive into the frame that replaces it. The
       dropped frame's changes were never fingerprinted, so forgetting where they were
       would leave those strips stale until the verification sweep happened past them. */
    OizysCaptureOutput *union_output = oizys_output_create(NULL, 0, worker);
    dispatch_suspend(worker);
    OizysDirtyRect first = {0, 0, 4, 4}, second = {8, 8, 4, 4};
    CMSampleBufferRef early = sample(11), late = sample(12);
    oizys_output_enqueue(union_output, early, 0, 0, &first, 1);
    oizys_output_enqueue(union_output, late, 0, 0, &second, 1);
    CFRelease(early); CFRelease(late);
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    if (last_rect_count != 2) failure |= 16;

    /* And a frame with no rects at all must not inherit the previous frame's: no rects
       means "read everything", which is the only answer that stays correct. */
    dispatch_suspend(worker);
    CMSampleBufferRef marked = sample(13), blind = sample(14);
    oizys_output_enqueue(union_output, marked, 0, 0, &first, 1);
    oizys_output_enqueue(union_output, blind, 0, 0, NULL, 0);
    CFRelease(marked); CFRelease(blind);
    dispatch_resume(worker); dispatch_sync(worker, ^{});
    if (last_rect_count != 0) failure |= 32;
    oizys_output_destroy(union_output);

    dispatch_release(worker); return failure;
}
