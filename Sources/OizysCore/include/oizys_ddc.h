#pragma once

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Standard MCCS feature codes this driver names. The manufacturer range 0xE0-0xFF is not
 * listed: Dell has declined to publish its own codes, so those are found by probing. */
#define OIZYS_VCP_RESTORE_FACTORY 0x04
#define OIZYS_VCP_RESTORE_LUMINANCE 0x05
#define OIZYS_VCP_RESTORE_COLOUR 0x08
#define OIZYS_VCP_LUMINANCE 0x10
#define OIZYS_VCP_CONTRAST 0x12
#define OIZYS_VCP_COLOUR_PRESET 0x14
#define OIZYS_VCP_GAIN_RED 0x16
#define OIZYS_VCP_GAIN_GREEN 0x18
#define OIZYS_VCP_GAIN_BLUE 0x1a
#define OIZYS_VCP_AUTO_SETUP 0x1e
#define OIZYS_VCP_INPUT_SOURCE 0x60
#define OIZYS_VCP_AUDIO_VOLUME 0x62
#define OIZYS_VCP_BLACK_RED 0x6c
#define OIZYS_VCP_BLACK_GREEN 0x6e
#define OIZYS_VCP_BLACK_BLUE 0x70
#define OIZYS_VCP_AUDIO_MUTE 0x8d
#define OIZYS_VCP_USAGE_HOURS 0xc0
#define OIZYS_VCP_CONTROLLER_TYPE 0xc8
#define OIZYS_VCP_FIRMWARE 0xc9
#define OIZYS_VCP_OSD_LOCK 0xca
#define OIZYS_VCP_OSD_LANGUAGE 0xcc
#define OIZYS_VCP_POWER_MODE 0xd6
#define OIZYS_VCP_VERSION 0xdf

/*
 * DDC/CI over the display's I2C channel. This reaches a monitor on a real display pipe --
 * DisplayPort, Thunderbolt DP Alt Mode -- and nothing else. A head driven over the dock has
 * no display pipe and therefore no DCPAVServiceProxy, so none of this applies to it; see
 * the Ridge tunnel for that side.
 */
typedef struct OizysDDCDisplay OizysDDCDisplay;

/* Open the DDC channel for a CGDirectDisplayID. NULL when the display has no I2C path. */
OizysDDCDisplay *oizys_ddc_open(uint32_t display_id);
void oizys_ddc_close(OizysDDCDisplay *display);

/*
 * The first external display uniquely matched to a native AV service by EDID. Returns
 * 0 when no match can be verified, including missing API support or ambiguous identities.
 */
uint32_t oizys_ddc_native_display_id(void);

/* Every online display and whether it has an I2C path, one per line. */
void oizys_ddc_list(FILE *out);

/*
 * Read a VCP feature. `current` and `maximum` are both 16-bit; a monitor reports the
 * maximum its own scale uses, which is not always 100. Returns 0 on success.
 * Reads over this channel fail intermittently by design of the hardware, so this retries.
 */
int oizys_ddc_get_vcp(OizysDDCDisplay *display, uint8_t code, uint16_t *current,
                      uint16_t *maximum);

/* Write a VCP feature. Returns 0 on success. */
int oizys_ddc_set_vcp(OizysDDCDisplay *display, uint8_t code, uint16_t value);

/*
 * The monitor's capabilities string, assembled from its 0xE3 fragments. This is the only
 * reliable answer to "what does this model's menu actually contain" -- codes it does not
 * list are not there, and codes with parenthesised values list their legal settings.
 */
int oizys_ddc_capabilities(OizysDDCDisplay *display, char *out, size_t capacity);

/* Human-readable name for a standard MCCS code, or NULL in the manufacturer range. */
const char *oizys_ddc_vcp_name(uint8_t code);

/* Read every standard code this display answers, one per line. */
void oizys_ddc_dump(OizysDDCDisplay *display, FILE *out);

#ifdef __cplusplus
}
#endif
