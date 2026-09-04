#pragma once

#include "oizys_encode.h"
#include "oizys_usb.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OIZYS_DL3_MAX_HEADS 2

typedef struct {
    uint16_t product_id;
    uint8_t head_count;
    uint8_t video_endpoint[OIZYS_DL3_MAX_HEADS];
    uint8_t ddc_selector[OIZYS_DL3_MAX_HEADS];
} OizysDL3Profile;

/* Measured profile for the local Ridge 17e9:6000 dock. */
const OizysDL3Profile *oizys_dl3_profile(uint16_t product_id);

/*
 * Extract and validate EDID from this dock's authenticated 0x114/0x21 reply.
 * Returns 0 and writes one or more complete 128-byte EDID blocks on success.
 */
int oizys_dl3_parse_ridge_edid(const uint8_t *plain, size_t plain_len, uint8_t *edid,
                               size_t edid_cap, size_t *edid_len);

/* Build a 16-byte DL3 bulk header. size field is (16+body_len-4). */
void oizys_dl3_header(uint8_t out[16], uint32_t type, uint16_t sub, uint16_t aux, uint32_t seq,
                      size_t body_len);

size_t oizys_dl3_init_0(uint8_t *out, size_t cap);
size_t oizys_dl3_init_25(uint8_t *out, size_t cap);
size_t oizys_dl3_init_4_probe(uint8_t *out, size_t cap);

/* CTA 1920x1080p60 inner set-mode plaintext (id 0x48 / sub 0x22). */
size_t oizys_dl3_set_mode_1080p60(uint8_t *out, size_t cap, uint16_t counter, uint8_t head);

/* AES-CTR + Dl3Cmac seal of an interactive CP frame (type 4 sub 0x24). */
size_t oizys_dl3_seal_cp(uint8_t *out, size_t cap, const uint8_t ks[16], const uint8_t riv[8],
                         uint16_t inner_id, uint32_t wire_seq, const uint8_t *inner,
                         size_t inner_len);

/* Seal with an already-whitened live key and explicit video/control header fields. */
size_t oizys_dl3_seal_live(uint8_t *out, size_t cap, const uint8_t live_key[16],
                           const uint8_t riv[8], uint16_t wire_sub, uint16_t aux,
                           uint32_t wire_seq, const uint8_t *plain, size_t plain_len);

int oizys_dl3_open_cp(const uint8_t ks[16], const uint8_t in_riv[8], uint32_t seq,
                      const uint8_t *body, size_t body_len, uint8_t *pt, size_t pt_cap);

/* HDCP 2.2 transmitter helpers. */
void oizys_aes_cmac(const uint8_t key[16], const uint8_t *msg, size_t n, uint8_t tag[16]);
void oizys_aes_ctr_xor(const uint8_t key[16], const uint8_t riv[8], uint32_t seq,
                       const uint8_t *in, uint8_t *out, size_t n);
void oizys_hdcp_random(void *buf, size_t n);
void oizys_hdcp_derive_kd(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          uint8_t kd[32]);
void oizys_hdcp_ske_edkey(const uint8_t km[16], const uint8_t rtx[8], const uint8_t rrx[8],
                          const uint8_t rn[8], const uint8_t ks[16], uint8_t edkey[16]);
int oizys_hdcp_rsa_oaep_encrypt(const uint8_t modulus[128], const uint8_t exponent[3],
                                const uint8_t km[16], uint8_t out[128]);

size_t oizys_hdcp_ake_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                           const uint8_t rtx[8]);
size_t oizys_hdcp_ake_txinfo(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);
size_t oizys_hdcp_ake_no_stored_km(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                                   const uint8_t ekpub[128]);
size_t oizys_hdcp_session_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);
size_t oizys_hdcp_lc_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                          const uint8_t rn[8]);
size_t oizys_hdcp_ske_send_eks(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t edkey[16], const uint8_t riv[8]);
void oizys_hmac_sha256(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen,
                       uint8_t out[32]);
void oizys_hdcp_compute_h(const uint8_t kd[32], const uint8_t rtx[8], int repeater, uint8_t h[32]);
void oizys_hdcp_compute_l(const uint8_t kd[32], const uint8_t rrx[8], const uint8_t rn[8],
                          uint8_t l[32]);
void oizys_cp_session_key(const uint8_t raw[16], uint8_t live[16]);

size_t oizys_hdcp_repeater_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t v_lsb[16]);
size_t oizys_hdcp_stream_manage(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq);

typedef struct OizysDriver OizysDriver;

typedef struct {
    uint8_t logical_head;
    uint8_t ddc_selector;
    uint8_t video_endpoint;
    uint8_t present;
    uint8_t authenticated;
    uint8_t edid[512];
    size_t edid_len;
    char manufacturer[4];
} OizysHeadStatus;

typedef struct {
    uint8_t h_prime_verified;
    uint8_t l_prime_verified;
    uint8_t v_prime_verified;
    uint32_t cp_ack_frames;
    uint32_t video_writes[OIZYS_DL3_MAX_HEADS];
} OizysDriverVerification;

/* The caller owns the USB session; destroying a driver does not close it. */
OizysDriver *oizys_driver_engage(OizysSession *session, uint16_t product_id);
int oizys_driver_fetch_edid(OizysDriver *driver, uint8_t head);
int oizys_driver_fetch_edids(OizysDriver *driver);
int oizys_driver_get_head(const OizysDriver *driver, uint8_t head, OizysHeadStatus *status);
int oizys_driver_get_verification(const OizysDriver *driver, OizysDriverVerification *status);
/* Non-zero once this head's mode is activated and its decoder armed. A head left off the
 * dock for this run never arms, and skipping it is not a failure. */
int oizys_driver_head_is_armed(const OizysDriver *driver, uint8_t head);
int oizys_driver_activate_1080p60(OizysDriver *driver, uint8_t head);
int oizys_driver_present_solid(OizysDriver *driver, uint8_t head, uint8_t red, uint8_t green,
                               uint8_t blue);
/* Present a ScreenCaptureKit BGRA surface as Haar/WHT 64x16 colour strips. Unchanged
 * surfaces produce no video write. */
/* As oizys_driver_present_bgra_mosaic, but hands the compositor's changed rectangles to
   the damage ledger so unchanged strips are never re-read. A NULL or empty list means the
   whole surface is fingerprinted. */
int oizys_driver_present_bgra_dirty(OizysDriver *driver, uint8_t head, const uint8_t *bgra,
                                    size_t stride, uint32_t width, uint32_t height,
                                    const OizysDirtyRect *rects, int rect_count);
int oizys_driver_present_bgra_mosaic(OizysDriver *driver, uint8_t head, const uint8_t *bgra,
                                     size_t stride, uint32_t width, uint32_t height);
/* Pay off any outstanding strip retransmissions from the cached strip bodies.
 * ScreenCaptureKit goes silent on a static desktop, so nothing else would carry the
 * repeats a changed strip still owes. Sends nothing when the ledger is clear. */
int oizys_driver_refresh_head(OizysDriver *driver, uint8_t head);

/* Non-zero while this head is blanked by head.<side>.standby_min. The display still exists
 * and the layout is untouched; only its pixels are black. */
int oizys_driver_head_is_blanked(const OizysDriver *driver, uint8_t head);
/* Non-zero while this head's cached strip bodies were encoded at settings that have since
   changed. Nothing in the cache is worth sending until a real frame has been re-encoded, so
   the capture clock answers this with a repaint rather than the usual cached repayment. */
int oizys_driver_head_needs_recode(const OizysDriver *driver, uint8_t head);

/* Seconds since anything on this head last changed, 0 before the first frame. */
int oizys_driver_head_idle_seconds(const OizysDriver *driver, uint8_t head);

/* The capture rate this session should be asking for now: capture.fps normally, and
 * power.idle_fps once every active head has been still for power.idle_after_s. */
int oizys_driver_capture_fps_target(const OizysDriver *driver);
/* Run the control session's own clocks: a 13 ms status poll and a 3 s heartbeat. These
 * are independent of whether any pixels moved. Call it often; it rate-limits itself. */
int oizys_driver_service_control(OizysDriver *driver);

/* Pack a Ridge video frame (row records + trailer) from BGRA. strips==NULL encodes the
 * full 1920x1080 grid. Used by tests and the desktop scanout path. */
size_t oizys_video_encode_bgra_frame(uint8_t *out, size_t cap, uint8_t head, uint32_t sequence,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height, const OizysStrip *strips, int strip_count);
size_t oizys_video_solid_strip(uint8_t *out, size_t cap, uint16_t x, uint16_t y, uint8_t red,
                               uint8_t green, uint8_t blue);
/* Encode one complete Ridge 64x16 colour strip. Fixed-point planes are block-major
 * [16 blocks][Cr,Cb,Y][64 row-major samples]. */
size_t oizys_video_colour_strip_planes(uint8_t *out, size_t cap, uint16_t x, uint16_t y,
                                       const int32_t *planes);
/* Uniform output gain applied while encoding, 256 = unity, clamped to 0..256. Set it per
 * head before that head's strips are encoded. This dims the signal Oizys sends; it is not
 * the monitor's backlight, which a DisplayLink output cannot reach. */
void oizys_video_set_gain(int gain_q8);

/* Contrast about mid-grey applied while encoding, 256 = unity, clamped to 128..384. Unlike
 * gain this runs either side of unity, because a contrast control that can only reduce is
 * half a control; above unity it clips highlights, as raising contrast on a monitor does.
 * Set it per head before that head's strips are encoded. */
void oizys_video_set_contrast(int contrast_q8);
int oizys_video_contrast(void);

/* Per-channel correction as three 256-entry tables, in R, G, B order, applied to pixels
 * before the colour transform. NULL removes it. The caller owns the storage and must keep it
 * alive and unchanged while frames are being encoded. */
void oizys_video_set_channel_lut(const uint8_t (*tables)[256]);
int oizys_video_has_channel_lut(void);
int oizys_video_gain(void);

size_t oizys_video_colour_strip_bgra(uint8_t *out, size_t cap, uint16_t x, uint16_t y,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height);
size_t oizys_video_decoder_config(uint8_t *out, size_t cap, uint16_t width, uint16_t height,
                                  const uint8_t nonce[14]);
uint64_t oizys_video_solid_frame_fingerprint(uint8_t head, uint32_t sequence, uint8_t red,
                                             uint8_t green, uint8_t blue, size_t *frame_len);
void oizys_driver_destroy(OizysDriver *driver);

#ifdef __cplusplus
}
#endif

/* Test seams into the encoder's scalar definitions. The vector path must agree with
 * these exactly; the suite checks that rather than assuming the tables were transcribed
 * correctly. Not part of the driver's runtime interface. */
int32_t oizys_quantize_reference(unsigned plane, unsigned scan, int32_t value);
unsigned oizys_scan_index(unsigned row, unsigned column);
/* Runs the vector quantiser against the scalar one over `rounds` blocks of generated
 * coefficients. Returns the number of disagreements; 0 means the optimisation is exact.
 * `generate` may be NULL for a fixed sweep. */
int oizys_encode_selftest(int32_t (*generate)(void *context, unsigned index), void *context,
                          unsigned rounds);
unsigned oizys_inverse_scan(unsigned scan);
