#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/AppleUSBDefinitions.h>
#import <IOUSBHost/IOUSBHost.h>
#include "mview_usb.h"
#include <pthread.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IN_DEPTH 4
#define IN_BUF 8192
#define INBOX 32

struct MViewSession {
    CFTypeRef device;
    CFTypeRef iface;
    CFTypeRef iface1;
    CFTypeRef ctrl_out;
    CFTypeRef ctrl_in;
    CFTypeRef video0;
    CFTypeRef video1;
    dispatch_queue_t queue;
    CFTypeRef inbufs;
    uint8_t inbox[INBOX][IN_BUF];
    size_t inbox_len[INBOX];
    int inbox_r, inbox_w, inbox_n;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    atomic_int closing;
    uint8_t identity[64];
    int identity_len;
};

static IOUSBHostInterface *session_iface(MViewSession *s) {
    return s && s->iface ? (__bridge IOUSBHostInterface *)s->iface : nil;
}

static IOUSBHostPipe *pipe_for_ep(MViewSession *s, uint8_t ep) {
    CFTypeRef ref = NULL;
    if (ep == MVIEW_EP_CTRL_OUT) {
        ref = s->ctrl_out;
    } else if (ep == MVIEW_EP_CTRL_IN) {
        ref = s->ctrl_in;
    } else if (ep == 0x08) {
        ref = s->video0;
    } else if (ep == 0x0b) {
        ref = s->video1;
    }
    return ref ? (__bridge IOUSBHostPipe *)ref : nil;
}

static int registry_number(io_service_t service, CFStringRef key, int fallback) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int result = fallback;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        (void)CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    }
    if (value) {
        CFRelease(value);
    }
    return result;
}

static io_service_t find_numbered_interface(uint8_t interface_number) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"),
                                     &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    io_service_t selected = IO_OBJECT_NULL;
    for (io_service_t service = IOIteratorNext(iterator); service;
         service = IOIteratorNext(iterator)) {
        int vendor = registry_number(service, CFSTR("idVendor"), -1);
        int number = registry_number(service, CFSTR("bInterfaceNumber"), -1);
        if (vendor == MVIEW_VID && number == interface_number) {
            selected = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return selected;
}

static io_service_t find_displaylink_device(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"),
                                     &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    io_service_t selected = IO_OBJECT_NULL;
    for (io_service_t service = IOIteratorNext(iterator); service;
         service = IOIteratorNext(iterator)) {
        int vendor = registry_number(service, CFSTR("idVendor"), -1);
        if (vendor == MVIEW_VID) {
            selected = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return selected;
}

static int identity_from_configuration(const IOUSBConfigurationDescriptor *configuration,
                                       uint8_t *out, size_t out_cap) {
    if (!configuration || !out || out_cap < 16) {
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)configuration;
    size_t total = (size_t)bytes[2] | ((size_t)bytes[3] << 8);
    for (size_t offset = 0; offset + 2 <= total;) {
        size_t length = bytes[offset];
        if (length < 2 || offset + length > total) {
            break;
        }
        if (bytes[offset + 1] == MVIEW_IDENT_TYPE && length >= 16) {
            size_t copied = length < out_cap ? length : out_cap;
            memcpy(out, bytes + offset, copied);
            return (int)copied;
        }
        offset += length;
    }
    return 0;
}

static IOUSBHostInterface *open_iface(NSNumber *iface_num, NSNumber *cls, NSNumber *sub,
                                      NSNumber *proto, IOUSBHostObjectInitOptions opts,
                                      dispatch_queue_t queue) {
    io_service_t svc = IO_OBJECT_NULL;
    if (iface_num) {
        svc = find_numbered_interface(iface_num.unsignedCharValue);
    } else {
        CFMutableDictionaryRef matching =
            [IOUSBHostInterface createMatchingDictionaryWithVendorID:@(MVIEW_VID)
                                                           productID:nil
                                                           bcdDevice:nil
                                                     interfaceNumber:nil
                                                  configurationValue:nil
                                                      interfaceClass:cls
                                                   interfaceSubclass:sub
                                                   interfaceProtocol:proto
                                                               speed:nil
                                                      productIDArray:nil];
        io_iterator_t iter = IO_OBJECT_NULL;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
            return nil;
        }
        svc = IOIteratorNext(iter);
        IOObjectRelease(iter);
    }
    if (!svc) {
        mview_log("no registry service for DisplayLink interface %s", iface_num ? "numbered" : "DL3");
        return nil;
    }
    NSError *err = nil;
    IOUSBHostInterface *iface = [[IOUSBHostInterface alloc] initWithIOService:svc
                                                                      options:opts
                                                                        queue:queue
                                                                        error:&err
                                                              interestHandler:nil];
    IOObjectRelease(svc);
    if (!iface) {
        mview_log("open iface %s failed: %s", iface_num ? "n" : "dl3",
                  err.localizedDescription.UTF8String ?: "?");
    }
    return iface;
}

static void inbox_push(MViewSession *s, const void *p, size_t n) {
    pthread_mutex_lock(&s->mu);
    if (s->inbox_n < INBOX && n > 0 && n <= IN_BUF) {
        memcpy(s->inbox[s->inbox_w], p, n);
        s->inbox_len[s->inbox_w] = n;
        s->inbox_w = (s->inbox_w + 1) % INBOX;
        s->inbox_n++;
        pthread_cond_signal(&s->cv);
    }
    pthread_mutex_unlock(&s->mu);
}

static void arm_in(MViewSession *s, NSMutableData *buf);

static void in_complete(MViewSession *s, NSMutableData *buf, IOReturn status, NSUInteger n) {
    if (atomic_load(&s->closing)) {
        return;
    }
    if (status == kIOReturnSuccess && n > 0) {
        inbox_push(s, buf.bytes, n);
    }
    arm_in(s, buf);
}

static void arm_in(MViewSession *s, NSMutableData *buf) {
    IOUSBHostPipe *p = pipe_for_ep(s, MVIEW_EP_CTRL_IN);
    if (!p || atomic_load(&s->closing)) {
        return;
    }
    buf.length = IN_BUF;
    NSError *err = nil;
    BOOL ok = [p enqueueIORequestWithData:buf
                        completionTimeout:0
                                    error:&err
                        completionHandler:^(IOReturn status, NSUInteger bytesTransferred) {
                            in_complete(s, buf, status, bytesTransferred);
                        }];
    if (!ok) {
        mview_log("EP84 rearm failed: %s", err.localizedDescription.UTF8String ?: "?");
    }
}

MViewSession *mview_session_open(int capture) {
    @autoreleasepool {
        dispatch_queue_t q = dispatch_queue_create("mview.usb", DISPATCH_QUEUE_SERIAL);
        IOUSBHostDevice *device = nil;
        uint8_t identityCache[64] = {0};
        int identityCacheLength = 0;
        io_service_t deviceService = find_displaylink_device();
        if (deviceService) {
            NSError *deviceError = nil;
            device = [[IOUSBHostDevice alloc] initWithIOService:deviceService
                                                        options:IOUSBHostObjectInitOptionsDeviceSeize
                                                          queue:q
                                                          error:&deviceError
                                                interestHandler:nil];
            IOObjectRelease(deviceService);
            if (!device) {
                mview_log("open DisplayLink device for configuration failed: %s",
                          deviceError.localizedDescription.UTF8String ?: "?");
            } else {
                const IOUSBConfigurationDescriptor *configuration =
                    [device configurationDescriptorWithConfigurationValue:1 error:&deviceError];
                identityCacheLength =
                    identity_from_configuration(configuration, identityCache, sizeof(identityCache));
            }
            if (device && ![device configureWithValue:1 matchInterfaces:YES error:&deviceError]) {
                mview_log("select DisplayLink configuration 1 failed: %s",
                          deviceError.localizedDescription.UTF8String ?: "?");
                [device destroy];
                device = nil;
            } else {
                /* SET_CONFIGURATION terminates and republishes every child interface. */
                usleep(100000);
            }
        }
        /* Claim the app/DFU interface before interface 0 seizes the display function. */
        IOUSBHostInterface *dfu =
            open_iface(@1, nil, nil, nil, IOUSBHostObjectInitOptionsDeviceSeize, q);
        if (!dfu) {
            dfu = open_iface(@1, nil, nil, nil, IOUSBHostObjectInitOptionsNone, q);
        }
        IOUSBHostObjectInitOptions opts =
            capture ? IOUSBHostObjectInitOptionsDeviceCapture : IOUSBHostObjectInitOptionsDeviceSeize;
        IOUSBHostInterface *iface =
            open_iface(nil, @(MVIEW_DL3_CLASS), @(MVIEW_DL3_SUBCLASS), @(MVIEW_DL3_PROTOCOL), opts, q);
        if (!iface) {
            iface = open_iface(nil, @(MVIEW_DL3_CLASS), @(MVIEW_DL3_SUBCLASS),
                               @(MVIEW_DL3_PROTOCOL), IOUSBHostObjectInitOptionsDeviceSeize, q);
        }
        if (!iface) {
            iface = open_iface(nil, @(MVIEW_DL3_CLASS), @(MVIEW_DL3_SUBCLASS), @(MVIEW_DL3_PROTOCOL),
                               IOUSBHostObjectInitOptionsNone, q);
        }
        if (!iface) {
            if (dfu) {
                [dfu destroy];
            }
            if (device) {
                [device destroy];
            }
            return NULL;
        }

        NSError *altError = nil;
        if (![iface selectAlternateSetting:0 error:&altError]) {
            mview_log("select display interface alt 0 failed: %s",
                      altError.localizedDescription.UTF8String ?: "?");
            [iface destroy];
            if (dfu) {
                [dfu destroy];
            }
            if (device) {
                [device destroy];
            }
            return NULL;
        }

        MViewSession *s = (MViewSession *)calloc(1, sizeof(*s));
        if (!s) {
            [iface destroy];
            if (dfu) {
                [dfu destroy];
            }
            if (device) {
                [device destroy];
            }
            return NULL;
        }
        pthread_mutex_init(&s->mu, NULL);
        pthread_cond_init(&s->cv, NULL);
        atomic_init(&s->closing, 0);
        s->queue = q;
        if (device) {
            s->device = CFBridgingRetain(device);
        }
        s->iface = CFBridgingRetain(iface);
        s->ctrl_out = CFBridgingRetain([iface copyPipeWithAddress:MVIEW_EP_CTRL_OUT error:nil]);
        s->ctrl_in = CFBridgingRetain([iface copyPipeWithAddress:MVIEW_EP_CTRL_IN error:nil]);
        s->video0 = CFBridgingRetain([iface copyPipeWithAddress:0x08 error:nil]);
        s->video1 = CFBridgingRetain([iface copyPipeWithAddress:0x0b error:nil]);

        CFTypeRef pipeRefs[] = {s->ctrl_out, s->ctrl_in, s->video0, s->video1};
        for (size_t i = 0; i < sizeof(pipeRefs) / sizeof(pipeRefs[0]); i++) {
            CFTypeRef pipeRef = pipeRefs[i];
            if (!pipeRef) {
                continue;
            }
            NSError *clearError = nil;
            IOUSBHostPipe *pipe = (__bridge IOUSBHostPipe *)pipeRef;
            if (![pipe clearStallWithError:&clearError]) {
                mview_log("clear stall ep 0x%02lx failed: %s", (unsigned long)pipe.endpointAddress,
                          clearError.localizedDescription.UTF8String ?: "?");
            }
        }

        if (dfu) {
            s->iface1 = CFBridgingRetain(dfu);
        }

        /* Type-0x40 is readable before the start-app request changes the device's control state.
         * Preserve that measured identity so verification can still name the claimed hardware
         * after the encrypted/video session is live. */
        if (identityCacheLength > 0) {
            memcpy(s->identity, identityCache, (size_t)identityCacheLength);
            s->identity_len = identityCacheLength;
        }

        NSMutableArray *bufs = [NSMutableArray arrayWithCapacity:IN_DEPTH];
        for (int i = 0; i < IN_DEPTH; i++) {
            NSMutableData *buf = [NSMutableData dataWithLength:IN_BUF];
            [bufs addObject:buf];
            arm_in(s, buf);
        }
        s->inbufs = CFBridgingRetain(bufs);
        mview_log("session open pipes out=%p in=%p v0=%p v1=%p dfu=%p", s->ctrl_out, s->ctrl_in,
                  s->video0, s->video1, s->iface1);
        return s;
    }
}

int mview_session_bulk_out(MViewSession *s, uint8_t ep, const void *data, size_t len) {
    if (!s || !data || len > INT_MAX) {
        return -1;
    }
    @autoreleasepool {
        IOUSBHostPipe *p = pipe_for_ep(s, ep);
        if (!p) {
            mview_log("no pipe for ep 0x%02x", ep);
            return -1;
        }
        NSMutableData *buf = [NSMutableData dataWithBytes:data length:len];
        NSUInteger xfer = 0;
        NSError *err = nil;
        BOOL ok = [p sendIORequestWithData:buf
                          bytesTransferred:&xfer
                         completionTimeout:2.0
                                     error:&err];
        if (!ok || xfer != len) {
            mview_log("bulk OUT 0x%02x %zu failed (%ld, transferred %lu): %s", ep, len,
                      (long)err.code, (unsigned long)xfer,
                      err.localizedDescription.UTF8String ?: "short transfer");
            return -1;
        }
        return (int)xfer;
    }
}

/*
 * Submit each encoded frame in one IOUSBHost request, including packet-aligned
 * lengths. Do not split it or append a separate zero-length request: on the local
 * Ridge dock the latter was followed by endpoint resets during motion. The USB
 * stack owns packetization; an extra request is not part of the encoded frame.
 */
int mview_session_bulk_out_frame(MViewSession *s, uint8_t ep, const void *data, size_t len) {
    if (len == 0) return -1;
    return mview_session_bulk_out(s, ep, data, len);
}

int mview_session_bulk_outv(MViewSession *s, uint8_t ep, const MViewUSBChunk *chunks,
                            int chunk_count) {
    if (!s || !chunks || chunk_count <= 0) {
        return -1;
    }
    @autoreleasepool {
        IOUSBHostPipe *pipe = pipe_for_ep(s, ep);
        if (!pipe) {
            mview_log("no pipe for ep 0x%02x", ep);
            return -1;
        }
        dispatch_group_t pending = dispatch_group_create();
        NSMutableArray<NSMutableData *> *buffers =
            [NSMutableArray arrayWithCapacity:(NSUInteger)chunk_count];
        __block int failed = 0;
        __block size_t transferred = 0;
        for (int i = 0; i < chunk_count; i++) {
            if (!chunks[i].bytes || chunks[i].length == 0) {
                failed = 1;
                continue;
            }
            NSMutableData *buffer =
                [NSMutableData dataWithBytes:chunks[i].bytes length:chunks[i].length];
            [buffers addObject:buffer];
            dispatch_group_enter(pending);
            NSError *error = nil;
            BOOL queued = [pipe enqueueIORequestWithData:buffer
                                       completionTimeout:2.0
                                                   error:&error
                                       completionHandler:^(IOReturn status,
                                                           NSUInteger bytesTransferred) {
                                           if (status != kIOReturnSuccess ||
                                               bytesTransferred != buffer.length) {
                                               failed = 1;
                                               mview_log("async bulk OUT 0x%02x failed status=%08x "
                                                         "%lu/%lu",
                                                         ep, status,
                                                         (unsigned long)bytesTransferred,
                                                         (unsigned long)buffer.length);
                                           } else {
                                               transferred += bytesTransferred;
                                           }
                                           dispatch_group_leave(pending);
                                       }];
            if (!queued) {
                failed = 1;
                mview_log("async bulk OUT 0x%02x enqueue failed: %s", ep,
                          error.localizedDescription.UTF8String ?: "?");
                dispatch_group_leave(pending);
                break;
            }
        }
        dispatch_group_wait(pending, DISPATCH_TIME_FOREVER);
        return failed ? -1 : (int)transferred;
    }
}

int mview_session_recv(MViewSession *s, void *data, size_t cap, size_t *got, double timeout_s) {
    if (got) {
        *got = 0;
    }
    if (!s || !data) {
        return -1;
    }
    pthread_mutex_lock(&s->mu);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += (time_t)timeout_s;
    ts.tv_nsec += (long)((timeout_s - (time_t)timeout_s) * 1e9);
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    while (s->inbox_n == 0 && !atomic_load(&s->closing)) {
        if (pthread_cond_timedwait(&s->cv, &s->mu, &ts) != 0) {
            pthread_mutex_unlock(&s->mu);
            return -1;
        }
    }
    if (s->inbox_n == 0) {
        pthread_mutex_unlock(&s->mu);
        return -1;
    }
    size_t n = s->inbox_len[s->inbox_r];
    if (n > cap) {
        n = cap;
    }
    memcpy(data, s->inbox[s->inbox_r], n);
    s->inbox_r = (s->inbox_r + 1) % INBOX;
    s->inbox_n--;
    pthread_mutex_unlock(&s->mu);
    if (got) {
        *got = n;
    }
    return (int)n;
}

int mview_session_ctrl(MViewSession *s, uint8_t bm, uint8_t req, uint16_t value, uint16_t index,
                       void *data, uint16_t len, double timeout_s) {
    if (!s) {
        return -1;
    }
    @autoreleasepool {
        if (bm == 0x01 && req == 0x0b && index == 1 && s->iface1) {
            NSError *selectError = nil;
            IOUSBHostInterface *target = (__bridge IOUSBHostInterface *)s->iface1;
            if (![target selectAlternateSetting:value error:&selectError]) {
                mview_log("select interface 1 alt %u failed: %s", value,
                          selectError.localizedDescription.UTF8String ?: "?");
                return -1;
            }
            return 0;
        }
        IOUSBHostInterface *iface = session_iface(s);
        if ((bm & 0x1f) == 0x01 && index == 1 && s->iface1) {
            iface = (__bridge IOUSBHostInterface *)s->iface1;
        }
        if (!iface) {
            return -1;
        }
        IOUSBDeviceRequest r;
        r.bmRequestType = bm;
        r.bRequest = req;
        r.wValue = value;
        r.wIndex = index;
        r.wLength = len;
        NSMutableData *buf = nil;
        if (len && data) {
            if (bm & 0x80) {
                buf = [NSMutableData dataWithLength:len];
            } else {
                buf = [NSMutableData dataWithBytes:data length:len];
            }
        }
        NSUInteger xfer = 0;
        NSError *err = nil;
        BOOL ok = [iface sendDeviceRequest:r
                                      data:buf
                          bytesTransferred:&xfer
                         completionTimeout:timeout_s
                                     error:&err];
        if (!ok) {
            mview_log("ctrl bm=%02x req=%02x val=%04x idx=%04x failed: %s", bm, req, value, index,
                      err.localizedDescription.UTF8String ?: "?");
            return -1;
        }
        if ((bm & 0x80) && data && buf) {
            memcpy(data, buf.bytes, xfer);
        }
        return (int)xfer;
    }
}

int mview_session_get_identity(MViewSession *s, uint8_t *buf, int cap) {
    if (!s || !buf || cap < 16) {
        return -1;
    }
    if (s->identity_len > 0) {
        int n = s->identity_len < cap ? s->identity_len : cap;
        memcpy(buf, s->identity, (size_t)n);
        return n;
    }
    uint8_t header[9];
    int got = mview_session_ctrl(s, 0x80, 0x06, 0x0200, 0, header, sizeof(header), 1.0);
    if (got != (int)sizeof(header)) {
        return -1;
    }
    size_t total = (size_t)header[2] | ((size_t)header[3] << 8);
    if (total < sizeof(header) || total > 1024) {
        return -1;
    }
    uint8_t configuration[1024];
    got = mview_session_ctrl(s, 0x80, 0x06, 0x0200, 0, configuration, (uint16_t)total, 1.0);
    if (got < (int)total) {
        return -1;
    }
    int identityLength = identity_from_configuration(
        (const IOUSBConfigurationDescriptor *)configuration, s->identity, sizeof(s->identity));
    if (identityLength <= 0) {
        return -1;
    }
    s->identity_len = identityLength;
    int copied = identityLength < cap ? identityLength : cap;
    memcpy(buf, s->identity, (size_t)copied);
    return copied;
}

void mview_session_close(MViewSession *s) {
    if (!s) {
        return;
    }
    pthread_mutex_lock(&s->mu);
    atomic_store(&s->closing, 1);
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
    @autoreleasepool {
        // A callback may have passed its closing check just before the flag changed.
        // Let that callback finish enqueueing before aborting the outstanding reads.
        if (s->queue) dispatch_sync(s->queue, ^{});
        if (s->ctrl_in) {
            NSError *err = nil;
            [pipe_for_ep(s, MVIEW_EP_CTRL_IN) abortWithOption:IOUSBHostAbortOptionSynchronous
                                                       error:&err];
        }
        // Aborted completions still run on the interface queue and read the session.
        // Drain them before releasing buffers or freeing their callback context.
        if (s->queue) dispatch_sync(s->queue, ^{});
        if (s->inbufs) {
            CFRelease(s->inbufs);
            s->inbufs = NULL;
        }
        if (s->iface) {
            [session_iface(s) destroy];
            CFRelease(s->iface);
            s->iface = NULL;
        }
        if (s->iface1) {
            IOUSBHostInterface *d = (__bridge IOUSBHostInterface *)s->iface1;
            [d destroy];
            CFRelease(s->iface1);
            s->iface1 = NULL;
        }
        if (s->device) {
            IOUSBHostDevice *d = (__bridge IOUSBHostDevice *)s->device;
            [d destroy];
            CFRelease(s->device);
            s->device = NULL;
        }
        if (s->ctrl_out) {
            CFRelease(s->ctrl_out);
        }
        if (s->ctrl_in) {
            CFRelease(s->ctrl_in);
        }
        if (s->video0) {
            CFRelease(s->video0);
        }
        if (s->video1) {
            CFRelease(s->video1);
        }
    }
    pthread_mutex_destroy(&s->mu);
    pthread_cond_destroy(&s->cv);
    s->queue = NULL;
    free(s);
}
