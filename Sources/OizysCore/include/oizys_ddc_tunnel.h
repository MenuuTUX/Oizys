#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * DDC/CI over the dock, for monitors with no display pipe.
 *
 * oizys_ddc_* speaks to a monitor over the I2C channel of a real GPU output. A head driven
 * over the dock has no such output, so that path cannot reach the two panels this driver
 * actually lights. The dock can: it already performs I2C to those monitors every session,
 * because that is how it reads their EDID.
 *
 * This file is the protocol half, and it is complete and tested. DDC/CI is a published
 * standard (VESA MCCS): a message to 0x37 carrying a length byte, a payload, and a checksum
 * xored with the source address. Everything about framing, parsing and validating those
 * messages is here and provable without any hardware.
 *
 * What is not here is the dock's opcode for "perform this I2C transaction". The EDID path
 * uses a dedicated read-EDID command whose only parameter is the DDC selector -- there is no
 * address field in it -- so the generic transaction is a different message, and its id and
 * sub are not published anywhere this project is allowed to look. `oizys_ddc_tunnel_send` is
 * therefore a function pointer, empty until something installs one. `oizys ddc tunnel-probe`
 * is the safe, read-only experiment that finds it against live hardware.
 *
 * Until that is installed, oizys_ddc_tunnel_available() is 0 and the menu says DDC is not
 * reachable on a dock head, which is the truth rather than a button that does nothing.
 */

#define OIZYS_DDC_ADDRESS 0x37       /* 7-bit I2C address of the DDC/CI port */
#define OIZYS_DDC_HOST_ADDRESS 0x51  /* what a host calls itself in the checksum */
#define OIZYS_DDC_MAX_PAYLOAD 32

/* MCCS opcodes carried inside a DDC/CI message. */
#define OIZYS_DDC_OP_GET 0x01
#define OIZYS_DDC_OP_GET_REPLY 0x02
#define OIZYS_DDC_OP_SET 0x03
#define OIZYS_DDC_OP_SAVE 0x0c

/*
 * One I2C transaction, as the dock would perform it: write `write_len` bytes to `address`,
 * then read `read_len` bytes back. Returns 0 on success. `selector` is the dock's logical
 * DDC selector for the head, the same value the EDID path uses.
 *
 * Returning -1 means the transaction did not happen; returning 0 with fewer bytes than asked
 * is a monitor that did not answer, which is normal and retried by the layer above.
 */
typedef int (*OizysDDCTunnelFn)(void *context, uint8_t selector, uint8_t address,
                                const uint8_t *write, size_t write_len,
                                uint8_t *read, size_t read_len);

/* Install the transport. Passing NULL removes it and makes the tunnel unavailable again. */
void oizys_ddc_tunnel_install(OizysDDCTunnelFn transport, void *context);

/* Non-zero once a transport is installed. */
int oizys_ddc_tunnel_available(void);

/*
 * Frame an MCCS payload as a DDC/CI message: destination-implied length byte with its high
 * bit set, the payload, then a checksum over the whole exchange including the addresses.
 * Returns the framed length, or 0 when it will not fit.
 */
size_t oizys_ddc_frame(uint8_t *out, size_t capacity, const uint8_t *payload, size_t length);

/*
 * The checksum a DDC/CI message carries: an xor over the destination address, the source
 * address, and every byte of the frame before the checksum itself.
 */
uint8_t oizys_ddc_checksum(uint8_t destination, uint8_t source, const uint8_t *bytes,
                           size_t length);

/*
 * Parse a monitor's reply to a VCP read. Returns 0 and fills `current` and `maximum` when
 * the reply is a well-formed, checksum-valid answer for `code`; -1 otherwise. A reply for a
 * different code is rejected rather than returned, because a monitor that lags a request by
 * one would otherwise report the previous feature's value as this one's.
 */
int oizys_ddc_parse_get_reply(const uint8_t *bytes, size_t length, uint8_t code,
                              uint16_t *current, uint16_t *maximum);

/* Read a VCP feature through the tunnel. Returns 0 on success. Retries: this channel is
 * specified to be lossy and a single failure means nothing. */
int oizys_ddc_tunnel_get(uint8_t selector, uint8_t code, uint16_t *current, uint16_t *maximum);

/* Write a VCP feature through the tunnel. Returns 0 on success. */
int oizys_ddc_tunnel_set(uint8_t selector, uint8_t code, uint16_t value);

/* Asserts over framing, checksums and reply parsing. Returns the number of failed checks. */
int oizys_ddc_tunnel_selftest(void);

#ifdef __cplusplus
}
#endif
