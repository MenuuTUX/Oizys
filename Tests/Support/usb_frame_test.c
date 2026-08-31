#include "../../Sources/OizysCore/usb_session.c"
static int writes;
static IOReturn status;
static IOReturn write_frame(void *self, UInt8 pipe, void *data, UInt32 size, UInt32 idle, UInt32 timeout) {
    writes++;
    return status;
}
int test_usb_frames(void) {
    USBInterface interface = {0}; interface.WritePipeTO = write_frame;
    USBInterface *vtable = &interface;
    OizysSession s = {0}; s.iface = &vtable; s.pipes[0x08] = 1;
    uint8_t *bytes = calloc(1, 196608);
    if (!bytes) return 64;
    size_t sizes[] = {1040, 2048, 65536, 196608};
    int failure = 0;
    for (unsigned i = 0; i < 4; i++) {
        int before = writes;
        if (oizys_session_bulk_out_frame(&s, 8, bytes, sizes[i]) != (int)sizes[i] || writes != before + 1) failure |= 1;
    }
    status = kIOReturnUnderrun;
    if (oizys_session_bulk_out_frame(&s, 8, bytes, 2048) != -1) failure |= 2;
    status = kIOReturnNotResponding;
    if (oizys_session_bulk_out_frame(&s, 8, bytes, 2048) != -1) failure |= 4;
    int before = writes;
    if (oizys_session_bulk_out_frame(&s, 8, bytes, 0) != -1 ||
        oizys_session_bulk_out_frame(&s, 8, bytes, (size_t)INT_MAX + 1) != -1 ||
        oizys_session_bulk_out_frame(&s, 8, NULL, 32) != -1 || writes != before) failure |= 8;
    status = 0;
    atomic_store(&s.closing, 1);
    if (oizys_session_bulk_out_frame(&s, 8, bytes, 32) != -1) failure |= 16;
    free(bytes);
    return failure;
}
