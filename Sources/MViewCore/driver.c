#include "mview_config.h"
#include "mview_dl3.h"
#include "mview_encode.h"
#include "mview_profile.h"

#include <dispatch/dispatch.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define REPLY_CAP 16384
#define RECEIVER_LIST_CAP 2048
/* Complete record strides are limited to 4080 bytes; the buffer is larger so a single
 * strip that overruns that still has somewhere to land. */
#define MVIEW_RECORD_STRIDE_CAP 0x0ff0
#define MVIEW_RECORD_CAP 8192
#define MVIEW_STRIP_CAP 8192
#define RIDGE_STRIP_COLUMNS 30
#define RIDGE_STRIP_ROWS 68
#define RIDGE_STRIP_COUNT (RIDGE_STRIP_COLUMNS * RIDGE_STRIP_ROWS)

struct MViewDriver {
    MViewSession *session;
    const MViewDL3Profile *profile;
    uint8_t control_key[16]; /* raw SKE key; dl3 seal/open apply CP whitening */
    uint8_t control_nonce[8];
    uint8_t modulus[128];
    uint8_t exponent[3];
    uint8_t receiver_list[RECEIVER_LIST_CAP];
    size_t receiver_list_len;
    uint32_t wire_seq;
    uint16_t inner_counter;
    MViewHeadStatus head[MVIEW_DL3_MAX_HEADS];
    uint8_t video_key[MVIEW_DL3_MAX_HEADS][16];
    uint8_t video_nonce[MVIEW_DL3_MAX_HEADS][8];
    uint32_t frame_seq[MVIEW_DL3_MAX_HEADS];
    uint64_t next_keepalive;
    uint64_t next_heartbeat;
    uint8_t active[MVIEW_DL3_MAX_HEADS];
    MViewDriverVerification verification;
    MViewDamageMap damage[MVIEW_DL3_MAX_HEADS];
    /* Last encoded body of every strip, and the content hash it was encoded from. A
     * strip owing a retransmission is re-sent from here, so paying that debt needs no
     * surface and no second pass over the codec. */
    uint8_t *strip_body[MVIEW_DL3_MAX_HEADS][MVIEW_MAX_STRIPS];
    uint16_t strip_body_len[MVIEW_DL3_MAX_HEADS][MVIEW_MAX_STRIPS];
    uint16_t strip_body_capacity[MVIEW_DL3_MAX_HEADS][MVIEW_MAX_STRIPS];
    uint64_t strip_body_hash[MVIEW_DL3_MAX_HEADS][MVIEW_MAX_STRIPS];
    struct {
        uint32_t sequence;
        size_t length;
    } recent_video[MVIEW_DL3_MAX_HEADS][8];
    unsigned recent_next[MVIEW_DL3_MAX_HEADS];
};

static uint16_t read_u16(const uint8_t *p) {
    uint16_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint32_t read_u32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void put_u16(uint8_t *p, uint16_t value) { memcpy(p, &value, sizeof(value)); }
static void put_u32(uint8_t *p, uint32_t value) { memcpy(p, &value, sizeof(value)); }

static int write_control(MViewSession *session, const uint8_t *packet, size_t length,
                         const char *name) {
    int rc = mview_session_bulk_out(session, MVIEW_EP_CTRL_OUT, packet, length);
    if (name) {
        mview_log("%s: %s (%zu bytes)", name, rc < 0 ? "write failed" : "sent", length);
    }
    return rc < 0 ? -1 : 0;
}

static int receive_hdcp(MViewSession *session, uint8_t *message_id, uint8_t *payload,
                        size_t payload_cap, size_t *payload_len) {
    uint8_t frame[REPLY_CAP];
    *payload_len = 0;
    for (int attempt = 0; attempt < 24; attempt++) {
        size_t length = 0;
        if (mview_session_recv(session, frame, sizeof(frame), &length, 1.0) < 0 || length < 26) {
            continue;
        }
        if (read_u16(frame + 8) != 0x25) {
            continue;
        }
        const uint8_t *body = frame + 16;
        size_t body_len = length - 16;
        uint8_t id = body[9];
        if (id == 0) {
            continue;
        }
        size_t n = body_len - 10;
        if (n > payload_cap) {
            n = payload_cap;
        }
        memcpy(payload, body + 10, n);
        *message_id = id;
        *payload_len = n;
        mview_log("HDCP reply id=0x%02x payload=%zu", id, n);
        return 0;
    }
    return -1;
}

static void drain_plain(MViewSession *session, int limit, double timeout) {
    uint8_t frame[REPLY_CAP];
    for (int i = 0; i < limit; i++) {
        size_t length = 0;
        if (mview_session_recv(session, frame, sizeof(frame), &length, timeout) < 0) {
            break;
        }
    }
}

static int open_reply(MViewDriver *driver, const uint8_t *wire, size_t wire_len,
                      uint8_t *plain, size_t plain_cap) {
    if (wire_len <= 16) {
        return -1;
    }
    uint16_t wire_sub = read_u16(wire + 8);
    if (wire_sub == 0x25) {
        size_t n = wire_len - 16;
        if (n > plain_cap) {
            return -1;
        }
        memcpy(plain, wire + 16, n);
        return (int)n;
    }
    if (wire_sub != 0x45) {
        return -1;
    }
    uint8_t candidates[4][8];
    memcpy(candidates[0], driver->control_nonce, 8);
    candidates[0][7] ^= 0x01;
    memcpy(candidates[1], candidates[0], 8);
    candidates[1][0] ^= 0x80;
    memcpy(candidates[2], driver->control_nonce, 8);
    memcpy(candidates[3], candidates[2], 8);
    candidates[3][0] ^= 0x80;
    uint32_t seq = read_u32(wire + 12);
    for (int i = 0; i < 4; i++) {
        int n = mview_dl3_open_cp(driver->control_key, candidates[i], seq, wire + 16,
                                  wire_len - 16, plain, plain_cap);
        if (n >= 8) {
            driver->verification.cp_ack_frames++;
            return n;
        }
    }
    return -1;
}

static void drain_control_quiet(MViewDriver *driver, int limit, double timeout) {
    uint8_t wire[REPLY_CAP];
    for (int i = 0; i < limit; i++) {
        size_t wire_len = 0;
        if (mview_session_recv(driver->session, wire, sizeof(wire), &wire_len, timeout) < 0) {
            break;
        }
    }
}

static void drain_control_debug(MViewDriver *driver, int limit, double timeout) {
    uint8_t wire[REPLY_CAP], plain[REPLY_CAP];
    for (int i = 0; i < limit; i++) {
        size_t wire_len = 0;
        if (mview_session_recv(driver->session, wire, sizeof(wire), &wire_len, timeout) < 0) {
            break;
        }
        int plain_len = open_reply(driver, wire, wire_len, plain, sizeof(plain));
        if (plain_len < 8) {
            mview_log("control reply wire-sub=0x%04x len=%zu (not decoded)",
                      wire_len >= 10 ? read_u16(wire + 8) : 0xffff, wire_len);
            continue;
        }
        uint16_t id = read_u16(plain), sub = read_u16(plain + 2), counter = read_u16(plain + 4);
        mview_log("control reply id=0x%04x sub=0x%04x counter=%u len=%d", id, sub, counter,
                  plain_len);
        if (sub == 0x84 && plain_len >= 10) {
            char payload[160] = {0};
            size_t shown = (size_t)(plain_len - 10);
            if (shown > 32) shown = 32;
            size_t at = 0;
            for (size_t j = 0; j < shown && at + 3 < sizeof(payload); j++) {
                at += (size_t)snprintf(payload + at, sizeof(payload) - at, "%02x ",
                                       plain[10 + j]);
            }
            mview_log("downstream HDCP push msg=0x%02x payload=%s", plain[9], payload);
        }
        if (sub == 0x0c && plain_len > 8) {
            char trace[256];
            size_t n = 0;
            for (int j = 8; j < plain_len && n + 1 < sizeof(trace); j++) {
                if (plain[j] >= 0x20 && plain[j] < 0x7f) {
                    trace[n++] = (char)plain[j];
                }
            }
            trace[n] = 0;
            if (n >= 4) {
                mview_log("dock trace: %s", trace);
            }
        }
    }
}

static int run_shared_ake(MViewDriver *driver) {
    MViewSession *session = driver->session;
    uint8_t scratch[2048];
    (void)mview_session_ctrl(session, 0xc1, 0xfe, 0, 1, scratch, 16, 1.0);
    (void)mview_session_ctrl(session, 0xc1, 0xfc, 0, 1, scratch, 3, 1.0);
    (void)mview_session_ctrl(session, 0x01, 0x0b, 0, 1, NULL, 0, 1.0);
    if (mview_session_ctrl(session, 0x40, 0x24, 3, 0, NULL, 0, 1.0) < 0) {
        return -1;
    }
    if (mview_session_ctrl(session, 0xc1, 0x22, 1, 0, scratch, 28, 1.0) < 0) {
        return -1;
    }
    (void)mview_session_ctrl(session, 0x80, 0x06, 0x0200, 0, scratch, 40, 1.0);
    (void)mview_session_ctrl(session, 0x80, 0x06, 0x0200, 0, scratch, 618, 1.0);

    uint8_t packet[512];
    size_t length = mview_dl3_init_0(packet, sizeof(packet));
    if (!length || write_control(session, packet, length, "init 0") < 0) {
        return -1;
    }
    length = mview_dl3_init_25(packet, sizeof(packet));
    if (!length || write_control(session, packet, length, "init 25") < 0) {
        return -1;
    }
    (void)mview_session_ctrl(session, 0x80, 0x06, 0x0300, 0, scratch, 255, 1.0);
    (void)mview_session_ctrl(session, 0x80, 0x06, 0x0303, 0x0409, scratch, 255, 1.0);
    length = mview_dl3_init_4_probe(packet, sizeof(packet));
    if (!length || write_control(session, packet, length, "init probe") < 0) {
        return -1;
    }
    size_t got = 0;
    if (mview_session_recv(session, scratch, sizeof(scratch), &got, 1.0) < 0) {
        mview_log("session init was not acknowledged");
        return -1;
    }

    uint32_t hdcp_seq = 1;
    length = mview_hdcp_session_ack(packet, sizeof(packet), hdcp_seq++, 0);
    if (write_control(session, packet, length, "session capability ack") < 0) {
        return -1;
    }
    drain_plain(session, 8, 0.03);

    uint8_t rtx[8];
    mview_hdcp_random(rtx, sizeof(rtx));
    length = mview_hdcp_ake_init(packet, sizeof(packet), hdcp_seq++, 0, rtx);
    if (write_control(session, packet, length, "shared AKE init") < 0) {
        return -1;
    }

    uint8_t message_id = 0, payload[2048];
    size_t payload_len = 0;
    if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0 ||
        message_id != 0x03 || payload_len < 137) {
        mview_log("invalid shared AKE certificate id=0x%02x len=%zu", message_id, payload_len);
        return -1;
    }
    int repeater = payload[0] != 0;
    memcpy(driver->modulus, payload + 6, 128);
    memcpy(driver->exponent, payload + 134, 3);

    length = mview_hdcp_ake_txinfo(packet, sizeof(packet), hdcp_seq++, 0);
    if (write_control(session, packet, length, "shared transmitter info") < 0) {
        return -1;
    }
    if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0) {
        return -1;
    }

    uint8_t km[16], encrypted_km[128];
    mview_hdcp_random(km, sizeof(km));
    if (mview_hdcp_rsa_oaep_encrypt(driver->modulus, driver->exponent, km, encrypted_km) != 0) {
        return -1;
    }
    length = mview_hdcp_ake_no_stored_km(packet, sizeof(packet), hdcp_seq++, 0, encrypted_km);
    if (write_control(session, packet, length, "shared no-stored-km") < 0) {
        return -1;
    }
    if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0 ||
        message_id != 0x06 || payload_len < 8) {
        mview_log("shared AKE missing Rrx");
        return -1;
    }
    uint8_t rrx[8], kd[32];
    memcpy(rrx, payload, 8);
    mview_hdcp_derive_kd(km, rtx, rrx, kd);
    if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0 ||
        message_id != 0x07 || payload_len < 32) {
        return -1;
    }
    uint8_t expected[32];
    mview_hdcp_compute_h(kd, rtx, repeater, expected);
    if (memcmp(expected, payload, 32) != 0) {
        mview_log("shared H-prime verification failed");
        return -1;
    }
    driver->verification.h_prime_verified = 1;
    mview_log("shared H-prime verified");
    (void)receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len);

    uint8_t rn[8];
    mview_hdcp_random(rn, sizeof(rn));
    length = mview_hdcp_lc_init(packet, sizeof(packet), hdcp_seq++, 0, rn);
    if (write_control(session, packet, length, "shared locality check") < 0) {
        return -1;
    }
    if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0 ||
        message_id != 0x0a || payload_len < 32) {
        return -1;
    }
    mview_hdcp_compute_l(kd, rrx, rn, expected);
    if (memcmp(expected, payload, 32) != 0) {
        mview_log("shared L-prime verification failed");
        return -1;
    }
    driver->verification.l_prime_verified = 1;
    mview_log("shared L-prime verified");

    uint8_t delivered_nonce[8], encrypted_session_key[16];
    mview_hdcp_random(driver->control_key, sizeof(driver->control_key));
    mview_hdcp_random(delivered_nonce, sizeof(delivered_nonce));
    mview_hdcp_ske_edkey(km, rtx, rrx, rn, driver->control_key, encrypted_session_key);
    length = mview_hdcp_ske_send_eks(packet, sizeof(packet), hdcp_seq++, 0,
                                     encrypted_session_key, delivered_nonce);
    if (write_control(session, packet, length, "shared session key") < 0) {
        return -1;
    }

    driver->receiver_list_len = 0;
    if (repeater) {
        if (receive_hdcp(session, &message_id, payload, sizeof(payload), &payload_len) < 0 ||
            message_id != 0x0c || payload_len < 16) {
            return -1;
        }
        size_t list_len = payload_len - 16;
        if (list_len > sizeof(driver->receiver_list)) {
            return -1;
        }
        uint8_t v[32];
        mview_hmac_sha256(kd, sizeof(kd), payload, list_len, v);
        if (memcmp(v, payload + list_len, 16) != 0) {
            mview_log("shared V-prime verification failed");
            return -1;
        }
        driver->verification.v_prime_verified = 1;
        mview_log("shared V-prime verified");
        memcpy(driver->receiver_list, payload, list_len);
        driver->receiver_list_len = list_len;
        length = mview_hdcp_repeater_ack(packet, sizeof(packet), hdcp_seq++, 0, v + 16);
        if (write_control(session, packet, length, "shared repeater ack") < 0) {
            return -1;
        }
        drain_plain(session, 8, 0.03);
        length = mview_hdcp_stream_manage(packet, sizeof(packet), hdcp_seq++, 0);
        if (write_control(session, packet, length, "shared stream manage") < 0) {
            return -1;
        }
        drain_plain(session, 16, 0.03);
    }
    memcpy(driver->control_nonce, delivered_nonce, 8);
    driver->control_nonce[7] ^= 0x04;
    driver->inner_counter = (uint16_t)hdcp_seq;
    driver->wire_seq = 0;
    mview_log("shared authenticated control session established");
    return 0;
}

static int send_inner(MViewDriver *driver, uint16_t id, const uint8_t *plain, size_t plain_len,
                      const char *name) {
    size_t cap = 32 + plain_len;
    uint8_t *wire = malloc(cap);
    if (!wire) {
        return -1;
    }
    size_t length = mview_dl3_seal_cp(wire, cap, driver->control_key, driver->control_nonce, id,
                                      driver->wire_seq, plain, plain_len);
    int rc = length ? write_control(driver->session, wire, length, name) : -1;
    free(wire);
    if (rc == 0) {
        driver->inner_counter++;
        driver->wire_seq += (uint32_t)((plain_len + 15) / 16);
    }
    return rc;
}

static void inner_header(uint8_t *plain, size_t length, uint16_t id, uint16_t sub,
                         uint16_t counter) {
    memset(plain, 0, length);
    put_u16(plain, id);
    put_u16(plain + 2, sub);
    put_u16(plain + 4, counter);
}

static void log_downstream_push(uint8_t expected_head, const uint8_t *plain, int plain_len) {
    if (plain_len < 10 || read_u16(plain + 2) != 0x84) {
        return;
    }
    uint32_t selector = read_u32(plain + 4);
    char payload[160] = {0};
    size_t shown = (size_t)(plain_len - 10);
    if (shown > 32) shown = 32;
    size_t at = 0;
    for (size_t j = 0; j < shown && at + 3 < sizeof(payload); j++) {
        at += (size_t)snprintf(payload + at, sizeof(payload) - at, "%02x ", plain[10 + j]);
    }
    mview_log("head %u downstream push selector=0x%08x msg=0x%02x payload=%s",
              expected_head, selector, plain[9], payload);
}

static int receive_rrx(MViewDriver *driver, uint8_t expected_head, uint8_t rrx[8], int limit,
                       double timeout) {
    uint8_t wire[REPLY_CAP], plain[REPLY_CAP];
    int found = 0;
    for (int i = 0; i < limit; i++) {
        size_t wire_len = 0;
        if (mview_session_recv(driver->session, wire, sizeof(wire), &wire_len, timeout) < 0) {
            break;
        }
        int plain_len = open_reply(driver, wire, wire_len, plain, sizeof(plain));
        log_downstream_push(expected_head, plain, plain_len);
        /* Ridge encodes the one-hot connector selector in inner byte 5. */
        uint32_t expected_selector = 0x100u << expected_head;
        if (plain_len >= 18 && read_u16(plain + 2) == 0x84 && plain[9] == 0x06 &&
            read_u32(plain + 4) == expected_selector) {
            memcpy(rrx, plain + 10, 8);
            found = 1;
        }
    }
    return found ? 0 : -1;
}

static int configure_one_head(MViewDriver *driver, uint8_t head) {
    static const struct {
        uint16_t id, sub;
        size_t length;
    } steps[] = {
        {0x22, 0x10, 48}, {0x1f, 0x10, 48}, {0x9a, 0x10, 160},
        {0x22, 0x10, 48}, {0x32, 0x10, 64}, {0x2a, 0x10, 48},
        {0x26, 0x10, 48}, {0x14, 0x30, 32}, {0x19, 0x31, 32},
    };
    uint8_t rtx[8], km[16], rn[8], raw_video_key[16], delivered_nonce[8];
    uint8_t encrypted_km[128], encrypted_video_key[16], rrx[8], kd[32], v[32];
    int have_rrx = 0;
    mview_hdcp_random(rtx, sizeof(rtx));
    mview_hdcp_random(km, sizeof(km));
    mview_hdcp_random(rn, sizeof(rn));
    mview_hdcp_random(raw_video_key, sizeof(raw_video_key));
    mview_hdcp_random(delivered_nonce, sizeof(delivered_nonce));
    if (mview_hdcp_rsa_oaep_encrypt(driver->modulus, driver->exponent, km, encrypted_km) != 0) {
        return -1;
    }
    mview_cp_session_key(raw_video_key, driver->video_key[head]);
    memcpy(driver->video_nonce[head], delivered_nonce, 8);
    driver->video_nonce[head][7] ^= (uint8_t)(0x08 | head);

    for (size_t index = 0; index < sizeof(steps) / sizeof(steps[0]); index++) {
        if (index >= 3 && !have_rrx) {
            mview_log("head %u did not provide downstream Rrx", head);
            return -1;
        }
        if (index == 3) {
            mview_hdcp_derive_kd(km, rtx, rrx, kd);
            mview_hdcp_ske_edkey(km, rtx, rrx, rn, raw_video_key, encrypted_video_key);
            mview_hmac_sha256(kd, sizeof(kd), driver->receiver_list,
                              driver->receiver_list_len, v);
        }
        uint8_t plain[160];
        inner_header(plain, steps[index].length, steps[index].id, steps[index].sub,
                     driver->inner_counter);
        if (index <= 5) {
            plain[23] = (uint8_t)(head + 1);
            static const uint8_t message_ids[6] = {0x02, 0x13, 0x04, 0x09, 0x0b, 0x0f};
            plain[27] = message_ids[index];
            switch (index) {
            case 0:
                memcpy(plain + 28, rtx, 8);
                mview_hdcp_random(plain + 36, 12);
                break;
            case 1: {
                static const uint8_t tx_info[5] = {0, 6, 2, 0, 2};
                memcpy(plain + 28, tx_info, sizeof(tx_info));
                mview_hdcp_random(plain + 33, 15);
                break;
            }
            case 2:
                memcpy(plain + 28, encrypted_km, 128);
                mview_hdcp_random(plain + 156, 4);
                break;
            case 3:
                memcpy(plain + 28, rn, 8);
                mview_hdcp_random(plain + 36, 12);
                break;
            case 4:
                memcpy(plain + 28, encrypted_video_key, 16);
                memcpy(plain + 44, delivered_nonce, 8);
                mview_hdcp_random(plain + 52, 12);
                break;
            case 5:
                memcpy(plain + 28, v + 16, 16);
                mview_hdcp_random(plain + 44, 4);
                break;
            }
        } else if (index == 6) {
            plain[23] = (uint8_t)(head + 1);
            plain[27] = 0x10;
            put_u32(plain + 32, 1);
            put_u32(plain + 36, (uint32_t)(0x08 | head));
            mview_hdcp_random(plain + 40, 8);
        } else if (index == 7) {
            mview_hdcp_random(plain + 22, 10);
        } else {
            plain[22] = head;
            plain[24] = 0x06;
            plain[25] = (uint8_t)(head * 4);
            plain[26] = 0x04;
            mview_hdcp_random(plain + 27, 5);
        }
        if (send_inner(driver, steps[index].id, plain, steps[index].length,
                       "per-head control") < 0) {
            return -1;
        }
        if (receive_rrx(driver, head, rrx, 16, 0.01) == 0) {
            have_rrx = 1;
        }
        if (index == 2) {
            /* The downstream receiver computes H' asynchronously after No_Stored_km. Keep the
             * protocol's measured 165 ms gate even when Rrx arrived immediately; advancing on
             * Rrx alone races LC, SKE, and the repeater Ack ahead of H'/the receiver list. */
            usleep(165000);
            if (receive_rrx(driver, head, rrx, 16, 0.01) == 0) {
                have_rrx = 1;
            }
        }
    }
    driver->head[head].authenticated = 1;
    mview_log("head %u downstream authentication complete", head);
    return 0;
}

static int configure_control(MViewDriver *driver) {
    static const uint8_t stream_open[64] = {
        0x00, 0x00, 0x1c, 0x00, 0x02, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x1c, 0x00, 0x02, 0x00, 0x00, 0x00, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    if (write_control(driver->session, stream_open, sizeof(stream_open), "stream open") < 0) {
        return -1;
    }
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), 0x14, 0, driver->inner_counter);
    mview_hdcp_random(plain + 22, 10);
    if (send_inner(driver, 0x14, plain, sizeof(plain), "first encrypted control") < 0) {
        return -1;
    }
    drain_plain(driver->session, 8, 0.01);

    static const struct {
        uint16_t id, sub;
        uint8_t prefix[2], prefix_len;
    } setup[] = {
        {0x14, 0x30, {0, 0}, 0},
        {0x15, 0x0b, {1, 0}, 1},
        {0x16, 0x2a, {0, 1}, 2},
        {0x16, 0x2a, {1, 1}, 2},
    };
    for (size_t i = 0; i < sizeof(setup) / sizeof(setup[0]); i++) {
        inner_header(plain, sizeof(plain), setup[i].id, setup[i].sub,
                     driver->inner_counter);
        mview_hdcp_random(plain + 22, 10);
        memcpy(plain + 22, setup[i].prefix, setup[i].prefix_len);
        if (send_inner(driver, setup[i].id, plain, sizeof(plain), "control setup") < 0) {
            return -1;
        }
        drain_plain(driver->session, 2, 0.01);
    }
    for (uint8_t head = 0; head < driver->profile->head_count; head++) {
        if (configure_one_head(driver, head) < 0) {
            return -1;
        }
    }
    static const uint16_t finalize[][2] = {{0x16, 0x4c}, {0x15, 0x4a}, {0x16, 0x4c}};
    for (uint8_t head = 0; head < driver->profile->head_count; head++) {
        for (size_t i = 0; i < sizeof(finalize) / sizeof(finalize[0]); i++) {
            inner_header(plain, sizeof(plain), finalize[i][0], finalize[i][1],
                         driver->inner_counter);
            plain[22] = head;
            if (finalize[i][1] == 0x4c) {
                plain[23] = 1;
                mview_hdcp_random(plain + 24, 8);
            } else {
                mview_hdcp_random(plain + 23, 9);
            }
            if (send_inner(driver, finalize[i][0], plain, sizeof(plain), "head finalize") < 0) {
                return -1;
            }
            drain_plain(driver->session, 2, 0.01);
        }
    }
    if (mview_session_ctrl(driver->session, 0x40, 0x24, 0, 0, NULL, 0, 1.0) < 0 ||
        mview_session_ctrl(driver->session, 0xc1, 0x22, 1, 0, plain, 28, 1.0) < 0) {
        return -1;
    }
    drain_plain(driver->session, 16, 0.01);
    return 0;
}

static int send_edid_message(MViewDriver *driver, uint16_t id, uint16_t sub, uint8_t selector,
                             uint8_t state, const char *name) {
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), id, sub, driver->inner_counter);
    plain[22] = selector;
    if (id == 0x16 && (sub == 0x23 || sub == 0x4b)) {
        plain[23] = state;
        mview_hdcp_random(plain + 24, 8);
    } else {
        mview_hdcp_random(plain + 23, 9);
    }
    return send_inner(driver, id, plain, sizeof(plain), name);
}

static void decode_manufacturer(MViewHeadStatus *head) {
    if (head->edid_len < 10) {
        return;
    }
    uint16_t code = (uint16_t)((head->edid[8] << 8) | head->edid[9]);
    head->manufacturer[0] = (char)('A' - 1 + ((code >> 10) & 0x1f));
    head->manufacturer[1] = (char)('A' - 1 + ((code >> 5) & 0x1f));
    head->manufacturer[2] = (char)('A' - 1 + (code & 0x1f));
    head->manufacturer[3] = 0;
}

static int drain_edid(MViewDriver *driver, MViewHeadStatus *head, int limit, double timeout) {
    uint8_t wire[REPLY_CAP], plain[REPLY_CAP];
    for (int i = 0; i < limit; i++) {
        size_t wire_len = 0;
        if (mview_session_recv(driver->session, wire, sizeof(wire), &wire_len, timeout) < 0) {
            break;
        }
        int plain_len = open_reply(driver, wire, wire_len, plain, sizeof(plain));
        if (plain_len < 8) {
            continue;
        }
        uint16_t id = read_u16(plain), sub = read_u16(plain + 2);
        if (id == 0x44 && sub == 0x20 && plain_len >= 26) {
            uint32_t status = read_u32(plain + 22);
            head->present = (status & 0x1000) != 0;
            mview_log("selector %u status=0x%08x present=%u", head->ddc_selector, status,
                      head->present);
        }
        size_t edid_len = 0;
        if (mview_dl3_parse_ridge_edid(plain, (size_t)plain_len, head->edid,
                                       sizeof(head->edid), &edid_len) == 0) {
            head->edid_len = edid_len;
            decode_manufacturer(head);
            mview_log("selector %u EDID=%zu manufacturer=%s", head->ddc_selector, edid_len,
                      head->manufacturer);
        }
    }
    return head->edid_len ? 0 : -1;
}

static int fetch_one_edid(MViewDriver *driver, MViewHeadStatus *head) {
    /* One presence transaction plus the fetcher's two seek rounds, as on the proven path. */
    for (int i = 0; i < 3; i++) {
        if (send_edid_message(driver, 0x15, 0x20, head->ddc_selector, 0,
                              "EDID presence probe") < 0) {
            return -1;
        }
        (void)drain_edid(driver, head, 64, 0.005);
        usleep(100000);
    }
    if (send_edid_message(driver, 0x16, 0x4b, head->ddc_selector, 1,
                          "EDID reader start") < 0) {
        return -1;
    }
    (void)drain_edid(driver, head, 64, 0.005);
    usleep(100000);
    if (send_edid_message(driver, 0x15, 0x21, head->ddc_selector, 0, "EDID fetch") < 0) {
        return -1;
    }
    for (int i = 0; i < 200 && !head->edid_len; i++) {
        (void)drain_edid(driver, head, 64, 0.005);
        usleep(10000);
    }
    for (int i = 0; i < 2; i++) {
        if (send_edid_message(driver, 0x16, 0x23, head->ddc_selector, head->ddc_selector,
                              "EDID sink engage") < 0) {
            return -1;
        }
        (void)drain_edid(driver, head, 64, 0.005);
        usleep(100000);
    }
    if (send_edid_message(driver, 0x15, 0x53, (uint8_t)(1u << head->ddc_selector), 0,
                          "post-EDID query") < 0) {
        return -1;
    }
    (void)drain_edid(driver, head, 64, 0.005);
    /* DLM teardown can briefly leave HPD false even though DDC already answers. Never arm an
     * endpoint on EDID alone: wait for the measured presence bit to settle after engagement. */
    for (int i = 0; i < 20 && !head->present; i++) {
        if (send_edid_message(driver, 0x15, 0x20, head->ddc_selector, 0,
                              "post-EDID presence probe") < 0) {
            return -1;
        }
        (void)drain_edid(driver, head, 64, 0.005);
        if (!head->present) {
            usleep(100000);
        }
    }
    return head->edid_len && head->present ? 0 : -1;
}

MViewDriver *mview_driver_engage(MViewSession *session, uint16_t product_id) {
    const MViewDL3Profile *profile = mview_dl3_profile(product_id);
    if (!session || !profile) {
        mview_log("unsupported DisplayLink product 0x%04x", product_id);
        return NULL;
    }
    uint8_t identity_bytes[64];
    MViewIdentity identity;
    int identity_len = mview_session_get_identity(session, identity_bytes, sizeof(identity_bytes));
    if (identity_len < 0 || mview_identity_parse(&identity, identity_bytes, identity_len) < 0 ||
        identity.family != MVIEW_FAMILY_RIDGE) {
        mview_log("claimed DL3 interface did not contain a Ridge type-0x40 identity");
        return NULL;
    }
    mview_log("identity %s firmware %u.%u.%u", identity.platform, identity.firmware[0],
              identity.firmware[1], identity.firmware[2]);
    MViewDriver *driver = calloc(1, sizeof(*driver));
    if (!driver) {
        return NULL;
    }
    driver->session = session;
    driver->profile = profile;
    for (uint8_t i = 0; i < profile->head_count; i++) {
        driver->head[i].logical_head = i;
        driver->head[i].ddc_selector = profile->ddc_selector[i];
        driver->head[i].video_endpoint = profile->video_endpoint[i];
        mview_damage_init(&driver->damage[i], 1920, 1080);
    }
    if (run_shared_ake(driver) < 0 || configure_control(driver) < 0) {
        mview_log("driver engagement failed");
        free(driver);
        return NULL;
    }
    mview_log("native Ridge control session engaged");
    return driver;
}

int mview_driver_fetch_edids(MViewDriver *driver) {
    if (!driver) {
        return -1;
    }
    int result = 0;
    for (uint8_t i = 0; i < driver->profile->head_count; i++) {
        if (mview_driver_fetch_edid(driver, i) < 0) {
            mview_log("head %u selector %u returned no valid EDID", i,
                      driver->head[i].ddc_selector);
            result = -1;
        }
    }
    return result;
}

int mview_driver_fetch_edid(MViewDriver *driver, uint8_t head) {
    if (!driver || head >= driver->profile->head_count) {
        return -1;
    }
    return fetch_one_edid(driver, &driver->head[head]);
}

int mview_driver_get_head(const MViewDriver *driver, uint8_t head, MViewHeadStatus *status) {
    if (!driver || !status || head >= driver->profile->head_count) {
        return -1;
    }
    *status = driver->head[head];
    return 0;
}

/*
 * Non-zero once the head has had its mode activated and its decoder armed. A head this run
 * is not driving over the dock never gets there, and asking it to scan out is not an error.
 */
int mview_driver_head_is_armed(const MViewDriver *driver, uint8_t head) {
    if (!driver || head >= driver->profile->head_count) {
        return 0;
    }
    return driver->active[head] != 0;
}

int mview_driver_get_verification(const MViewDriver *driver, MViewDriverVerification *status) {
    if (!driver || !status) {
        return -1;
    }
    *status = driver->verification;
    return 0;
}

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} ByteBuffer;

static int buffer_init(ByteBuffer *buffer, size_t capacity) {
    memset(buffer, 0, sizeof(*buffer));
    buffer->bytes = malloc(capacity);
    if (!buffer->bytes) {
        return -1;
    }
    buffer->capacity = capacity;
    return 0;
}

static void buffer_free(ByteBuffer *buffer) {
    free(buffer->bytes);
    memset(buffer, 0, sizeof(*buffer));
}

static int buffer_append(ByteBuffer *buffer, const void *bytes, size_t length) {
    if (length > buffer->capacity - buffer->length) {
        size_t wanted = buffer->length + length;
        size_t capacity = buffer->capacity ? buffer->capacity : 4096;
        while (capacity < wanted) {
            capacity *= 2;
        }
        uint8_t *grown = realloc(buffer->bytes, capacity);
        if (!grown) {
            return -1;
        }
        buffer->bytes = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return 0;
}

typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t bit_count;
    int overflow;
} BitWriter;

static void bit_writer_init(BitWriter *writer, uint8_t *bytes, size_t capacity) {
    memset(bytes, 0, capacity);
    writer->bytes = bytes;
    writer->capacity = capacity;
    writer->bit_count = 0;
    writer->overflow = 0;
}

static void put_bit(BitWriter *writer, unsigned bit) {
    size_t byte = writer->bit_count / 8;
    if (byte >= writer->capacity) {
        writer->overflow = 1;
        return;
    }
    if (bit & 1) {
        writer->bytes[byte] |= (uint8_t)(1u << (writer->bit_count & 7));
    }
    writer->bit_count++;
}

static size_t bit_writer_finish(const BitWriter *writer) {
    return writer->overflow ? 0 : (writer->bit_count + 7) / 8;
}

static void put_flat_sync(BitWriter *writer) {
    put_bit(writer, 0);
    put_bit(writer, 0);
    for (int i = 0; i < 6; i++) {
        put_bit(writer, 1);
    }
    for (int i = 0; i < 7; i++) {
        put_bit(writer, 0);
    }
}

static void put_escape(BitWriter *writer, int value, unsigned max_category) {
    if (value == 0) {
        put_bit(writer, 0);
        return;
    }
    unsigned magnitude = (unsigned)(value < 0 ? -value : value);
    unsigned category = 0;
    for (unsigned n = magnitude; n; n >>= 1) {
        category++;
    }
    if (category > max_category) {
        category = max_category;
    }
    for (unsigned i = 0; i < category; i++) {
        put_bit(writer, 1);
    }
    if (category < max_category) {
        put_bit(writer, 0);
    }
    unsigned base = 1u << (category - 1);
    unsigned offset = magnitude - base;
    for (unsigned bit = category - 1; bit > 0; bit--) {
        put_bit(writer, (offset >> (bit - 1)) & 1);
    }
    put_bit(writer, value > 0);
}

static int round_signed_shift(int value, unsigned shift) {
    int half = 1 << (shift - 1);
    return value >= 0 ? (value + half) >> shift : -((-value + half) >> shift);
}

static size_t solid_strip(uint8_t *out, size_t capacity, uint16_t x, uint16_t y, uint8_t red,
                          uint8_t green, uint8_t blue) {
    uint8_t main_bytes[128];
    BitWriter main;
    bit_writer_init(&main, main_bytes, sizeof(main_bytes));
    for (int block = 0; block < 16; block++) {
        put_flat_sync(&main);
    }
    int fixed[3] = {
        64 * ((int)blue - (int)green),
        64 * ((int)red - (int)green),
        64 * (int)green +
            64 * ((((int)red - (int)green) + ((int)blue - (int)green)) >> 2),
    };
    int dc[3] = {
        round_signed_shift(fixed[0], 6),
        round_signed_shift(fixed[1], 6),
        round_signed_shift(fixed[2], 4),
    };
    int previous[3] = {0, 0, 0};
    for (int block = 0; block < 16; block++) {
        for (int plane = 0; plane < 3; plane++) {
            put_escape(&main, dc[plane] - previous[plane], 10);
            previous[plane] = dc[plane];
        }
    }
    size_t main_len = bit_writer_finish(&main);
    if (!main_len) {
        return 0;
    }
    size_t main_end = 16 + ((main_len + 1) & ~1u) + 2;
    size_t row1 = main_end;
    size_t length = row1;
    if (length > capacity || length > UINT16_MAX) {
        return 0;
    }
    memset(out, 0, length);
    out[0] = 0x01;
    out[1] = 0x28;
    put_u16(out + 2, x);
    put_u16(out + 4, y);
    put_u16(out + 10, (uint16_t)main_end);
    put_u16(out + 12, (uint16_t)row1);
    memcpy(out + 16, main_bytes, main_len);
    return length;
}

size_t mview_video_solid_strip(uint8_t *out, size_t cap, uint16_t x, uint16_t y, uint8_t red,
                               uint8_t green, uint8_t blue) {
    return solid_strip(out, cap, x, y, red, green, blue);
}

static void make_frame_trailer(uint8_t out[96], uint8_t head, uint32_t sequence) {
    memset(out, 0, 96);
    uint8_t phase = (uint8_t)((sequence % 3) * 2);
    uint8_t next = (uint8_t)((phase + 2) % 6);
    for (int record = 0; record < 3; record++) {
        size_t offset = (size_t)record * 32;
        mview_dl3_header(out + offset, 4, (uint16_t)(head | (record == 2 ? 0x10 : 0)),
                         record == 0 ? 6 : 4, 0, 16);
    }
    out[16] = 0x08;
    out[18] = 0x05;
    out[19] = phase;
    out[23] = (uint8_t)(phase * 4);
    out[25] = (uint8_t)(sequence + 1);
    for (size_t offset = 32; offset <= 64; offset += 32) {
        out[offset + 16] = 0x0a;
        out[offset + 18] = 0x04;
        out[offset + 19] = next;
        out[offset + 23] = (uint8_t)(next * 4);
        out[offset + 27] = (uint8_t)(phase * 4);
    }
}

static int build_solid_frame(ByteBuffer *frame, uint8_t head, uint32_t sequence, uint8_t red,
                             uint8_t green, uint8_t blue) {
    const uint32_t columns = 30;
    const uint32_t rows = 68;
    for (uint32_t row = 0; row < rows; row++) {
        uint8_t record[MVIEW_RECORD_CAP];
        memset(record, 0, 16);
        size_t record_len = 16;
        for (uint32_t column = 0; column < columns; column++) {
            uint8_t strip[128];
            size_t strip_len = solid_strip(strip, sizeof(strip), (uint16_t)(column * 64),
                                           (uint16_t)(row * 16), red, green, blue);
            if (!strip_len || record_len + 2 + strip_len > sizeof(record)) {
                return -1;
            }
            put_u16(record + record_len, (uint16_t)strip_len);
            record_len += 2;
            memcpy(record + record_len, strip, strip_len);
            record_len += strip_len;
        }
        size_t padding = (16 - (record_len & 15)) & 15;
        memset(record + record_len, 0, padding);
        record_len += padding;
        mview_dl3_header(record, 4, (uint16_t)(head | ((row & 1) << 4)),
                         (uint16_t)padding, 0, record_len - 16);
        if (buffer_append(frame, record, record_len) < 0) {
            return -1;
        }
    }
    uint8_t trailer[96];
    make_frame_trailer(trailer, head, sequence);
    return buffer_append(frame, trailer, sizeof(trailer));
}

static int finish_video_record(ByteBuffer *frame, uint8_t *record, size_t *record_len,
                               uint8_t head, uint32_t row) {
    if (*record_len <= 16) {
        return 0;
    }
    size_t padding = (16 - (*record_len & 15)) & 15;
    memset(record + *record_len, 0, padding);
    *record_len += padding;
    mview_dl3_header(record, 4, (uint16_t)(head | ((row & 1) << 4)), (uint16_t)padding, 0,
                     *record_len - 16);
    int rc = buffer_append(frame, record, *record_len);
    memset(record, 0, 16);
    *record_len = 16;
    return rc;
}

static int append_encoded_strip(ByteBuffer *frame, uint8_t *record, size_t *record_len,
                                uint8_t head, uint32_t row, const uint8_t *strip,
                                size_t strip_len) {
    if (*record_len > 16 && *record_len + 2 + strip_len > MVIEW_RECORD_STRIDE_CAP) {
        if (finish_video_record(frame, record, record_len, head, row) < 0) {
            return -1;
        }
    }
    /* A strip that alone overruns the stride cap still goes out in a record of its own.
     * Dropping the frame instead would end the session over one noisy tile. */
    if (*record_len + 2 + strip_len + 15 > MVIEW_RECORD_CAP) {
        return -1;
    }
    put_u16(record + *record_len, (uint16_t)strip_len);
    *record_len += 2;
    memcpy(record + *record_len, strip, strip_len);
    *record_len += strip_len;
    return 0;
}

static int build_encoded_records(ByteBuffer *frame, uint8_t head, const uint8_t *bgra,
                                 size_t stride, uint32_t width, uint32_t height,
                                 const MViewStrip *strips, int strip_count) {
    uint8_t record[MVIEW_RECORD_CAP];
    memset(record, 0, 16);
    size_t record_len = 16;
    int current_row = -1;
    for (int i = 0; i < strip_count; i++) {
        MViewStrip strip = strips[i];
        if ((int)strip.row != current_row) {
            if (current_row >= 0 &&
                finish_video_record(frame, record, &record_len, head, (uint32_t)current_row) < 0) {
                return -1;
            }
            current_row = (int)strip.row;
        }
        uint8_t encoded[MVIEW_STRIP_CAP];
        size_t encoded_len = mview_video_colour_strip_bgra(encoded, sizeof(encoded),
                                                           (uint16_t)strip.x, (uint16_t)strip.y,
                                                           bgra, stride, width, height);
        if (!encoded_len ||
            append_encoded_strip(frame, record, &record_len, head, strip.row, encoded,
                                 encoded_len) < 0) {
            return -1;
        }
    }
    if (current_row >= 0 &&
        finish_video_record(frame, record, &record_len, head, (uint32_t)current_row) < 0) {
        return -1;
    }
    return 0;
}

static int build_encoded_frame(ByteBuffer *frame, uint8_t head, uint32_t sequence,
                               const uint8_t *bgra, size_t stride, uint32_t width,
                               uint32_t height, const MViewStrip *strips, int strip_count) {
    if (build_encoded_records(frame, head, bgra, stride, width, height, strips, strip_count) < 0) {
        return -1;
    }
    uint8_t trailer[96];
    make_frame_trailer(trailer, head, sequence);
    return buffer_append(frame, trailer, sizeof(trailer));
}

size_t mview_video_encode_bgra_frame(uint8_t *out, size_t cap, uint8_t head, uint32_t sequence,
                                     const uint8_t *bgra, size_t stride, uint32_t width,
                                     uint32_t height, const MViewStrip *strips, int strip_count) {
    MViewStrip local[MVIEW_MAX_STRIPS];
    int count = strip_count;
    const MViewStrip *list = strips;
    if (!out || !bgra || width != 1920 || height != 1080 || stride < (size_t)width * 4) {
        return 0;
    }
    if (!list) {
        MViewDamageMap map;
        mview_damage_init(&map, width, height);
        count = mview_damage_update(&map, bgra, stride, local, MVIEW_MAX_STRIPS);
        list = local;
    }
    if (count <= 0 || count > MVIEW_MAX_STRIPS) {
        return 0;
    }
    ByteBuffer frame;
    if (buffer_init(&frame, 2 * 1024 * 1024) < 0) {
        return 0;
    }
    if (build_encoded_frame(&frame, head, sequence, bgra, stride, width, height, list, count) < 0 ||
        frame.length > cap) {
        buffer_free(&frame);
        return 0;
    }
    memcpy(out, frame.bytes, frame.length);
    size_t length = frame.length;
    buffer_free(&frame);
    return length;
}

uint64_t mview_video_solid_frame_fingerprint(uint8_t head, uint32_t sequence, uint8_t red,
                                             uint8_t green, uint8_t blue, size_t *frame_len) {
    ByteBuffer frame;
    if (buffer_init(&frame, 131072) < 0) {
        return 0;
    }
    if (build_solid_frame(&frame, head, sequence, red, green, blue) < 0) {
        buffer_free(&frame);
        return 0;
    }
    uint64_t hash = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < frame.length; i++) {
        hash ^= frame.bytes[i];
        hash *= 0x100000001b3ull;
    }
    if (frame_len) {
        *frame_len = frame.length;
    }
    buffer_free(&frame);
    return hash;
}

static uint32_t escape_threshold(unsigned category) {
    return (1u << (2 * category + 1)) - (1u << category);
}

static uint32_t magnitude_code(unsigned category) {
    uint32_t low = (1u << category) - 1;
    return low * ((1u << (category + 1)) - 1);
}

static void make_decoder_table(uint32_t table[47], unsigned max_category, int special_terminal) {
    memset(table, 0, 47 * sizeof(*table));
    for (unsigned category = 1; category < max_category; category++) {
        table[2 * category - 1] = escape_threshold(category);
        table[25 + 2 * (category - 1)] = magnitude_code(category);
    }
    unsigned first_terminal = 2 * max_category - 2;
    unsigned second_terminal = 24 + 2 * max_category - 2;
    uint32_t mask = (1u << max_category) - 1;
    if (special_terminal) {
        table[first_terminal] = (1u << (2 * max_category)) - 1;
        table[first_terminal + 1] = 1u << (2 * max_category + 1);
        table[second_terminal] = mask * mask;
        table[second_terminal + 1] = ((1u << (max_category + 1)) - 2) << max_category;
    } else {
        table[first_terminal] = 1u << (2 * max_category);
        table[second_terminal] = mask * mask;
    }
}

static size_t build_decoder_config(uint8_t out[1104], uint16_t width, uint16_t height,
                                   const uint8_t nonce[14]) {
    memset(out, 0, 1104);
    size_t offset = 0;
    uint16_t mode[] = {0x0018, 0x030b, 0x0204, 0x0002, 0x0002, width, height,
                       0x4000, 0x0002, width, height, 0x4000, 0};
    for (size_t i = 0; i < sizeof(mode) / sizeof(mode[0]); i++) {
        put_u16(out + offset, mode[i]);
        offset += 2;
    }
    for (unsigned index = 0; index < 5; index++) {
        uint32_t table[47];
        if (index == 0) {
            make_decoder_table(table, 9, 0);
        } else if (index <= 2) {
            make_decoder_table(table, 10, 0);
        } else if (index == 3) {
            make_decoder_table(table, 4, 1);
        } else {
            make_decoder_table(table, 7, 1);
        }
        put_u16(out + offset, 194);
        offset += 2;
        put_u16(out + offset, (uint16_t)((index << 8) | 0x0d));
        offset += 2;
        put_u32(out + offset, 1);
        offset += 4;
        for (size_t i = 0; i < 47; i++) {
            put_u32(out + offset, table[i]);
            offset += 4;
        }
    }
    uint16_t quant[41];
    size_t q = 0;
    uint16_t prefix[] = {10, 1, 1, 0, 64, 64};
    memcpy(quant + q, prefix, sizeof(prefix));
    q += sizeof(prefix) / sizeof(prefix[0]);
    /* The first decoder band has seven identical scalar slots before its wide triplet. */
    for (int i = 0; i < 7; i++) {
        quant[q++] = 16;
    }
    uint16_t a_tail[] = {32, 32, 32, 1, 1, 1};
    memcpy(quant + q, a_tail, sizeof(a_tail));
    q += sizeof(a_tail) / sizeof(a_tail[0]);
    for (int i = 0; i < 2; i++) {
        uint16_t triple[] = {16, 16, 4};
        memcpy(quant + q, triple, sizeof(triple));
        q += 3;
    }
    uint16_t b_tail[] = {32, 32, 8, 1, 1, 1};
    memcpy(quant + q, b_tail, sizeof(b_tail));
    q += sizeof(b_tail) / sizeof(b_tail[0]);
    for (int i = 0; i < 2; i++) {
        uint16_t triple[] = {32, 32, 2};
        memcpy(quant + q, triple, sizeof(triple));
        q += 3;
    }
    uint16_t c_tail[] = {64, 64, 4, 0};
    memcpy(quant + q, c_tail, sizeof(c_tail));
    q += sizeof(c_tail) / sizeof(c_tail[0]);
    if (q != 41) {
        return 0;
    }
    put_u16(out + offset, 82);
    offset += 2;
    for (size_t i = 0; i < q; i++) {
        put_u16(out + offset, quant[i]);
        offset += 2;
    }
    memcpy(out + offset, nonce, 14);
    offset += 14;
    return offset;
}

size_t mview_video_decoder_config(uint8_t *out, size_t cap, uint16_t width, uint16_t height,
                                  const uint8_t nonce[14]) {
    if (!out || cap < 1104 || !nonce) {
        return 0;
    }
    return build_decoder_config(out, width, height, nonce);
}

static int append_plain_arm(ByteBuffer *arm, uint16_t sub, const uint8_t body[16]) {
    uint8_t frame[32];
    mview_dl3_header(frame, 2, sub, 0, 0, 16);
    memcpy(frame + 16, body, 16);
    return buffer_append(arm, frame, sizeof(frame));
}

static int append_sealed_arm(ByteBuffer *arm, MViewDriver *driver, uint8_t head, uint16_t sub,
                             uint16_t aux, uint32_t seq, const uint8_t *plain,
                             size_t plain_len) {
    size_t capacity = 32 + plain_len;
    uint8_t *frame = malloc(capacity);
    if (!frame) {
        return -1;
    }
    size_t length = mview_dl3_seal_live(frame, capacity, driver->video_key[head],
                                        driver->video_nonce[head], sub, aux, seq, plain, plain_len);
    int rc = length ? buffer_append(arm, frame, length) : -1;
    free(frame);
    return rc;
}

static int build_video_arm(ByteBuffer *arm, MViewDriver *driver, uint8_t head) {
    uint8_t body[16];
    uint16_t sub;
    memset(body, 0, sizeof(body));
    put_u16(body, (uint16_t)(0x08 + head));
    put_u16(body + 2, 0x06);
    if (append_plain_arm(arm, (uint16_t)(0x08 + head), body) < 0) return -1;

    memset(body, 0, sizeof(body));
    put_u16(body, (uint16_t)(0x08 + head));
    put_u16(body + 2, 0x16);
    if (append_plain_arm(arm, (uint16_t)(0x18 + head), body) < 0) return -1;

    for (int i = 0; i < 2; i++) {
        memset(body, 0, sizeof(body));
        static const uint8_t marker[6] = {0x04, 0x00, 0x08, 0x04, 0x03, 0x00};
        memcpy(body, marker, sizeof(marker));
        mview_hdcp_random(body + 6, 10);
        sub = (uint16_t)((i ? 0x18 : 0x08) + head);
        if (append_sealed_arm(arm, driver, head, sub, 0x0a, (uint32_t)i, body,
                              sizeof(body)) < 0) return -1;
    }

    memset(body, 0, sizeof(body));
    put_u16(body, head);
    if (append_plain_arm(arm, head, body) < 0) return -1;
    memset(body, 0, sizeof(body));
    put_u16(body, head);
    put_u16(body + 2, 0x10);
    if (append_plain_arm(arm, (uint16_t)(0x10 + head), body) < 0) return -1;

    static const uint8_t fixed_body[16] = {
        0x0a, 0x00, 0x04, 0x00, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 0,
    };
    for (int i = 0; i < 2; i++) {
        uint8_t frame[32];
        mview_dl3_header(frame, 4, (uint16_t)((i ? 0x10 : 0x00) + head), 0x04, 0, 16);
        memcpy(frame + 16, fixed_body, 16);
        if (buffer_append(arm, frame, sizeof(frame)) < 0) return -1;
    }

    for (int i = 0; i < 2; i++) {
        uint8_t config[1104];
        uint8_t nonce[14];
        mview_hdcp_random(nonce, sizeof(nonce));
        if (build_decoder_config(config, 1920, 1080, nonce) != sizeof(config)) return -1;
        sub = (uint16_t)((i ? 0x18 : 0x08) + head);
        uint32_t seq = i ? 71 : 2;
        if (append_sealed_arm(arm, driver, head, sub, 0x0e, seq, config,
                              sizeof(config)) < 0) return -1;
    }
    return arm->length == 2560 ? 0 : -1;
}

int mview_video_plan_usb_chunks(const void *bytes, size_t length, size_t transfer_size,
                                MViewUSBChunk *chunks, int max_chunks) {
    if (transfer_size == 0) {
        return -1;
    }
    if (length == 0) {
        return 0;
    }
    if (!bytes) {
        return -1;
    }
    size_t needed64 = (length + transfer_size - 1) / transfer_size;
    if (needed64 > (size_t)INT_MAX) {
        return -1;
    }
    int needed = (int)needed64;
    if (!chunks) {
        return needed;
    }
    if (max_chunks < needed) {
        return -1;
    }
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t remaining = length;
    for (int i = 0; i < needed; i++) {
        size_t n = remaining > transfer_size ? transfer_size : remaining;
        chunks[i].bytes = cursor;
        chunks[i].length = n;
        cursor += n;
        remaining -= n;
    }
    return needed;
}

/*
 * A frame goes out as exactly one transfer. The previous version split every frame
 * at 64 KB — an exact multiple of the 1024-byte max packet size — and enqueued the
 * pieces as separate IO requests. Ridge reads each transfer boundary as a frame
 * delimiter, so a 502 KB raster arrived as seven malformed frames and halted the
 * endpoint a second or so into scanout.
 */
static int submit_video(MViewDriver *driver, uint8_t head, const ByteBuffer *stream) {
    uint8_t endpoint = driver->profile->video_endpoint[head];
    if (stream->length == 0) {
        return 0;
    }
    unsigned recent = driver->recent_next[head]++ % 8;
    driver->recent_video[head][recent].sequence = driver->frame_seq[head];
    driver->recent_video[head][recent].length = stream->length;
    MVIEW_PROFILE_BEGIN(usb, MVIEW_ZONE_USB_WRITE);
    int wrote = mview_session_bulk_out_frame(driver->session, endpoint, stream->bytes,
                                             stream->length);
    MVIEW_PROFILE_END(usb, MVIEW_ZONE_USB_WRITE);
    if (wrote < 0) {
        mview_log("video endpoint 0x%02x rejected %zu-byte frame", endpoint, stream->length);
        for (unsigned i = 0; i < 8; i++) {
            unsigned slot = (driver->recent_next[head] + i) % 8;
            mview_log("recent head %u sequence=%u bytes=%zu", head,
                      driver->recent_video[head][slot].sequence,
                      driver->recent_video[head][slot].length);
        }
        char path[96];
        snprintf(path, sizeof(path), "logs/failed-frame-head%u.bin", head);
        FILE *failed = mview_config()->capture_dump_frames ? fopen(path, "wb") : NULL;
        if (failed) {
            fwrite(stream->bytes, 1, stream->length, failed);
            fclose(failed);
        }
        drain_control_debug(driver, 64, 0.01);
        return -1;
    }
    driver->verification.video_writes[head]++;
    /* Bytes, not just transfers: a saturated link and a per-transfer latency floor look
       the same in a count of writes and want opposite fixes. */
    if (mview_profile_active) {
        static _Atomic uint64_t bytes[MVIEW_DL3_MAX_HEADS], writes[MVIEW_DL3_MAX_HEADS];
        uint64_t total = atomic_fetch_add(&bytes[head], stream->length) + stream->length;
        uint64_t n = atomic_fetch_add(&writes[head], 1) + 1;
        if (n % 128 == 0) {
            mview_log("head %u video: %llu writes, %llu bytes, mean %llu bytes/frame", head,
                      (unsigned long long)n, (unsigned long long)total,
                      (unsigned long long)(total / n));
        }
    }
    return 0;
}

static int send_solid_frame(MViewDriver *driver, uint8_t head, int with_arm, uint8_t red,
                            uint8_t green, uint8_t blue) {
    ByteBuffer stream;
    if (buffer_init(&stream, 196608) < 0) {
        return -1;
    }
    int rc = 0;
    if (with_arm && build_video_arm(&stream, driver, head) < 0) {
        rc = -1;
    }
    if (rc == 0 && build_solid_frame(&stream, head, driver->frame_seq[head], red, green, blue) < 0) {
        rc = -1;
    }
    if (rc == 0 && submit_video(driver, head, &stream) < 0) {
        rc = -1;
    }
    if (rc == 0) {
        driver->frame_seq[head]++;
    }
    buffer_free(&stream);
    return rc;
}

static int send_random_tail(MViewDriver *driver, uint16_t id, uint16_t sub, const char *name) {
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), id, sub, driver->inner_counter);
    mview_hdcp_random(plain + 22, 10);
    if (send_inner(driver, id, plain, sizeof(plain), name) < 0) {
        return -1;
    }
    drain_control_debug(driver, 8, 0.001);
    return 0;
}

static int send_marker(MViewDriver *driver, uint8_t head, uint16_t sub, uint8_t state) {
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), 0x16, sub, driver->inner_counter);
    plain[22] = head;
    plain[23] = state;
    mview_hdcp_random(plain + 24, 8);
    return send_inner(driver, 0x16, plain, sizeof(plain), "stream marker");
}

static int send_stream_commit(MViewDriver *driver, uint8_t head) {
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), 0x16, 0x4c, driver->inner_counter);
    plain[22] = head ? 1 : 0;
    mview_hdcp_random(plain + 24, 8);
    return send_inner(driver, 0x16, plain, sizeof(plain), "stream commit");
}

/*
 * OUT session heartbeat, id=0x16 sub=0x75: two AES blocks with 0x2ee0 at offset 22 and
 * the tail ignored. It runs for the whole streaming session.
 */
static int send_heartbeat(MViewDriver *driver) {
    uint8_t plain[32];
    inner_header(plain, sizeof(plain), 0x16, 0x75, driver->inner_counter);
    plain[22] = 0xe0;
    plain[23] = 0x2e;
    return send_inner(driver, 0x16, plain, sizeof(plain), NULL);
}

static uint64_t monotonic_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void wait_offset(uint64_t anchor, unsigned milliseconds) {
    uint64_t deadline = anchor + (uint64_t)milliseconds * 1000000ull;
    uint64_t now = monotonic_ns();
    if (now < deadline) {
        usleep((useconds_t)((deadline - now) / 1000));
    }
}

static int activate_1080p60_once(MViewDriver *driver, uint8_t head) {
    if (!driver || head >= driver->profile->head_count || !driver->head[head].authenticated ||
        !driver->head[head].present || !driver->head[head].edid_len) {
        return -1;
    }
    uint8_t mode[80];
    size_t mode_len = mview_dl3_set_mode_1080p60(mode, sizeof(mode), driver->inner_counter, head);
    if (!mode_len || send_inner(driver, 0x48, mode, mode_len, "set 1080p60 mode") < 0 ||
        send_random_tail(driver, 0x14, 0x0c, "mode status poll") < 0) {
        return -1;
    }
    uint64_t anchor = monotonic_ns();
    wait_offset(anchor, 5);
    if (send_marker(driver, head, 0x2f, 1) < 0) return -1;
    wait_offset(anchor, 9);
    if (send_marker(driver, head, 0x2e, 3) < 0) return -1;
    wait_offset(anchor, 12);
    if (send_marker(driver, head, 0x2f, 1) < 0) return -1;
    wait_offset(anchor, 14);
    if (send_marker(driver, head, 0x2e, 3) < 0) return -1;
    wait_offset(anchor, 20);
    if (send_marker(driver, head, 0x2f, 1) < 0 ||
        send_random_tail(driver, 0x14, 0x0c, "mode status poll") < 0) return -1;
    wait_offset(anchor, 26);
    if (send_marker(driver, head, 0x2e, 0) < 0) return -1;
    wait_offset(anchor, 89);
    if (send_random_tail(driver, 0x14, 0x0c, "mode status poll") < 0) return -1;
    wait_offset(anchor, 95);
    if (send_random_tail(driver, 0x14, 0x0c, "mode status poll") < 0) return -1;
    wait_offset(anchor, 110);
    if (send_random_tail(driver, 0x14, 0x0c, "mode status poll") < 0) return -1;
    if (monotonic_ns() - anchor > 300000000ull) {
        mview_log("head %u activation bracket overran before first video", head);
        return -2;
    }
    driver->frame_seq[head] = 0;
    if (send_solid_frame(driver, head, 1, 0, 0, 0) < 0 ||
        send_stream_commit(driver, head) < 0 || send_stream_commit(driver, head) < 0) {
        return -1;
    }
    wait_offset(anchor, 123);
    if (send_marker(driver, head, 0x2f, 0) < 0) return -1;
    wait_offset(anchor, 125);
    if (send_marker(driver, head, 0x2e, 0) < 0) return -1;
    uint64_t next_poll = monotonic_ns();
    while (monotonic_ns() - anchor < 700000000ull) {
        if (send_solid_frame(driver, head, 0, 0, 0, 0) < 0) return -1;
        if (monotonic_ns() >= next_poll) {
            if (send_random_tail(driver, 0x14, 0x0c, "training status poll") < 0) return -1;
            next_poll = monotonic_ns() + 16000000ull;
        }
    }
    driver->active[head] = 1;
    mview_log("head %u 1920x1080p60 video endpoint trained", head);
    return 0;
}

int mview_driver_activate_1080p60(MViewDriver *driver, uint8_t head) {
    for (int attempt = 0; attempt < 3; attempt++) {
        int result = activate_1080p60_once(driver, head);
        if (result != -2) return result;
        // No video was submitted if the timing bracket overran. Start a new mode
        // sequence rather than continuing the expired one or widening its deadline.
        mview_log("head %u retrying mode activation after scheduler delay (%d/3)", head, attempt + 1);
    }
    return -1;
}

int mview_driver_present_solid(MViewDriver *driver, uint8_t head, uint8_t red, uint8_t green,
                               uint8_t blue) {
    if (!driver || head >= driver->profile->head_count || !driver->active[head]) {
        return -1;
    }
    for (int copy = 0; copy < 2; copy++) {
        if (send_solid_frame(driver, head, 0, red, green, blue) < 0) {
            return -1;
        }
    }
    return send_random_tail(driver, 0x14, 0x0c, "present status poll");
}

/* Frame the cached bodies of `strips` into image records, grouped by y-band. */
static int build_body_records(ByteBuffer *frame, MViewDriver *driver, uint8_t head,
                              const MViewStrip *strips, int count) {
    uint8_t record[MVIEW_RECORD_CAP];
    memset(record, 0, 16);
    size_t record_len = 16;
    int current_row = -1;
    for (int i = 0; i < count; i++) {
        uint32_t index = strips[i].row * driver->damage[head].cols + strips[i].col;
        if (!driver->strip_body[head][index]) {
            return -1;
        }
        if ((int)strips[i].row != current_row) {
            if (current_row >= 0 &&
                finish_video_record(frame, record, &record_len, head, (uint32_t)current_row) < 0) {
                return -1;
            }
            current_row = (int)strips[i].row;
        }
        if (append_encoded_strip(frame, record, &record_len, head, strips[i].row,
                                 driver->strip_body[head][index],
                                 driver->strip_body_len[head][index]) < 0) {
            return -1;
        }
    }
    if (current_row >= 0 &&
        finish_video_record(frame, record, &record_len, head, (uint32_t)current_row) < 0) {
        return -1;
    }
    return 0;
}

/* Re-encode only the strips whose content actually moved; the rest are already cached. */
/* Re-encode one strip into its cache slot. Slots are indexed by strip, so concurrent
   calls for different strips share nothing but the read-only surface. */
static int encode_strip_body(MViewDriver *driver, uint8_t head, const MViewDamageMap *map,
                             const uint8_t *bgra, size_t stride, uint32_t width, uint32_t height,
                             MViewStrip strip) {
    uint32_t index = strip.row * map->cols + strip.col;
    if (driver->strip_body[head][index] &&
        driver->strip_body_hash[head][index] == map->pending[index]) {
        return 0;
    }
    uint8_t encoded[MVIEW_STRIP_CAP];
    size_t length = mview_video_colour_strip_bgra(encoded, sizeof(encoded), (uint16_t)strip.x,
                                                  (uint16_t)strip.y, bgra, stride, width, height);
    if (!length) {
        return -1;
    }
    if (length > driver->strip_body_capacity[head][index]) {
        // Motion changes encoded lengths every frame. Retain capacity instead of
        // making all encoder workers resize their allocations for every strip.
        size_t capacity = (length + 255) & ~(size_t)255;
        uint8_t *body = realloc(driver->strip_body[head][index], capacity);
        if (!body) return -1;
        driver->strip_body[head][index] = body;
        driver->strip_body_capacity[head][index] = (uint16_t)capacity;
    }
    memcpy(driver->strip_body[head][index], encoded, length);
    driver->strip_body_len[head][index] = (uint16_t)length;
    driver->strip_body_hash[head][index] = map->pending[index];
    return 0;
}

/* Below this, the dispatch handshake costs more than the encoding it would spread. A
   moved window charges a few macro tiles; only a keyframe or a full-screen change is
   large enough to be worth splitting. */
static int refresh_strip_bodies(MViewDriver *driver, uint8_t head, const uint8_t *bgra,
                                size_t stride, uint32_t width, uint32_t height,
                                const MViewStrip *strips, int count) {
    const MViewDamageMap *map = &driver->damage[head];
    MVIEW_PROFILE_BEGIN(encode, MVIEW_ZONE_ENCODE_STRIPS);
    if (count < mview_config()->encode_parallel_threshold) {
        for (int i = 0; i < count; i++) {
            if (encode_strip_body(driver, head, map, bgra, stride, width, height, strips[i]) < 0) {
                MVIEW_PROFILE_END(encode, MVIEW_ZONE_ENCODE_STRIPS);
                return -1;
            }
        }
        MVIEW_PROFILE_END(encode, MVIEW_ZONE_ENCODE_STRIPS);
        return 0;
    }
    _Atomic int failed = 0;
    _Atomic int *failure = &failed;
    dispatch_apply((size_t)count, DISPATCH_APPLY_AUTO, ^(size_t i) {
      if (atomic_load_explicit(failure, memory_order_relaxed)) {
          return;
      }
      if (encode_strip_body(driver, head, map, bgra, stride, width, height, strips[i]) < 0) {
          atomic_store_explicit(failure, 1, memory_order_relaxed);
      }
    });
    MVIEW_PROFILE_END(encode, MVIEW_ZONE_ENCODE_STRIPS);
    return atomic_load(&failed) ? -1 : 0;
}

/*
 * One logical frame, presented `presentations` times. Each presentation carries the same
 * records under a freshly advanced trailer, whose phase is how the dock steps to the next
 * of its buffers; repeating one sequence number would pin it.
 */
static int submit_strip_frame(MViewDriver *driver, uint8_t head, const MViewStrip *strips,
                              int count, int presentations) {
    MVIEW_PROFILE_BEGIN(submit, MVIEW_ZONE_SUBMIT);
    ByteBuffer stream;
    if (buffer_init(&stream, 512 * 1024) < 0) {
        MVIEW_PROFILE_END(submit, MVIEW_ZONE_SUBMIT);
        return -1;
    }
    uint8_t trailer[96];
    int rc = build_body_records(&stream, driver, head, strips, count);
    size_t body_len = stream.length;
    if (rc == 0) {
        make_frame_trailer(trailer, head, driver->frame_seq[head]);
        rc = buffer_append(&stream, trailer, sizeof(trailer));
    }
    for (int copy = 0; rc == 0 && copy < presentations; copy++) {
        make_frame_trailer(stream.bytes + body_len, head, driver->frame_seq[head]);
        rc = submit_video(driver, head, &stream);
        driver->frame_seq[head]++;
    }
    buffer_free(&stream);
    MVIEW_PROFILE_END(submit, MVIEW_ZONE_SUBMIT);
    return rc;
}

/*
 * ScreenCaptureKit delivers a frame only when the content changes, so a static desktop
 * stops the callback entirely and with it the repayment of any outstanding strip debt.
 * The caller drives this on a steady timer to finish paying it. An idle desktop that
 * owes nothing puts zero bytes on the wire, which is what DisplayLink Manager does: the
 * dock holds the last image in its own buffers.
 */
int mview_driver_refresh_head(MViewDriver *driver, uint8_t head) {
    if (!driver || head >= driver->profile->head_count || !driver->active[head]) {
        return -1;
    }
    /* Nothing is cached to repay from until the first full frame has landed. */
    if (driver->damage[head].keyframe_owed) {
        return 0;
    }
    MViewStrip owed[MVIEW_MAX_STRIPS];
    int count = mview_damage_owed(&driver->damage[head], owed, MVIEW_MAX_STRIPS);
    if (count <= 0 || count > MVIEW_MAX_STRIPS) {
        return count > MVIEW_MAX_STRIPS ? -1 : 0;
    }
    /*
     * No status poll here. Ridge pushes state changes unsolicited on 0x03/0x82 and
     * the vendor probes only a handful of times per session; polling every frame
     * produces transient negatives that the driver then reads as the monitor going
     * away.
     */
    if (submit_strip_frame(driver, head, owed, count, 1) < 0) {
        return -1;
    }
    mview_damage_presented(&driver->damage[head]);
    return 0;
}

static int present_bgra_mosaic(MViewDriver *driver, uint8_t head, const uint8_t *bgra,
                               size_t stride, uint32_t width, uint32_t height,
                               const MViewDirtyRect *rects, int rect_count) {
    if (!driver || !bgra || head >= driver->profile->head_count || !driver->active[head] ||
        width != 1920 || height != 1080 || stride < (size_t)width * 4) {
        return -1;
    }
    /*
     * DisplayLink Manager does not stream whole frames. It hashes the surface a strip at
     * a time, sends the macro tiles whose content moved, and sends nothing at all while
     * the desktop is still. A complete raster per frame is both orders of magnitude more
     * bytes and a different wire shape from the one the dock was built around, which is
     * what the link kept failing under.
     */
    MViewStrip owed[MVIEW_MAX_STRIPS];
    int presentations = 1;
    int count = mview_damage_plan_dirty(&driver->damage[head], bgra, stride, rects, rect_count,
                                        owed, MVIEW_MAX_STRIPS, &presentations);
    if (count > MVIEW_MAX_STRIPS) {
        return -1;
    }
    if (count == 0) {
        return 0;
    }
    int keyframe = driver->damage[head].keyframe_owed;
    if (refresh_strip_bodies(driver, head, bgra, stride, width, height, owed, count) < 0 ||
        submit_strip_frame(driver, head, owed, count, presentations) < 0) {
        return -1;
    }
    mview_damage_presented(&driver->damage[head]);
    /* A static desktop is silent on the control plane, which makes a healthy idle stream
     * look identical to a dead one in the log. Say so periodically. */
    if (keyframe || driver->frame_seq[head] % 64 < (uint32_t)presentations) {
        mview_log("head %u scanout: frame %u, %d of %u strips%s", head, driver->frame_seq[head],
                  count, driver->damage[head].rows * driver->damage[head].cols,
                  keyframe ? " (keyframe)" : "");
    }
    return 0;
}

int mview_driver_present_bgra_dirty(MViewDriver *driver, uint8_t head, const uint8_t *bgra,
                                    size_t stride, uint32_t width, uint32_t height,
                                    const MViewDirtyRect *rects, int rect_count) {
    MVIEW_PROFILE_BEGIN(present, MVIEW_ZONE_PRESENT);
    int rc = present_bgra_mosaic(driver, head, bgra, stride, width, height, rects, rect_count);
    MVIEW_PROFILE_END(present, MVIEW_ZONE_PRESENT);
    return rc;
}

int mview_driver_present_bgra_mosaic(MViewDriver *driver, uint8_t head, const uint8_t *bgra,
                                     size_t stride, uint32_t width, uint32_t height) {
    return mview_driver_present_bgra_dirty(driver, head, bgra, stride, width, height, NULL, 0);
}

/*
 * The control session has its own clocks, and they are not the video clock. An idle
 * desktop puts nothing on the video endpoints, but the dock still expects a 13 ms status
 * poll and a 3 s heartbeat; without them it tears the link down and the panels report no
 * signal. Presence probing is deliberately not on this path — it is a once-a-second
 * question whose transient negatives read as a monitor unplugging.
 */
static int service_control(MViewDriver *driver) {
    if (!driver) {
        return -1;
    }
    uint64_t now = monotonic_ns();
    if (driver->next_keepalive && now < driver->next_keepalive) {
        return 0;
    }
    if (send_random_tail(driver, 0x14, 0x0c, NULL) < 0) {
        return -1;
    }
    const MViewConfig *config = mview_config();
    driver->next_keepalive = now + (uint64_t)config->control_poll_ms * 1000000ull;
    if (now >= driver->next_heartbeat) {
        if (send_heartbeat(driver) < 0) {
            return -1;
        }
        driver->next_heartbeat = now + (uint64_t)config->control_heartbeat_s * 1000000000ull;
    }
    /* Keep the IN endpoint from backing up behind the replies these provoke. */
    drain_control_quiet(driver, 4, 0.0);
    return 0;
}

int mview_driver_service_control(MViewDriver *driver) {
    MVIEW_PROFILE_BEGIN(control, MVIEW_ZONE_CONTROL);
    int rc = service_control(driver);
    MVIEW_PROFILE_END(control, MVIEW_ZONE_CONTROL);
    return rc;
}

void mview_driver_destroy(MViewDriver *driver) {
    if (driver) {
        for (int head = 0; head < MVIEW_DL3_MAX_HEADS; head++) {
            for (int strip = 0; strip < MVIEW_MAX_STRIPS; strip++) {
                free(driver->strip_body[head][strip]);
            }
        }
        memset(driver, 0, sizeof(*driver));
        free(driver);
    }
}
