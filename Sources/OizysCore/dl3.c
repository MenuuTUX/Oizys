#include "oizys_dl3.h"

#include <stdio.h>
#include <string.h>

static const uint8_t CP_KEY_WHITEN[16] = {
    0x26, 0xab, 0xee, 0x38, 0x93, 0xd0, 0xc4, 0x32,
    0x61, 0x43, 0xa4, 0xbf, 0x5b, 0x45, 0xd6, 0xec,
};

void oizys_cp_session_key(const uint8_t raw[16], uint8_t live[16]) {
    for (int i = 0; i < 16; i++) {
        live[i] = raw[i] ^ CP_KEY_WHITEN[i];
    }
}

static const OizysDL3Profile RIDGE_6000 = {
    .product_id = 0x6000,
    .head_count = 2,
    .video_endpoint = {0x08, 0x0b},
    .ddc_selector = {1, 3},
};

const OizysDL3Profile *oizys_dl3_profile(uint16_t product_id) {
    return product_id == RIDGE_6000.product_id ? &RIDGE_6000 : NULL;
}

int oizys_dl3_parse_ridge_edid(const uint8_t *plain, size_t plain_len, uint8_t *edid,
                               size_t edid_cap, size_t *edid_len) {
    static const uint8_t magic[8] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
    const size_t payload_offset = 22;
    if (edid_len) {
        *edid_len = 0;
    }
    if (!plain || plain_len < payload_offset + 128 || !edid) {
        return -1;
    }
    uint16_t id = 0, sub = 0;
    memcpy(&id, plain, sizeof(id));
    memcpy(&sub, plain + 2, sizeof(sub));
    if (id != 0x0114 || sub != 0x0021 ||
        memcmp(plain + payload_offset, magic, sizeof(magic)) != 0) {
        return -1;
    }
    const uint8_t *source = plain + payload_offset;
    size_t blocks = (size_t)source[126] + 1;
    if (blocks > SIZE_MAX / 128) {
        return -1;
    }
    size_t bytes = blocks * 128;
    if (plain_len - payload_offset < bytes || edid_cap < bytes) {
        return -1;
    }
    for (size_t block = 0; block < blocks; block++) {
        uint8_t sum = 0;
        for (size_t i = 0; i < 128; i++) {
            sum = (uint8_t)(sum + source[block * 128 + i]);
        }
        if (sum != 0) {
            return -1;
        }
    }
    memcpy(edid, source, bytes);
    if (edid_len) {
        *edid_len = bytes;
    }
    return 0;
}

void oizys_dl3_header(uint8_t out[16], uint32_t type, uint16_t sub, uint16_t aux, uint32_t seq,
                      size_t body_len) {
    memset(out, 0, 16);
    uint16_t size = (uint16_t)((16 + body_len) - 4);
    memcpy(out + 2, &size, 2);
    memcpy(out + 4, &type, 4);
    memcpy(out + 8, &sub, 2);
    memcpy(out + 10, &aux, 2);
    memcpy(out + 12, &seq, 4);
}

static size_t push_frame(uint8_t *out, size_t cap, uint32_t type, uint16_t sub, uint16_t aux,
                         uint32_t seq, const uint8_t *body, size_t body_len) {
    if (16 + body_len > cap) {
        return 0;
    }
    oizys_dl3_header(out, type, sub, aux, seq, body_len);
    if (body_len) {
        memcpy(out + 16, body, body_len);
    }
    return 16 + body_len;
}

size_t oizys_dl3_init_0(uint8_t *out, size_t cap) {
    return push_frame(out, cap, 0x01, 0x00, 0, 0, NULL, 0);
}

size_t oizys_dl3_init_25(uint8_t *out, size_t cap) {
    static const uint8_t body[16] = {0x05, 0, 0x08, 0};
    return push_frame(out, cap, 0x02, 0x25, 0, 0, body, 16);
}

size_t oizys_dl3_init_4_probe(uint8_t *out, size_t cap) {
    static const uint8_t a[16] = {0x04};
    static const uint8_t probe[32] = {0x14, 0, 0x90};
    size_t n = push_frame(out, cap, 0x02, 0x04, 0, 0, a, 16);
    if (!n) {
        return 0;
    }
    size_t m = push_frame(out + n, cap - n, 0x04, 0x04, 0x0a, 0, probe, 32);
    if (!m) {
        return 0;
    }
    return n + m;
}

static size_t hdcp_body(uint8_t *b, size_t body_len, uint16_t sub_size, uint32_t hdcp_seq,
                        uint8_t msg_id, const uint8_t *payload, size_t payload_len) {
    memset(b, 0, body_len);
    memcpy(b + 0, &sub_size, 2);
    uint16_t mark = 0x0010;
    memcpy(b + 2, &mark, 2);
    memcpy(b + 4, &hdcp_seq, 4);
    uint32_t m30 = 0x00000030;
    memcpy(b + 22, &m30, 4);
    b[27] = msg_id;
    if (payload && payload_len) {
        memcpy(b + 28, payload, payload_len);
    }
    return body_len;
}

size_t oizys_hdcp_session_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq) {
    uint8_t b[32] = {0};
    uint16_t a = 0x0014, c = 0x0076;
    memcpy(b, &a, 2);
    memcpy(b + 2, &c, 2);
    memcpy(b + 4, &hdcp_seq, 4);
    return push_frame(out, cap, 0x04, 0x04, 0x0a, seq, b, 32);
}

size_t oizys_hdcp_ake_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                           const uint8_t rtx[8]) {
    uint8_t payload[11];
    memcpy(payload, rtx, 8);
    payload[8] = 0x00;
    payload[9] = 0x00;
    payload[10] = 0x00;
    uint8_t b[48];
    hdcp_body(b, 48, 0x0022, hdcp_seq, 0x02, payload, 11);
    return push_frame(out, cap, 0x04, 0x04, 0x0c, seq, b, 48);
}

size_t oizys_hdcp_ake_txinfo(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq) {
    static const uint8_t payload[5] = {0x00, 0x06, 0x02, 0x00, 0x02};
    uint8_t b[48];
    hdcp_body(b, 48, 0x001f, hdcp_seq, 0x13, payload, 5);
    return push_frame(out, cap, 0x04, 0x04, 0x0f, seq, b, 48);
}

size_t oizys_hdcp_ake_no_stored_km(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                                   const uint8_t ekpub[128]) {
    uint8_t b[160];
    hdcp_body(b, 160, 0x009a, hdcp_seq, 0x04, ekpub, 128);
    return push_frame(out, cap, 0x04, 0x04, 0x04, seq, b, 160);
}

size_t oizys_hdcp_lc_init(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                          const uint8_t rn[8]) {
    uint8_t b[48];
    hdcp_body(b, 48, 0x0022, hdcp_seq, 0x09, rn, 8);
    return push_frame(out, cap, 0x04, 0x04, 0x0c, seq, b, 48);
}

size_t oizys_hdcp_ske_send_eks(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t edkey[16], const uint8_t riv[8]) {
    uint8_t payload[24];
    memcpy(payload, edkey, 16);
    memcpy(payload + 16, riv, 8);
    uint8_t b[64];
    hdcp_body(b, 64, 0x0032, hdcp_seq, 0x0b, payload, 24);
    return push_frame(out, cap, 0x04, 0x04, 0x0c, seq, b, 64);
}

size_t oizys_hdcp_repeater_ack(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq,
                               const uint8_t v_lsb[16]) {
    uint8_t b[48];
    hdcp_body(b, 48, 0x002a, hdcp_seq, 0x0f, v_lsb, 16);
    return push_frame(out, cap, 0x04, 0x04, 0x04, seq, b, 48);
}

size_t oizys_hdcp_stream_manage(uint8_t *out, size_t cap, uint32_t hdcp_seq, uint32_t seq) {
    uint8_t b[48];
    hdcp_body(b, 48, 0x002d, hdcp_seq, 0x10, NULL, 0);
    b[32] = 0x02;
    b[36] = 0x04;
    b[43] = 0x05;
    return push_frame(out, cap, 0x04, 0x04, 0x01, seq, b, 48);
}

size_t oizys_dl3_set_mode_1080p60(uint8_t *out, size_t cap, uint16_t counter, uint8_t head) {
    uint8_t b[80];
    memset(b, 0, sizeof(b));
    uint16_t id = 0x48, sub = 0x22;
    memcpy(b + 0, &id, 2);
    memcpy(b + 2, &sub, 2);
    memcpy(b + 4, &counter, 2);
    /* off22 is not the head. off23 selects the head, and every set-mode the vendor has been
     * observed sending carries off22=1 — its capture only ever had one monitor, on the second
     * socket, so off22=0 has never appeared on the wire and was our inference, not a reading.
     * Sending 0 made the dock compute head 0's geometry at 23040 against head 1's 17280, a
     * ratio of exactly 4/3, after which it skipped the final buffer setup and fell back. Head 1
     * has always sent 1 here and has always rendered cleanly. */
    b[22] = 1;
    /* off23 is the one-based head number, the same convention the per-head setup burst
     * uses. Pinning it to 2 aimed every set-mode at the second head: head 0 was never
     * programmed at all, and head 1 was programmed twice under two stream indices. */
    b[23] = (uint8_t)(head + 1);
    uint16_t hactive = 1920, hblank = 280, hfront = 88, hsync = 44;
    uint16_t vactive = 1080, vblank = 45, vfront = 4, vsync = 5;
    uint16_t flags = 0x0400;
    uint16_t refresh = 60;
    uint16_t stride = 0x4000;
    uint16_t rows = 0x6000;
    uint16_t words[] = {hactive, hblank,  hfront, hsync, vactive, vblank,
                        vfront,  vsync,   flags,  refresh, stride, rows};
    memcpy(b + 26, words, sizeof(words));
    uint16_t c80 = 0x0080, cff = 0x00ff;
    memcpy(b + 58, &c80, 2);
    memcpy(b + 60, &cff, 2);
    uint16_t vic = 0x2810; /* aspect 16:9 | VIC 16 */
    memcpy(b + 66, &vic, 2);
    uint16_t depth = 0x0200;
    memcpy(b + 68, &depth, 2);
    uint32_t clock = 14850;
    memcpy(b + 70, &clock, 4);
    oizys_hdcp_random(b + 74, 6);
    if (sizeof(b) > cap) {
        return 0;
    }
    memcpy(out, b, sizeof(b));
    return sizeof(b);
}

static uint16_t aux_for_id(uint16_t id) {
    switch (id) {
    case 0x14:
        return 0x0a;
    case 0x15:
        return 0x09;
    case 0x16:
        return 0x08;
    case 0x48:
        return 0x06;
    default:
        return 0;
    }
}

size_t oizys_dl3_seal_cp(uint8_t *out, size_t cap, const uint8_t ks[16], const uint8_t riv[8],
                         uint16_t inner_id, uint32_t wire_seq, const uint8_t *inner,
                         size_t inner_len) {
    uint8_t key[16];
    oizys_cp_session_key(ks, key);
    return oizys_dl3_seal_live(out, cap, key, riv, 0x24, aux_for_id(inner_id), wire_seq, inner,
                               inner_len);
}

size_t oizys_dl3_seal_live(uint8_t *out, size_t cap, const uint8_t live_key[16],
                           const uint8_t riv[8], uint16_t wire_sub, uint16_t aux,
                           uint32_t wire_seq, const uint8_t *plain, size_t plain_len) {
    size_t body_len = plain_len + 16;
    size_t total = 16 + body_len;
    if (total > cap) {
        return 0;
    }
    oizys_dl3_header(out, 4, wire_sub, aux, wire_seq, body_len);
    uint8_t *ct = out + 16;
    oizys_aes_ctr_xor(live_key, riv, wire_seq, plain, ct, plain_len);
    uint8_t mac_nonce[8];
    memcpy(mac_nonce, riv, 8);
    mac_nonce[0] ^= 0x80;
    uint8_t macbuf[8 + 8 + 4096];
    if (plain_len > 4096) {
        return 0;
    }
    memcpy(macbuf, mac_nonce, 8);
    uint64_t seq64 = wire_seq;
    for (int i = 0; i < 8; i++) {
        macbuf[8 + i] = (uint8_t)(seq64 >> (56 - 8 * i));
    }
    memcpy(macbuf + 16, ct, plain_len);
    oizys_aes_cmac(live_key, macbuf, 16 + plain_len, ct + plain_len);
    return total;
}

int oizys_dl3_open_cp(const uint8_t ks[16], const uint8_t in_riv[8], uint32_t seq,
                      const uint8_t *body, size_t body_len, uint8_t *pt, size_t pt_cap) {
    if (body_len < 16 || body_len - 16 > pt_cap) {
        return -1;
    }
    uint8_t key[16];
    memcpy(key, ks, 16);
    for (int i = 0; i < 16; i++) {
        key[i] ^= CP_KEY_WHITEN[i];
    }
    size_t ct_len = body_len - 16;
    uint8_t mac_nonce[8];
    memcpy(mac_nonce, in_riv, 8);
    mac_nonce[0] ^= 0x80;
    uint8_t macbuf[8 + 8 + 4096];
    if (ct_len > 4096) {
        return -1;
    }
    memcpy(macbuf, mac_nonce, 8);
    uint64_t seq64 = seq;
    for (int i = 0; i < 8; i++) {
        macbuf[8 + i] = (uint8_t)(seq64 >> (56 - 8 * i));
    }
    memcpy(macbuf + 16, body, ct_len);
    uint8_t tag[16];
    oizys_aes_cmac(key, macbuf, 16 + ct_len, tag);
    uint8_t diff = 0;
    for (int i = 0; i < 16; i++) {
        diff |= tag[i] ^ body[ct_len + i];
    }
    if (diff) {
        return -1;
    }
    oizys_aes_ctr_xor(key, in_riv, seq, body, pt, ct_len);
    return (int)ct_len;
}

