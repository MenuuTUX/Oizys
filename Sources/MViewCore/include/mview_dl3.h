#pragma once

#include "mview_encode.h"
#include "mview_usb.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MVIEW_DL3_MAX_HEADS 2

typedef struct {
    uint16_t product_id;
    uint8_t head_count;
    uint8_t video_endpoint[MVIEW_DL3_MAX_HEADS];
    uint8_t ddc_selector[MVIEW_DL3_MAX_HEADS];
} MViewDL3Profile;

/* Measured profile for the local Ridge 17e9:6000 dock. */
const MViewDL3Profile *mview_dl3_profile(uint16_t product_id);

/*
 * Extract and validate EDID from this dock's authenticated 0x114/0x21 reply.
 * Returns 0 and writes one or more complete 128-byte EDID blocks on success.
 */
int mview_dl3_parse_ridge_edid(const uint8_t *plain, size_t plain_len, uint8_t *edid,
                               size_t edid_cap, size_t *edid_len);

/* Build a 16-byte DL3 bulk header. size field is (16+body_len-4). */
void mview_dl3_header(uint8_t out[16], uint32_t type, uint16_t sub, uint16_t aux, uint32_t seq,
                      size_t body_len);

size_t mview_dl3_init_0(uint8_t *out, size_t cap);
size_t mview_dl3_init_25(uint8_t *out, size_t cap);
size_t mview_dl3_init_4_probe(uint8_t *out, size_t cap);

/* CTA 1920x1080p60 inner set-mode plaintext (id 0x48 / sub 0x22). */
size_t mview_dl3_set_mode_1080p60(uint8_t *out, size_t cap, uint16_t counter, uint8_t head);

/* AES-CTR + Dl3Cmac seal of an interactive CP frame (type 4 sub 0x24). */
size_t mview_dl3_seal_cp(uint8_t *out, size_t cap, const uint8_t ks[16], const uint8_t riv[8],
                         uint16_t inner_id, uint32_t wire_seq, const uint8_t *inner,
                         size_t inner_len);

/* Seal with an already-whitened live key and explicit video/control header fields. */
size_t mview_dl3_seal_live(uint8_t *out, size_t cap, const uint8_t live_key[16],
                           const uint8_t riv[8], uint16_t wire_sub, uint16_t aux,
                           uint32_t wire_seq, const uint8_t *plain, size_t plain_len);

int mview_dl3_open_cp(const uint8_t ks[16], const uint8_t in_riv[8], uint32_t seq,
                      const uint8_t *body, size_t body_len, uint8_t *pt, size_t pt_cap);

/* HDCP 2.2 transmitter helpers. */
void mview_aes_cmac(const uint8_t key[16], const uint8_t *msg, size_t n, uint8_t tag[16]);
void mview_aes_ctr_xor(const uint8_t key[16], const uint8_t riv[8], uint32_t seq,
                       const uint8_t *in, uint8_t *out, size_t n);
void mview_hdcp_random(void *buf, size_t n);
void mview_hdcp_derive_kd(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          uint8_t kd[32]);
void mview_hdcp_ske_edkey(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          const uint8_t rn[8], const uint8_t ks[16], uint8_t edkey[16]);
int mview_hdcp_rsa_oaep_encrypt(const uint8_t modulus[128], const uint8_t exponent[3],
                                const uint8_t km[16], uint8_t out[128]);

size_t mview_hdcp_ake_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                           const uint8_t rtx[8]);
size_t mview_hdcp_ake_txinfo(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);
size_t mview_hdcp_ake_no_stored_km(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                                   const uint8_t ekpub[128]);
size_t mview_hdcp_session_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);
size_t mview_hdcp_lc_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                          const uint8_t rn[8]);
size_t mview_hdcp_ske_send_eks(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t edkey[16], const uint8_t riv[8]);
void mview_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen,
                       uint8_t out[32]);
void mview_hdcp_compute_h(const uint8_t kd[32], const uint8_t rtx[8], int repeater, uint8_t h[32]);
void mview_hdcp_compute_l(const uint8_t kd[32], const uint8_t rrx[8], const uint8_t rn[8],
                          uint8_t l[32]);
void mview_cp_session_key(const uint8_t raw[16], uint8_t live[16]);

size_t mview_hdcp_repeater_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t v_lsb[16]);
size_t mview_hdcp_stream_manage(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);

typedef struct MViewDriver MViewDriver;

typedef struct {
    uint8_t logical_head;
    uint8_t ddc_selector;
    uint8_t video_endpoint;
    uint8_t present;
    uint8_t authenticated;
    uint8_t edid[512];
    size_t edid_len;
    char manufacturer[4];
} MViewHeadStatus;

typedef struct {
    uint8_t h_prime_verified;
    uint8_t l_prime_verified;
    uint8_t v_prime_verified;
    uint32_t cp_ack_frames;
    uint32_t video_writes[MVIEW_DL3_MAX_HEADS];
} MViewDriverVerification;

/* The caller owns the USB session; destroying a driver does not close it. */
MViewDriver *mview_driver_engage(MViewSession *session, uint16_t product_id);
int mview_driver_fetch_edid(MViewDriver *driver, uint8_t head);
int mview_driver_fetch_edids(MViewDriver *driver);
int mview_driver_get_head(const MViewDriver *driver, uint8_t head, MViewHeadStatus *status);
int mview_driver_get_verification(const MViewDriver *driver, MViewDriverVerification *status);
int mview_driver_activate_1080p60(MViewDriver *driver, uint8_t head);
int mview_driver_present_solid(MViewDriver *driver, uint8_t head, uint8_t red, uint8_t green,
                               uint8_t blue);
/* Present a ScreenCaptureKit BGRA surface as Haar/WHT 64x16 colour strips. Unchanged
 * surfaces produce no video write. */
int mview_driver_present_bgra_mosaic(MViewDriver *driver, uint8_t head, const uint8_t *bgra,
                                     size_t stride, uint32_t width, uint32_t height);
/* Pay off any outstanding strip retransmissions from the cached strip bodies.
 * ScreenCaptureKit goes silent on a static desktop, so nothing else would carry the
 * repeats a changed strip still owes. Sends nothing when the ledger is clear. */
int mview_driver_refresh_head(MViewDriver *driver, uint8_t head);
/* Run the control session's own clocks: a 13 ms status poll and a 3 s heartbeat. These
 * are independent of whether any pixels moved. Call it often; it rate-limits itself. */
int mview_driver_service_control(MViewDriver *driver);

/* Pack a Ridge video frame (row records + trailer) from BGRA. strips==NULL encodes the
 * full 1920x1080 grid. Used by tests and the desktop scanout path. */
size_t mview_video_encode_bgra_frame(uint8_t *out, size_t cap, uint8_t head, uint32_t sequence,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height, const MViewStrip *strips, int strip_count);
size_t mview_video_solid_strip(uint8_t *out, size_t cap, uint16_t x, uint16_t y, uint8_t red,
                               uint8_t green, uint8_t blue);
/* Encode one complete Ridge 64x16 colour strip. Fixed-point planes are block-major
 * [16 blocks][Cr,Cb,Y][64 row-major samples]. */
size_t mview_video_colour_strip_planes(uint8_t *out, size_t cap, uint16_t x, uint16_t y,
                                       const int32_t *planes);
size_t mview_video_colour_strip_bgra(uint8_t *out, size_t cap, uint16_t x, uint16_t y,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height);
size_t mview_video_decoder_config(uint8_t *out, size_t cap, uint16_t width, uint16_t height,
                                  const uint8_t nonce[14]);
uint64_t mview_video_solid_frame_fingerprint(uint8_t head, uint32_t sequence, uint8_t red,
                                             uint8_t green, uint8_t blue, size_t *frame_len);
void mview_driver_destroy(MViewDriver *driver);

#ifdef __cplusplus
}
#endif

/* Test seams into the encoder's scalar definitions. The vector path must agree with
 * these exactly; the suite checks that rather than assuming the tables were transcribed
 * correctly. Not part of the driver's runtime interface. */
int32_t mview_quantize_reference(unsigned plane, unsigned scan, int32_t value);
unsigned mview_scan_index(unsigned row, unsigned column);
/* Runs the vector quantiser against the scalar one over `rounds` blocks of generated
 * coefficients. Returns the number of disagreements; 0 means the optimisation is exact.
 * `generate` may be NULL for a fixed sweep. */
int mview_encode_selftest(int32_t (*generate)(void *context, unsigned index), void *context,
                          unsigned rounds);
unsigned mview_inverse_scan(unsigned scan);
