#include "oizys_usb.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* IOKit's C user-client API owns USB. No Swift, Objective-C, per-frame NSData or
 * second copy of the encoded frame exists at this boundary. */
#define IN_BUF 8192
#define INBOX 32
typedef IOUSBInterfaceInterface550 USBInterface;
typedef IOUSBDeviceInterface650 USBDevice;
struct OizysSession {
    USBDevice **device;
    USBInterface **iface, **iface1;
    uint8_t pipes[256];
    pthread_t reader;
    int reader_started;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    atomic_int closing, failed;
    uint8_t inbox[INBOX][IN_BUF];
    size_t inbox_len[INBOX];
    unsigned inbox_r, inbox_w, inbox_n;
    uint8_t identity[64];
    int identity_len;
};

static int number(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, NULL, 0);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberIntType, &result);
    if (value) CFRelease(value);
    return result;
}

/* Caller preflights topology; recheck here to avoid seizing a different device
 * between enumeration and opening the user client. */
static io_service_t unique_device(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)) return 0;
    io_service_t found = 0, service;
    unsigned count = 0;
    while ((service = IOIteratorNext(iterator))) {
        if (number(service, CFSTR("idVendor")) == OIZYS_VID) {
            count++;
            if (count == 1 && number(service, CFSTR("idProduct")) == 0x6000) { found = service; continue; }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (count != 1 && found) { IOObjectRelease(found); found = 0; }
    return found;
}

static void *user_client(io_service_t service, CFUUIDRef plugin_type, CFUUIDRef interface_type) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    void *result = NULL;
    IOReturn rc = IOCreatePlugInInterfaceForService(service, plugin_type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (!rc && plugin) {
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(interface_type), &result);
        (*plugin)->Release(plugin);
    }
    if (!result) oizys_log("USB user client unavailable: 0x%08x", rc);
    return result;
}

static int identity_from_configuration(const IOUSBConfigurationDescriptor *configuration, uint8_t *out, size_t capacity) {
    if (!configuration || !out || capacity < 16) return 0;
    const uint8_t *bytes = (const uint8_t *)configuration;
    size_t total = bytes[2] | ((size_t)bytes[3] << 8);
    for (size_t offset = 0; offset + 2 <= total;) {
        size_t length = bytes[offset];
        if (length < 2 || length > total - offset) break;
        if (bytes[offset + 1] == OIZYS_IDENT_TYPE && length >= 16) {
            size_t n = length < capacity ? length : capacity;
            memcpy(out, bytes + offset, n); return (int)n;
        }
        offset += length;
    }
    return 0;
}

static USBInterface **open_interface(OizysSession *s, uint8_t desired) {
    IOUSBFindInterfaceRequest request = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                       kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t iterator = 0;
    if ((*s->device)->CreateInterfaceIterator(s->device, &request, &iterator)) return NULL;
    io_service_t service;
    USBInterface **found = NULL;
    while ((service = IOIteratorNext(iterator))) {
        if (number(service, CFSTR("bInterfaceNumber")) == desired)
            found = user_client(service, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID550);
        IOObjectRelease(service);
        if (found) break;
    }
    IOObjectRelease(iterator);
    if (!found) return NULL;
    IOReturn rc = (*found)->USBInterfaceOpenSeize(found);
    if (rc) { oizys_log("open USB interface %u failed: 0x%08x", desired, rc); (*found)->Release(found); return NULL; }
    if ((*found)->SetAlternateInterface(found, 0)) {
        (*found)->USBInterfaceClose(found); (*found)->Release(found); return NULL;
    }
    return found;
}

static void *read_control(void *context) {
    OizysSession *s = context;
    uint8_t bytes[IN_BUF];
    while (!atomic_load(&s->closing)) {
        UInt32 length = sizeof(bytes);
        IOReturn rc = (*s->iface)->ReadPipeTO(s->iface, s->pipes[OIZYS_EP_CTRL_IN], bytes, &length, 250, 250);
        if (atomic_load(&s->closing)) break;
        if (rc == kIOUSBTransactionTimeout || rc == kIOReturnTimeout) continue;
        if (rc || length > sizeof(bytes)) { atomic_store(&s->failed, 1); break; }
        if (!length) continue;
        pthread_mutex_lock(&s->mu);
        if (s->inbox_n == INBOX) {
            atomic_store(&s->failed, 1); /* Never silently lose an authentication/control reply. */
        } else {
            memcpy(s->inbox[s->inbox_w], bytes, length);
            s->inbox_len[s->inbox_w] = length;
            s->inbox_w = (s->inbox_w + 1) % INBOX; s->inbox_n++;
        }
        pthread_cond_signal(&s->cv);
        pthread_mutex_unlock(&s->mu);
        if (atomic_load(&s->failed)) break;
    }
    pthread_mutex_lock(&s->mu); pthread_cond_broadcast(&s->cv); pthread_mutex_unlock(&s->mu);
    return NULL;
}

OizysSession *oizys_session_open(int capture) {
    (void)capture; /* Exclusive open is used for either authorized takeover mode. */
    io_service_t service = unique_device();
    if (!service) return NULL;
    OizysSession *s = calloc(1, sizeof(*s));
    if (!s) { IOObjectRelease(service); return NULL; }
    pthread_mutex_init(&s->mu, NULL); pthread_cond_init(&s->cv, NULL);
    atomic_init(&s->closing, 0); atomic_init(&s->failed, 0);
    s->device = user_client(service, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID650);
    IOObjectRelease(service);
    if (!s->device) goto fail;
    IOReturn rc = (*s->device)->USBDeviceOpenSeize(s->device);
    if (rc) { oizys_log("open USB device failed: 0x%08x", rc); goto fail; }
    IOUSBConfigurationDescriptorPtr configuration = NULL;
    if (!(*s->device)->GetConfigurationDescriptorPtr(s->device, 0, &configuration))
        s->identity_len = identity_from_configuration(configuration, s->identity, sizeof(s->identity));
    if ((*s->device)->SetConfiguration(s->device, 1)) goto fail;
    usleep(100000);
    s->iface1 = open_interface(s, 1);
    s->iface = open_interface(s, 0);
    if (!s->iface || !s->iface1) goto fail;
    UInt8 count = 0;
    if ((*s->iface)->GetNumEndpoints(s->iface, &count)) goto fail;
    for (UInt8 pipe = 1; pipe <= count; pipe++) {
        UInt8 direction, endpoint, transfer, interval;
        UInt16 packet;
        if ((*s->iface)->GetPipeProperties(s->iface, pipe, &direction, &endpoint, &transfer, &packet, &interval)) goto fail;
        if (transfer == kUSBBulk) {
            uint8_t address = endpoint | (direction == kUSBIn ? 0x80 : 0);
            s->pipes[address] = pipe;
            (*s->iface)->ClearPipeStallBothEnds(s->iface, pipe);
        }
    }
    if (!s->pipes[0x02] || !s->pipes[0x84] || !s->pipes[0x08] || !s->pipes[0x0b]) goto fail;
    if (pthread_create(&s->reader, NULL, read_control, s)) goto fail;
    s->reader_started = 1;
    oizys_log("C USB session open: endpoints 02/84/08/0b, identity=%d bytes", s->identity_len);
    return s;
fail:
    oizys_session_close(s);
    return NULL;
}

int oizys_session_bulk_out(OizysSession *s, uint8_t ep, const void *data, size_t length) {
    if (!s || !s->iface || !data || !length || length > INT_MAX || !s->pipes[ep] ||
        atomic_load(&s->closing) || atomic_load(&s->failed)) return -1;
    // A successful WritePipeTO completes the entire supplied length. Underruns/errors
    // are failures. One request even for packet-aligned lengths, no extra ZLP.
    IOReturn rc = (*s->iface)->WritePipeTO(s->iface, s->pipes[ep], (void *)data, (UInt32)length, 2000, 2000);
    if (rc) { oizys_log("bulk OUT 0x%02x %zu failed: 0x%08x", ep, length, rc); return -1; }
    return (int)length;
}
int oizys_session_bulk_out_frame(OizysSession *s, uint8_t ep, const void *data, size_t length) {
    return oizys_session_bulk_out(s, ep, data, length);
}
int oizys_session_bulk_outv(OizysSession *s, uint8_t ep, const OizysUSBChunk *chunks, int count) {
    if (!chunks || count <= 0) return -1;
    size_t total = 0;
    for (int i = 0; i < count; i++) {
        if (chunks[i].length > INT_MAX - total) return -1;
        int written = oizys_session_bulk_out(s, ep, chunks[i].bytes, chunks[i].length);
        if (written < 0) return -1;
        total += (size_t)written;
    }
    return (int)total;
}
int oizys_session_recv(OizysSession *s, void *data, size_t capacity, size_t *got, double timeout) {
    if (got) *got = 0;
    if (!s || !data || !isfinite(timeout) || timeout < 0 || timeout > 60) return -1;
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += (time_t)timeout;
    deadline.tv_nsec += (long)((timeout - (time_t)timeout) * 1e9);
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&s->mu);
    while (!s->inbox_n && !atomic_load(&s->closing) && !atomic_load(&s->failed)) {
        if (pthread_cond_timedwait(&s->cv, &s->mu, &deadline)) break;
    }
    if (!s->inbox_n || s->inbox_len[s->inbox_r] > capacity) { pthread_mutex_unlock(&s->mu); return -1; }
    size_t n = s->inbox_len[s->inbox_r];
    memcpy(data, s->inbox[s->inbox_r], n);
    s->inbox_r = (s->inbox_r + 1) % INBOX; s->inbox_n--;
    pthread_mutex_unlock(&s->mu);
    if (got) *got = n;
    return (int)n;
}
int oizys_session_ctrl(OizysSession *s, uint8_t bm, uint8_t request, uint16_t value, uint16_t index,
                       void *data, uint16_t length, double timeout) {
    if (!s || !s->iface || (length && !data) || !isfinite(timeout) || timeout < 0 || timeout > 60) return -1;
    USBInterface **iface = (bm & 0x1f) == 1 && index == 1 ? s->iface1 : s->iface;
    if (!iface) return -1;
    if (bm == 0x01 && request == 0x0b && index == 1)
        return (*iface)->SetAlternateInterface(iface, (UInt8)value) ? -1 : 0;
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = bm; r.bRequest = request; r.wValue = value; r.wIndex = index;
    r.wLength = length; r.pData = data;
    r.noDataTimeout = r.completionTimeout = (UInt32)(timeout * 1000);
    IOReturn rc = (*iface)->ControlRequestTO(iface, 0, &r);
    if (rc || r.wLenDone > length) { oizys_log("USB control %02x/%02x failed: 0x%08x", bm, request, rc); return -1; }
    return (int)r.wLenDone;
}
int oizys_session_get_identity(OizysSession *s, uint8_t *bytes, int capacity) {
    if (!s || !bytes || capacity < 16 || !s->identity_len) return -1;
    int n = s->identity_len < capacity ? s->identity_len : capacity;
    memcpy(bytes, s->identity, (size_t)n); return n;
}
void oizys_session_close(OizysSession *s) {
    if (!s) return;
    atomic_store(&s->closing, 1);
    if (s->reader_started) {
        (*s->iface)->AbortPipe(s->iface, s->pipes[OIZYS_EP_CTRL_IN]);
        pthread_join(s->reader, NULL); /* reader owns no memory after this barrier */
    }
    USBInterface **interfaces[] = {s->iface, s->iface1};
    for (unsigned i = 0; i < 2; i++) if (interfaces[i]) {
        (*interfaces[i])->USBInterfaceClose(interfaces[i]); (*interfaces[i])->Release(interfaces[i]);
    }
    if (s->device) { (*s->device)->USBDeviceClose(s->device); (*s->device)->Release(s->device); }
    pthread_cond_destroy(&s->cv); pthread_mutex_destroy(&s->mu); free(s);
}
