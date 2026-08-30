#include "mview_capture_frame.h"
#include "mview_config.h"
#include "mview_build.h"
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct MViewCaptureOutput {
    MViewDriver *driver;
    uint8_t head;
    dispatch_queue_t worker;
    atomic_int frames;
    atomic_bool enabled, failed;
    char failure[160];
    os_unfair_lock lock;
    CMSampleBufferRef pending;
    uint64_t pending_time;
    MViewDirtyRect pending_rects[MVIEW_CAPTURE_MAX_RECTS];
    int pending_rect_count;
    bool scheduled;
    uint64_t last_present, samples, age_samples, age_ticks, max_age_ticks;
    uint64_t present_ticks, max_present_ticks, dropped;
    /* How often the compositor's rectangles were usable, and how many arrived. A frame
       with none falls back to fingerprinting the whole surface. */
    uint64_t rect_frames, rect_total, full_pass_frames;
};

MViewCaptureOutput *mview_output_create(MViewDriver *driver, uint8_t head, dispatch_queue_t queue) {
    MViewCaptureOutput *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->driver = driver; o->head = head; o->worker = queue;
    o->lock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    atomic_init(&o->frames, 0); atomic_init(&o->enabled, true); atomic_init(&o->failed, false);
    return o;
}

void mview_output_disable(MViewCaptureOutput *o) {
    os_unfair_lock_lock(&o->lock);
    atomic_store(&o->enabled, false);
    if (o->pending) CFRelease(o->pending);
    o->pending = NULL;
    os_unfair_lock_unlock(&o->lock);
}

void mview_output_fail(MViewCaptureOutput *o, const char *message) {
    os_unfair_lock_lock(&o->lock);
    if (atomic_load(&o->failed)) { os_unfair_lock_unlock(&o->lock); return; }
    snprintf(o->failure, sizeof(o->failure), "%s", message);
    atomic_store(&o->failed, true);
    os_unfair_lock_unlock(&o->lock);
    mview_output_disable(o);
    fprintf(stderr, "head %u %s\n", o->head, message);
}

static void dump_frame(CVPixelBufferRef pixels, const char *path) {
    void *base = CVPixelBufferGetBaseAddress(pixels);
    if (!base) {
        return;
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        base, CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 8,
        CVPixelBufferGetBytesPerRow(pixels), space,
        (CGBitmapInfo)((uint32_t)kCGImageAlphaNoneSkipFirst |
                       (uint32_t)kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(space);
    if (!context) {
        return;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) {
        return;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef out = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (url) CFRelease(url);
    if (out) {
        CGImageDestinationAddImage(out, image, NULL);
        CGImageDestinationFinalize(out);
        CFRelease(out);
    }
    CGImageRelease(image);
}

static void present(MViewCaptureOutput *o, CMSampleBufferRef sample, uint64_t displayed,
                    const MViewDirtyRect *rects, int rect_count) {
    uint64_t started = mach_absolute_time();
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels || CVPixelBufferGetPixelFormatType(pixels) != kCVPixelFormatType_32BGRA) {
        return;
    }
    if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        mview_output_fail(o, "could not lock captured pixels");
        return;
    }
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pixels);
    if (!base) {
        CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
        return;
    }
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(pixels);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(pixels);
    int frame = atomic_load(&o->frames);

    if ((frame == 0 || frame == 30) && MVIEW_DIAGNOSTICS && mview_config()->capture_dump_frames) {
        char path[128];
        snprintf(path, sizeof(path), "logs/capture-head%u-frame%d.png", o->head, frame);
        dump_frame(pixels, path);
    }
    /* A near-black desktop and a broken encoder look identical on the panel. Report what we
       are actually being handed so the log can tell them apart. */
    if (MVIEW_DIAGNOSTICS && frame % 60 == 0 && strcmp(mview_config()->log_level, "debug") == 0) {
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
        fprintf(stderr, "head %u frame %d: mean luma %lu/255, peak %u/255\n", o->head, frame,
                sampled ? total / sampled : 0, peak);
    }

    if (rect_count > 0) { o->rect_frames++; o->rect_total += (uint64_t)rect_count; }
    else { o->full_pass_frames++; }
    int result = mview_driver_present_bgra_dirty(o->driver, o->head, base, stride, width, height,
                                                rects, rect_count);
    if (result < 0 && MVIEW_DIAGNOSTICS && mview_config()->capture_dump_frames) {
        char path[96];
        snprintf(path, sizeof(path), "logs/failed-capture-head%u.png", o->head);
        dump_frame(pixels, path);
    }
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    if (result < 0) {
        mview_output_fail(o, "desktop presentation failed; see logs/run.log");
    } else {
        atomic_fetch_add(&o->frames, 1);
        o->last_present = mach_absolute_time();
        if (MVIEW_DIAGNOSTICS) {
            uint64_t work = o->last_present - started;
            o->samples++;
            o->present_ticks += work;
            o->max_present_ticks = work > o->max_present_ticks ? work : o->max_present_ticks;
            if (displayed) {
                // WindowServer can timestamp a frame ahead of this callback. Include
                // it as zero age until that timestamp, rather than biasing the mean
                // by discarding the freshest frames. This is not panel latency.
                uint64_t age = o->last_present > displayed ? o->last_present - displayed : 0;
                o->age_samples++;
                o->age_ticks += age;
                o->max_age_ticks = age > o->max_age_ticks ? age : o->max_age_ticks;
            }
        }
    }
}

static void consume(MViewCaptureOutput *o) {
    MViewDirtyRect rects[MVIEW_CAPTURE_MAX_RECTS];
    os_unfair_lock_lock(&o->lock);
    CMSampleBufferRef sample = o->pending;
    uint64_t timestamp = o->pending_time;
    int rect_count = o->pending_rect_count < 0 ? 0 : o->pending_rect_count;
    if (rect_count > 0) memcpy(rects, o->pending_rects, (size_t)rect_count * sizeof(rects[0]));
    o->pending = NULL; o->scheduled = false; o->pending_rect_count = 0;
    os_unfair_lock_unlock(&o->lock);
    if (!sample) return;
    if (atomic_load(&o->enabled)) present(o, sample, timestamp, rects, rect_count);
    CFRelease(sample);
}

void mview_output_enqueue(MViewCaptureOutput *o, CMSampleBufferRef sample, int status,
                          uint64_t timestamp, const MViewDirtyRect *rects, int rect_count) {
    if (!o || status != 0 || !sample || !CMSampleBufferIsValid(sample)) return;
    if (!rects || rect_count < 0 || rect_count > MVIEW_CAPTURE_MAX_RECTS) rect_count = 0;
    os_unfair_lock_lock(&o->lock);
    if (!atomic_load(&o->enabled)) { os_unfair_lock_unlock(&o->lock); return; }
    /*
     * A replaced frame's rects have to survive into the frame that replaces it. The
     * dropped frame's changes were never fingerprinted, so forgetting where they were
     * would leave those strips stale until the verification sweep reached them. Union the
     * lists; if the union no longer fits, give up on rects for this frame and let the
     * damage ledger read the whole surface, which is always correct.
     */
    if (o->pending) { CFRelease(o->pending); o->dropped++; }
    else o->pending_rect_count = 0;
    if (rect_count == 0 || o->pending_rect_count + rect_count > MVIEW_CAPTURE_MAX_RECTS) {
        o->pending_rect_count = -1;
    } else if (o->pending_rect_count >= 0) {
        memcpy(o->pending_rects + o->pending_rect_count, rects,
               (size_t)rect_count * sizeof(o->pending_rects[0]));
        o->pending_rect_count += rect_count;
    }
    o->pending = (CMSampleBufferRef)CFRetain(sample); o->pending_time = timestamp;
    bool schedule = !o->scheduled; o->scheduled = true;
    os_unfair_lock_unlock(&o->lock);
    if (schedule) dispatch_async(o->worker, ^{ consume(o); });
}

int mview_output_needs_refresh(MViewCaptureOutput *o) {
    if (!atomic_load(&o->enabled) || !o->last_present) return 0;
    os_unfair_lock_lock(&o->lock);
    bool pending = o->pending != NULL;
    os_unfair_lock_unlock(&o->lock);
    if (pending) return 0;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double elapsed = (double)(mach_absolute_time() - o->last_present) * tb.numer / tb.denom;
    return elapsed >= 2.0 * NSEC_PER_SEC / mview_config()->capture_fps;
}

int mview_output_frames(const MViewCaptureOutput *o) { return o ? atomic_load(&o->frames) : 0; }
const char *mview_output_failure(const MViewCaptureOutput *o) { return o && atomic_load(&o->failed) ? o->failure : NULL; }
void mview_output_destroy(MViewCaptureOutput *o) { if (o) { mview_output_disable(o); free(o); } }

void mview_output_report(MViewCaptureOutput *o) {
#if MVIEW_DIAGNOSTICS
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double ms = (double)tb.numer / tb.denom / 1e6;
    os_unfair_lock_lock(&o->lock);
    uint64_t dropped = o->dropped; o->dropped = 0;
    os_unfair_lock_unlock(&o->lock);
    printf("head %u latency: samples=%llu replaced=%llu capture-age-at-USB samples=%llu mean=%.2fms max=%.2fms "
           "processing mean=%.2fms max=%.2fms dirty-rect frames=%llu (mean %.1f rects) "
           "full-pass frames=%llu\n", o->head,
           (unsigned long long)o->samples, (unsigned long long)dropped,
           (unsigned long long)o->age_samples,
           o->age_samples ? o->age_ticks * ms / o->age_samples : 0, o->max_age_ticks * ms,
           o->samples ? o->present_ticks * ms / o->samples : 0, o->max_present_ticks * ms,
           (unsigned long long)o->rect_frames,
           o->rect_frames ? (double)o->rect_total / (double)o->rect_frames : 0.0,
           (unsigned long long)o->full_pass_frames);
    o->samples = o->age_samples = o->age_ticks = o->max_age_ticks = o->present_ticks = o->max_present_ticks = 0;
    o->rect_frames = o->rect_total = o->full_pass_frames = 0;
#endif
}
