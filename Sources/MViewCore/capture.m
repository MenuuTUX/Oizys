#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>

#include "mview_capture.h"
#include <stdatomic.h>
#include <stdio.h>

#define MVIEW_CAPTURE_MAX_HEADS 4
#define MVIEW_CAPTURE_WIDTH 1920
#define MVIEW_CAPTURE_HEIGHT 1080

/*
 * Write one captured frame to logs/ so a human can see what ScreenCaptureKit handed the
 * encoder. A faithfully encoded black desktop and a broken encoder look identical on the
 * panel; this tells them apart.
 */
static void dump_frame(CVPixelBufferRef pixels, const char *path) {
    void *base = CVPixelBufferGetBaseAddress(pixels);
    if (!base) {
        return;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        base, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 8,
        CVPixelBufferGetBytesPerRow(pixels), space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) {
        return;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef out =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (out) {
        CGImageDestinationAddImage(out, image, NULL);
        CGImageDestinationFinalize(out);
        CFRelease(out);
    }
    CGImageRelease(image);
}

@interface MViewCaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) uint8_t head;
@property(nonatomic) MViewDriver *driver;
@end

@implementation MViewCaptureOutput {
    atomic_int _frames;
    atomic_bool _enabled;
    atomic_bool _failed;
    char _failure[160];
}

- (instancetype)initWithHead:(uint8_t)head driver:(MViewDriver *)driver {
    self = [super init];
    if (self) {
        _head = head;
        _driver = driver;
        atomic_init(&_frames, 0);
        atomic_init(&_enabled, true);
        atomic_init(&_failed, false);
        _failure[0] = '\0';
    }
    return self;
}

- (void)recordFailure:(const char *)message {
    /* First failure wins; the watchdog only needs to know the head died once. */
    bool expected = false;
    if (!atomic_compare_exchange_strong(&_failed, &expected, true)) {
        return;
    }
    snprintf(_failure, sizeof(_failure), "%s", message);
    atomic_store(&_enabled, false);
    fprintf(stderr, "head %u %s\n", _head, message);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    (void)stream;
    if (!atomic_load(&_enabled) || type != SCStreamOutputTypeScreen ||
        !CMSampleBufferIsValid(sampleBuffer)) {
        return;
    }
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels || CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA) {
        return;
    }
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pixels);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        return;
    }
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(pixels);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(pixels);
    int frame = atomic_load(&_frames);

    if (frame == 0 || frame == 30) {
        char path[128];
        snprintf(path, sizeof(path), "logs/capture-head%u-frame%d.png", _head, frame);
        dump_frame(pixels, path);
    }
    /* A near-black desktop and a broken encoder look identical on the panel. Report what we
       are actually being handed so the log can tell them apart. */
    if (frame % 15 == 0) {
        unsigned long total = 0;
        unsigned peak = 0, sampled = 0;
        for (uint32_t y = 0; y < height; y += 8) {
            for (uint32_t x = 0; x < width; x += 8) {
                const uint8_t *p = base + (size_t)y * stride + (size_t)x * 4;
                unsigned luma = ((unsigned)p[0] + p[1] + p[2]) / 3;
                total += luma;
                peak = luma > peak ? luma : peak;
                sampled++;
            }
        }
        fprintf(stderr, "head %u frame %d: mean luma %lu/255, peak %u/255\n", _head, frame,
                sampled ? total / sampled : 0, peak);
    }

    int result = mview_driver_present_bgra_mosaic(_driver, _head, base, stride, width, height);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    if (result < 0) {
        [self recordFailure:"desktop presentation failed; see logs/run.log"];
    } else {
        atomic_fetch_add(&_frames, 1);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    char message[160];
    snprintf(message, sizeof(message), "ScreenCaptureKit stopped: %s",
             error.localizedDescription.UTF8String ?: "unknown");
    [self recordFailure:message];
}

- (void)disable {
    atomic_store(&_enabled, false);
}

- (int)frames {
    return atomic_load(&_frames);
}

- (const char *)failure {
    return atomic_load(&_failed) ? _failure : NULL;
}
@end

struct MViewCapture {
    CFTypeRef streams[MVIEW_CAPTURE_MAX_HEADS];
    CFTypeRef outputs[MVIEW_CAPTURE_MAX_HEADS];
    int count;
    dispatch_queue_t queue;
    dispatch_source_t refresh;
};

/* Block until the callback-based API answers; the caller is a plain C startup path. */
static SCShareableContent *shareable_content_sync(void) {
    __block SCShareableContent *content = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *result,
                                                                     NSError *error) {
                                                   (void)error;
                                                   content = result;
                                                   dispatch_semaphore_signal(done);
                                                 }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return content;
}

static BOOL start_capture_sync(SCStream *stream) {
    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [stream startCaptureWithCompletionHandler:^(NSError *error) {
      ok = (error == nil);
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ok;
}

static void stop_capture_sync(SCStream *stream) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {
      (void)error;
      dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

MViewCapture *mview_capture_start(const uint32_t *display_ids, int count, MViewDriver *driver,
                                  char *error, size_t error_capacity) {
    if (!display_ids || count <= 0 || count > MVIEW_CAPTURE_MAX_HEADS || !driver) {
        return NULL;
    }
    @autoreleasepool {
        SCShareableContent *content = shareable_content_sync();
        if (!content) {
            if (error) {
                snprintf(error, error_capacity, "ScreenCaptureKit returned no shareable content; "
                                                "grant Screen Recording access");
            }
            return NULL;
        }
        MViewCapture *capture = calloc(1, sizeof(*capture));
        if (!capture) {
            return NULL;
        }
        capture->queue = dispatch_queue_create_with_target(
            "mview.capture.serial",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                    QOS_CLASS_USER_INTERACTIVE, 0),
            NULL);
        for (int head = 0; head < count; head++) {
            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == display_ids[head]) {
                    display = candidate;
                    break;
                }
            }
            if (!display) {
                if (error) {
                    snprintf(error, error_capacity, "virtual display %u is not capturable",
                             display_ids[head]);
                }
                mview_capture_stop(capture);
                return NULL;
            }
            /* A head running at anything but its own mode is showing someone else's desktop —
               a mirror set, most likely. Scaling that into the encoder gives the dock a
               stretched picture and no clue why. */
            if (display.width != MVIEW_CAPTURE_WIDTH || display.height != MVIEW_CAPTURE_HEIGHT) {
                if (error) {
                    snprintf(error, error_capacity,
                             "virtual display %u is %ldx%ld, not %dx%d; it is probably mirroring "
                             "another display",
                             display_ids[head], (long)display.width, (long)display.height,
                             MVIEW_CAPTURE_WIDTH, MVIEW_CAPTURE_HEIGHT);
                }
                mview_capture_stop(capture);
                return NULL;
            }
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = MVIEW_CAPTURE_WIDTH;
            configuration.height = MVIEW_CAPTURE_HEIGHT;
            /* Only the strips that moved reach the wire, so the frame rate costs what the
               screen actually changes. Lower this first if the dock complains. */
            configuration.minimumFrameInterval = CMTimeMake(1, 60);
            configuration.queueDepth = 3;
            configuration.pixelFormat = kCVPixelFormatType_32BGRA;
            configuration.showsCursor = YES;
            configuration.capturesAudio = NO;

            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                             excludingWindows:@[]];
            MViewCaptureOutput *output = [[MViewCaptureOutput alloc] initWithHead:(uint8_t)head
                                                                          driver:driver];
            SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                                  configuration:configuration
                                                       delegate:output];
            NSError *add_error = nil;
            if (![stream addStreamOutput:output
                                    type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:capture->queue
                                   error:&add_error] ||
                !start_capture_sync(stream)) {
                if (error) {
                    snprintf(error, error_capacity, "head %d could not start capture: %s", head,
                             add_error.localizedDescription.UTF8String ?: "startCapture failed");
                }
                mview_capture_stop(capture);
                return NULL;
            }
            capture->streams[head] = CFBridgingRetain(stream);
            capture->outputs[head] = CFBridgingRetain(output);
            capture->count = head + 1;
        }
        return capture;
    }
}

void mview_capture_start_refresh_clock(MViewCapture *capture, MViewDriver *driver, int heads,
                                       int hz) {
    if (!capture || !driver || hz <= 0) {
        return;
    }
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, capture->queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                              (uint64_t)(NSEC_PER_SEC / (unsigned)hz), 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      if (mview_driver_service_control(driver) < 0) {
          fprintf(stderr, "control session keepalive failed; see logs/run.log\n");
          return;
      }
      for (int head = 0; head < heads; head++) {
          if (mview_driver_refresh_head(driver, (uint8_t)head) < 0) {
              fprintf(stderr, "head %d scanout refresh failed; see logs/run.log\n", head);
              return;
          }
      }
    });
    dispatch_resume(timer);
    capture->refresh = timer;
}

int mview_capture_frames(const MViewCapture *capture, int head) {
    if (!capture || head < 0 || head >= capture->count) {
        return 0;
    }
    return [(__bridge MViewCaptureOutput *)capture->outputs[head] frames];
}

const char *mview_capture_failure(const MViewCapture *capture, int head) {
    if (!capture || head < 0 || head >= capture->count) {
        return NULL;
    }
    return [(__bridge MViewCaptureOutput *)capture->outputs[head] failure];
}

int mview_capture_head_count(const MViewCapture *capture) {
    return capture ? capture->count : 0;
}

void mview_capture_stop(MViewCapture *capture) {
    if (!capture) {
        return;
    }
    if (capture->refresh) {
        dispatch_source_cancel(capture->refresh);
        capture->refresh = NULL;
    }
    for (int head = 0; head < capture->count; head++) {
        if (capture->outputs[head]) {
            [(__bridge MViewCaptureOutput *)capture->outputs[head] disable];
        }
    }
    for (int head = 0; head < capture->count; head++) {
        if (capture->streams[head]) {
            stop_capture_sync((__bridge SCStream *)capture->streams[head]);
            CFRelease(capture->streams[head]);
            capture->streams[head] = NULL;
        }
        if (capture->outputs[head]) {
            CFRelease(capture->outputs[head]);
            capture->outputs[head] = NULL;
        }
    }
    /* Let any callback already inside the queue finish before the driver goes away. */
    if (capture->queue) {
        dispatch_sync(capture->queue, ^{
        });
    }
    free(capture);
}
