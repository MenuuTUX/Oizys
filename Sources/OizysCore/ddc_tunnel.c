#include "oizys_ddc_tunnel.h"

#include <string.h>
#include <unistd.h>

static OizysDDCTunnelFn g_transport;
static void *g_context;

void oizys_ddc_tunnel_install(OizysDDCTunnelFn transport, void *context) {
    g_transport = transport;
    g_context = context;
}

int oizys_ddc_tunnel_available(void) {
    return g_transport != NULL;
}

uint8_t oizys_ddc_checksum(uint8_t destination, uint8_t source, const uint8_t *bytes,
                           size_t length) {
    uint8_t sum = (uint8_t)(destination ^ source);
    for (size_t i = 0; i < length; i++) {
        sum = (uint8_t)(sum ^ bytes[i]);
    }
    return sum;
}

size_t oizys_ddc_frame(uint8_t *out, size_t capacity, const uint8_t *payload, size_t length) {
    /* length byte + payload + checksum, and the length byte's high bit is always set. */
    if (!out || !payload || length == 0 || length > OIZYS_DDC_MAX_PAYLOAD ||
        capacity < length + 2) {
        return 0;
    }
    out[0] = (uint8_t)(0x80 | length);
    memcpy(out + 1, payload, length);
    /* The checksum covers the destination and source addresses as well as the frame. The
     * destination is the DDC port shifted into its 8-bit write form, which is what the
     * standard specifies and what monitors actually validate against. */
    out[length + 1] = oizys_ddc_checksum((uint8_t)(OIZYS_DDC_ADDRESS << 1),
                                         OIZYS_DDC_HOST_ADDRESS, out, length + 1);
    return length + 2;
}

int oizys_ddc_parse_get_reply(const uint8_t *bytes, size_t length, uint8_t code,
                              uint16_t *current, uint16_t *maximum) {
    /*
     * A well-formed reply is:
     *   [0] source address, echoed
     *   [1] 0x80 | payload length, and the payload is always 8 for a VCP read
     *   [2] 0x02, the get-reply opcode
     *   [3] result: 0 is success, 1 is "unsupported feature"
     *   [4] the VCP code being answered
     *   [5] type
     *   [6..7] maximum, big endian
     *   [8..9] current, big endian
     *   [10] checksum
     */
    if (!bytes || length < 11 || !current || !maximum) {
        return -1;
    }
    if ((bytes[1] & 0x7f) != 8 || !(bytes[1] & 0x80) || bytes[2] != OIZYS_DDC_OP_GET_REPLY) {
        return -1;
    }
    if (bytes[3] != 0x00) {
        return -1;  /* the monitor answered, and the answer is "I do not have that feature" */
    }
    /* A monitor that lags one request behind would otherwise report the previous feature's
     * value as this one's, which is worse than reporting nothing. */
    if (bytes[4] != code) {
        return -1;
    }
    uint8_t expected = oizys_ddc_checksum(OIZYS_DDC_HOST_ADDRESS,
                                          (uint8_t)(OIZYS_DDC_ADDRESS << 1), bytes, 10);
    if (bytes[10] != expected) {
        return -1;
    }
    *maximum = (uint16_t)((bytes[6] << 8) | bytes[7]);
    *current = (uint16_t)((bytes[8] << 8) | bytes[9]);
    return 0;
}

int oizys_ddc_tunnel_get(uint8_t selector, uint8_t code, uint16_t *current, uint16_t *maximum) {
    if (!g_transport || !current || !maximum) {
        return -1;
    }
    uint8_t payload[2] = {OIZYS_DDC_OP_GET, code};
    uint8_t frame[8];
    size_t framed = oizys_ddc_frame(frame, sizeof(frame), payload, sizeof(payload));
    if (!framed) {
        return -1;
    }
    /* DDC/CI is specified as a lossy channel and a single failure means nothing. The 40 ms
     * gap between a write and its read is the standard's own minimum for a get. */
    for (int attempt = 0; attempt < 4; attempt++) {
        uint8_t reply[16];
        memset(reply, 0, sizeof(reply));
        if (g_transport(g_context, selector, OIZYS_DDC_ADDRESS, frame, framed, NULL, 0) < 0) {
            usleep(50000);
            continue;
        }
        usleep(40000);
        if (g_transport(g_context, selector, OIZYS_DDC_ADDRESS, NULL, 0, reply, 11) < 0) {
            usleep(50000);
            continue;
        }
        if (oizys_ddc_parse_get_reply(reply, 11, code, current, maximum) == 0) {
            return 0;
        }
        usleep(50000);
    }
    return -1;
}

int oizys_ddc_tunnel_set(uint8_t selector, uint8_t code, uint16_t value) {
    if (!g_transport) {
        return -1;
    }
    uint8_t payload[4] = {OIZYS_DDC_OP_SET, code, (uint8_t)(value >> 8), (uint8_t)(value & 0xff)};
    uint8_t frame[8];
    size_t framed = oizys_ddc_frame(frame, sizeof(frame), payload, sizeof(payload));
    if (!framed) {
        return -1;
    }
    for (int attempt = 0; attempt < 3; attempt++) {
        if (g_transport(g_context, selector, OIZYS_DDC_ADDRESS, frame, framed, NULL, 0) == 0) {
            /* A set is not acknowledged. The standard's minimum settle before the next
             * message is 50 ms, and skipping it is how a burst of writes loses one. */
            usleep(50000);
            return 0;
        }
        usleep(50000);
    }
    return -1;
}

/* -- self test ------------------------------------------------------------------------ */

static int g_failures;
#define CHECK(condition)                                                          \
    do {                                                                          \
        if (!(condition)) {                                                       \
            g_failures++;                                                         \
            fprintf(stderr, "ddc tunnel selftest: %s:%d %s\n", __FILE__, __LINE__, \
                    #condition);                                                  \
        }                                                                         \
    } while (0)

/* A monitor that answers every read with the same feature, so the layer above can be driven
 * without hardware. Records what it was asked so the framing can be inspected. */
static struct {
    uint8_t last_write[16];
    size_t last_write_len;
    uint8_t code;
    uint16_t current, maximum;
    int fail_writes;
    int calls;
} g_fake;

static int fake_transport(void *context, uint8_t selector, uint8_t address,
                          const uint8_t *write, size_t write_len, uint8_t *read,
                          size_t read_len) {
    (void)context;
    (void)selector;
    g_fake.calls++;
    if (address != OIZYS_DDC_ADDRESS) {
        return -1;
    }
    if (write && write_len) {
        if (g_fake.fail_writes) {
            return -1;
        }
        memcpy(g_fake.last_write, write, write_len < 16 ? write_len : 16);
        g_fake.last_write_len = write_len;
        return 0;
    }
    if (read && read_len >= 11) {
        read[0] = OIZYS_DDC_HOST_ADDRESS;
        read[1] = 0x88;
        read[2] = OIZYS_DDC_OP_GET_REPLY;
        read[3] = 0x00;
        read[4] = g_fake.code;
        read[5] = 0x00;
        read[6] = (uint8_t)(g_fake.maximum >> 8);
        read[7] = (uint8_t)(g_fake.maximum & 0xff);
        read[8] = (uint8_t)(g_fake.current >> 8);
        read[9] = (uint8_t)(g_fake.current & 0xff);
        read[10] = oizys_ddc_checksum(OIZYS_DDC_HOST_ADDRESS,
                                      (uint8_t)(OIZYS_DDC_ADDRESS << 1), read, 10);
        return 0;
    }
    return -1;
}

int oizys_ddc_tunnel_selftest(void) {
    g_failures = 0;
    uint8_t frame[16];

    /* Framing: length byte carries the high bit, payload is copied, checksum closes it. */
    const uint8_t get_luminance[2] = {OIZYS_DDC_OP_GET, 0x10};
    size_t framed = oizys_ddc_frame(frame, sizeof(frame), get_luminance, 2);
    CHECK(framed == 4);
    CHECK(frame[0] == 0x82);
    CHECK(frame[1] == 0x01 && frame[2] == 0x10);
    CHECK(frame[3] == oizys_ddc_checksum(0x6e, OIZYS_DDC_HOST_ADDRESS, frame, 3));

    /* A frame that does not fit is refused rather than truncated. */
    CHECK(oizys_ddc_frame(frame, 3, get_luminance, 2) == 0);
    CHECK(oizys_ddc_frame(frame, sizeof(frame), get_luminance, 0) == 0);
    CHECK(oizys_ddc_frame(frame, sizeof(frame), get_luminance, OIZYS_DDC_MAX_PAYLOAD + 1) == 0);

    /* The tunnel is unavailable until a transport is installed. */
    oizys_ddc_tunnel_install(NULL, NULL);
    CHECK(oizys_ddc_tunnel_available() == 0);
    uint16_t current = 0, maximum = 0;
    CHECK(oizys_ddc_tunnel_get(1, 0x10, &current, &maximum) == -1);
    CHECK(oizys_ddc_tunnel_set(1, 0x10, 50) == -1);

    /* With one installed, a read round-trips through framing, transport and parsing. */
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.code = 0x10;
    g_fake.current = 47;
    g_fake.maximum = 100;
    oizys_ddc_tunnel_install(fake_transport, NULL);
    CHECK(oizys_ddc_tunnel_available() == 1);
    CHECK(oizys_ddc_tunnel_get(1, 0x10, &current, &maximum) == 0);
    CHECK(current == 47 && maximum == 100);
    CHECK(g_fake.last_write_len == 4 && g_fake.last_write[2] == 0x10);

    /* A monitor answering about a different feature is refused, not believed. */
    g_fake.code = 0x12;
    current = maximum = 0;
    CHECK(oizys_ddc_tunnel_get(1, 0x10, &current, &maximum) == -1);
    CHECK(current == 0 && maximum == 0);

    /* A write is framed with the value big-endian, and a transport that refuses is reported
     * rather than silently swallowed. */
    g_fake.code = 0x10;
    CHECK(oizys_ddc_tunnel_set(1, 0x10, 0x1234) == 0);
    CHECK(g_fake.last_write_len == 6);
    CHECK(g_fake.last_write[1] == OIZYS_DDC_OP_SET && g_fake.last_write[2] == 0x10);
    CHECK(g_fake.last_write[3] == 0x12 && g_fake.last_write[4] == 0x34);
    g_fake.fail_writes = 1;
    CHECK(oizys_ddc_tunnel_set(1, 0x10, 10) == -1);

    /* Reply validation: a bad checksum, a short frame and an unsupported feature all fail. */
    uint8_t reply[11] = {OIZYS_DDC_HOST_ADDRESS, 0x88, 0x02, 0x00, 0x10, 0x00,
                         0x00, 0x64, 0x00, 0x2f, 0x00};
    reply[10] = oizys_ddc_checksum(OIZYS_DDC_HOST_ADDRESS, 0x6e, reply, 10);
    CHECK(oizys_ddc_parse_get_reply(reply, 11, 0x10, &current, &maximum) == 0);
    CHECK(current == 0x2f && maximum == 0x64);
    reply[10] ^= 0xff;
    CHECK(oizys_ddc_parse_get_reply(reply, 11, 0x10, &current, &maximum) == -1);
    reply[10] ^= 0xff;
    CHECK(oizys_ddc_parse_get_reply(reply, 10, 0x10, &current, &maximum) == -1);
    reply[3] = 0x01;   /* unsupported feature */
    reply[10] = oizys_ddc_checksum(OIZYS_DDC_HOST_ADDRESS, 0x6e, reply, 10);
    CHECK(oizys_ddc_parse_get_reply(reply, 11, 0x10, &current, &maximum) == -1);

    oizys_ddc_tunnel_install(NULL, NULL);
    CHECK(oizys_ddc_tunnel_available() == 0);
    return g_failures;
}
