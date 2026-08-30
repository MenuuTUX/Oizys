#include <initializer_list>
// Mock only the IOUSBHost pipe; exercise the shipping frame transfer code.
#include "../../Sources/MViewCore/usb_session.mm"

@interface MViewTestUSBPipe : NSObject
@property(nonatomic) int synchronous;
@property(nonatomic) int enqueued;
@property(nonatomic) BOOL shortTransfer;
@property(nonatomic) BOOL failTransfer;
@end

@implementation MViewTestUSBPipe
- (BOOL)sendIORequestWithData:(NSMutableData *)data bytesTransferred:(NSUInteger *)count
           completionTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    self.synchronous++;
    *count = self.shortTransfer ? data.length - 1 : data.length;
    return !self.failTransfer;
}
- (BOOL)enqueueIORequestWithData:(NSMutableData *)data completionTimeout:(NSTimeInterval)timeout
                          error:(NSError **)error completionHandler:(IOUSBHostCompletionHandler)done {
    self.enqueued++;
    done(kIOReturnSuccess, data ? (self.shortTransfer ? data.length - 1 : data.length) : 0);
    return YES;
}
@end

extern "C" int test_usb_frames(void) {
    @autoreleasepool {
        MViewSession session = {};
        MViewTestUSBPipe *pipe = [MViewTestUSBPipe new];
        session.video0 = CFBridgingRetain(pipe);
        uint8_t bytes[2048] = {};
        int failure = 0;
        // Packet multiples and large frames must stay single requests, without ZLPs.
        for (size_t size : {size_t(1040), size_t(2048), size_t(65536), size_t(196608)}) {
            NSMutableData *frame = [NSMutableData dataWithLength:size];
            int before = pipe.synchronous;
            if (mview_session_bulk_out_frame(&session, 0x08, frame.bytes, size) != (int)size ||
                pipe.synchronous != before + 1 || pipe.enqueued != 0) failure |= 1;
        }
        pipe.shortTransfer = YES;
        if (mview_session_bulk_out_frame(&session, 0x08, bytes, 1040) != -1) failure |= 2;
        if (mview_session_bulk_out_frame(&session, 0x08, bytes, 2048) != -1) failure |= 4;
        pipe.shortTransfer = NO;
        pipe.failTransfer = YES;
        if (mview_session_bulk_out_frame(&session, 0x08, bytes, 2048) != -1) failure |= 8;
        int before = pipe.synchronous;
        if (mview_session_bulk_out_frame(&session, 0x08, bytes, 0) != -1 ||
            mview_session_bulk_out_frame(&session, 0x08, bytes, (size_t)INT_MAX + 1) != -1 ||
            mview_session_bulk_out_frame(&session, 0x08, NULL, 32) != -1 ||
            pipe.synchronous != before) failure |= 16;
        CFRelease(session.video0);
        return failure;
    }
}
