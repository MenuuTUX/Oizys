#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MVIEW_VID 0x17e9
#define MVIEW_DL3_CLASS 0xff
#define MVIEW_DL3_SUBCLASS 0x00
#define MVIEW_DL3_PROTOCOL 0x03
#define MVIEW_IDENT_TYPE 0x40
#define MVIEW_EP_CTRL_OUT 0x02
#define MVIEW_EP_CTRL_IN 0x84

#define MVIEW_MAX_IFACE 16
#define MVIEW_MAX_EP 8
#define MVIEW_MAX_HUBS 4

typedef enum {
    MVIEW_FAMILY_UNKNOWN = 0,
    MVIEW_FAMILY_RIDGE,
    MVIEW_FAMILY_NAVARRO,
    MVIEW_FAMILY_ELLA,
    MVIEW_FAMILY_FIREFLY
} MViewFamily;

typedef struct {
    uint8_t address;
    uint8_t dir_in; /* 1 = IN */
    uint8_t transfer; /* 0 ctrl, 1 iso, 2 bulk, 3 int */
    uint16_t max_packet;
} MViewEndpoint;

typedef struct {
    uint8_t number, alt, class_code, subclass, protocol;
    int ep_count;
    MViewEndpoint ep[MVIEW_MAX_EP];
} MViewInterface;

typedef struct {
    uint8_t raw[16];
    char platform[9];
    uint8_t firmware[6];
    MViewFamily family;
    int valid;
} MViewIdentity;

typedef struct {
    uint16_t vid, pid;
    uint32_t location_id;
    uint16_t bcd_usb, bcd_device;
    char manufacturer[64];
    char product[64];
    char serial[64];
    char speed[32];
    char exclusive_owner[128];
    MViewIdentity identity;
    int iface_count;
    MViewInterface iface[MVIEW_MAX_IFACE];
} MViewHub;

int mview_usb_probe(MViewHub *hubs, int max_hubs);
void mview_hub_print(const MViewHub *hub);
int mview_hub_is_dl3(const MViewHub *hub);
int mview_hub_has_control(const MViewHub *hub);
int mview_hub_video_outs(const MViewHub *hub, uint8_t *out, int max_out);
const char *mview_family_name(MViewFamily family);
MViewFamily mview_family_from_platform(const char *name);
int mview_identity_parse(MViewIdentity *id, const uint8_t *bytes, int n);

/* Exclusive USB session (IOUSBHost). ObjC implementation. */
typedef struct MViewSession MViewSession;

typedef struct {
    const void *bytes;
    size_t length;
} MViewUSBChunk;

#define MVIEW_VIDEO_USB_TRANSFER 65536

/* Split a video payload into bulk-OUT transfers of transfer_size bytes.
 * If chunks is NULL, returns the number of slots required.
 * Otherwise fills up to max_chunks and returns the count, or -1 if the
 * payload does not fit. */
int mview_video_plan_usb_chunks(const void *bytes, size_t length, size_t transfer_size,
                                MViewUSBChunk *chunks, int max_chunks);

void mview_log_open(const char *path);
void mview_log(const char *fmt, ...);

MViewSession *mview_session_open(int capture);
/* Bulk max packet size on this dock's video and control endpoints. */
#define MVIEW_BULK_MAX_PACKET 1024

int mview_session_bulk_out(MViewSession *s, uint8_t ep, const void *data, size_t len);
/* Send one complete video frame as a single transfer, with a trailing zero-length
 * packet when the length is an exact multiple of MVIEW_BULK_MAX_PACKET. */
int mview_session_bulk_out_frame(MViewSession *s, uint8_t ep, const void *data, size_t len);
int mview_session_bulk_outv(MViewSession *s, uint8_t ep, const MViewUSBChunk *chunks,
                            int chunk_count);
int mview_session_recv(MViewSession *s, void *data, size_t cap, size_t *got, double timeout_s);
int mview_session_ctrl(MViewSession *s, uint8_t bm, uint8_t req, uint16_t value, uint16_t index,
                       void *data, uint16_t len, double timeout_s);
int mview_session_get_identity(MViewSession *s, uint8_t *buf, int cap);
void mview_session_close(MViewSession *s);

int mview_stop_displaylink(void);
int mview_start_displaylink(void);

#ifdef __cplusplus
}
#endif
