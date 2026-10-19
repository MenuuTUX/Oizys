#pragma once

#include "oizys_build.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OIZYS_VID 0x17e9
#define OIZYS_DL3_CLASS 0xff
#define OIZYS_DL3_SUBCLASS 0x00
#define OIZYS_DL3_PROTOCOL 0x03
#define OIZYS_IDENT_TYPE 0x40
#define OIZYS_EP_CTRL_OUT 0x02
#define OIZYS_EP_CTRL_IN 0x84

#define OIZYS_MAX_IFACE 16
#define OIZYS_MAX_EP 8
#define OIZYS_MAX_HUBS 4

typedef enum {
    OIZYS_FAMILY_UNKNOWN = 0,
    OIZYS_FAMILY_RIDGE,
    OIZYS_FAMILY_NAVARRO,
    OIZYS_FAMILY_ELLA,
    OIZYS_FAMILY_FIREFLY
} OizysFamily;

typedef struct {
    uint8_t address;
    uint8_t dir_in; /* 1 = IN */
    uint8_t transfer; /* 0 ctrl, 1 iso, 2 bulk, 3 int */
    uint16_t max_packet;
} OizysEndpoint;

typedef struct {
    uint8_t number, alt, class_code, subclass, protocol;
    int ep_count;
    OizysEndpoint ep[OIZYS_MAX_EP];
} OizysInterface;

typedef struct {
    uint8_t raw[16];
    char platform[9];
    uint8_t firmware[6];
    OizysFamily family;
    int valid;
} OizysIdentity;

typedef struct {
    uint16_t vid, pid;
    uint32_t location_id;
    uint16_t bcd_usb, bcd_device;
    char manufacturer[64];
    char product[64];
    char serial[64];
    char speed[32];
    char exclusive_owner[128];
    OizysIdentity identity;
    int iface_count;
    OizysInterface iface[OIZYS_MAX_IFACE];
} OizysHub;

int oizys_usb_probe(OizysHub *hubs, int max_hubs);
void oizys_hub_print(const OizysHub *hub);
int oizys_hub_is_dl3(const OizysHub *hub);
int oizys_hub_has_control(const OizysHub *hub);
int oizys_hub_video_outs(const OizysHub *hub, uint8_t *out, int max_out);
const char *oizys_family_name(OizysFamily family);
OizysFamily oizys_family_from_platform(const char *name);
int oizys_identity_parse(OizysIdentity *id, const uint8_t *bytes, int n);

/* Exclusive USB session (IOUSBHost). ObjC implementation. */
typedef struct OizysSession OizysSession;

void oizys_log_open(const char *path);
void oizys_log(const char *fmt, ...);

OizysSession *oizys_session_open(int capture);
int oizys_session_bulk_out(OizysSession *s, uint8_t ep, const void *data, size_t len);
/* Send one complete video frame as one IOUSBHost request. Never append a separate
 * zero-length request, including when the frame length is packet-aligned. */
int oizys_session_bulk_out_frame(OizysSession *s, uint8_t ep, const void *data, size_t len);
int oizys_session_recv(OizysSession *s, void *data, size_t cap, size_t *got, double timeout_s);
int oizys_session_ctrl(OizysSession *s, uint8_t bm, uint8_t req, uint16_t value, uint16_t index,
                       void *data, uint16_t len, double timeout_s);
int oizys_session_get_identity(OizysSession *s, uint8_t *buf, int cap);
/* Off (the default), a full control-reply queue fails the session, because authentication
 * and mode setting must not lose a reply. On, once streaming, the oldest unread reply is
 * dropped instead: the control clock drains and discards them, so none is load-bearing. */
void oizys_session_set_lossy(OizysSession *s, int lossy);
void oizys_session_close(OizysSession *s);

int oizys_stop_displaylink(void);
int oizys_start_displaylink(void);

#ifdef __cplusplus
}
#endif

#if !OIZYS_DIAGNOSTICS && !defined(OIZYS_LOG_IMPLEMENTATION)
/* Type-check arguments without evaluating them or emitting production logging. */
#define oizys_log(...) ((void)sizeof((oizys_log(__VA_ARGS__), 0)))
#define oizys_log_open(...) ((void)sizeof((oizys_log_open(__VA_ARGS__), 0)))
#endif
