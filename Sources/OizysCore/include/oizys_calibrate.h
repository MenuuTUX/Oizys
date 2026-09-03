#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Matching displays to each other from a phone camera.
 *
 * An iPhone camera is not a colorimeter: its pipeline applies auto-exposure, auto white
 * balance and tone mapping that a web page cannot turn off. Absolute colour from it is not
 * available and this file does not pretend otherwise. What a camera does measure reliably is
 * a *ratio* between two things in the same shot under the same settings, and that is enough
 * to answer the question people actually have: "why is the left monitor bluer than the right
 * one, and why does neither match the iPad".
 *
 * So the model is deliberately small. Per channel, a display is treated as
 *
 *     measured = scale * input ^ exponent                                (0 <= input <= 1)
 *
 * which is fitted from a neutral ramp by least squares in log-log space. Correcting one
 * display onto a reference is then closed-form in the same family, so the correction is six
 * numbers per display and nothing has to be inverted numerically.
 *
 * Six numbers will not reproduce a colorimeter, and no claim here is that they do. They fix
 * grey balance and gamma mismatch between panels, which is the visible fault.
 *
 * ponytail: gain and gamma per channel, no 3x3 mix. Add the matrix when a measurement shows
 * primaries crossing badly enough to see, which needs primary patches this does not collect.
 */

#define OIZYS_CAL_CHANNELS 3
#define OIZYS_CAL_MIN_PATCHES 4
#define OIZYS_CAL_MAX_PATCHES 32

/* One neutral patch: what was displayed, and what the camera reported back. Both are
 * normalised to 0..1, and both are linear, not sRGB-encoded -- the page linearises before
 * it sends, because fitting an exponent through an sRGB curve fits the wrong thing. */
typedef struct {
    double input;                        /* the level Oizys displayed */
    double measured[OIZYS_CAL_CHANNELS]; /* the camera's mean for that patch */
} OizysPatch;

/* A display's fitted response. */
typedef struct {
    double scale[OIZYS_CAL_CHANNELS];
    double exponent[OIZYS_CAL_CHANNELS];
    int valid;
} OizysResponse;

/* The correction to apply before encoding: output = gain * input ^ exponent. */
typedef struct {
    double gain[OIZYS_CAL_CHANNELS];
    double exponent[OIZYS_CAL_CHANNELS];
    int valid;
} OizysCalibration;

/* An uncorrected pass-through: gain 1, exponent 1. Always valid. */
OizysCalibration oizys_calibration_identity(void);

/*
 * Fit scale and exponent per channel from a neutral ramp, by least squares on
 * log(measured) against log(input). Patches at input 0 carry no information in log space and
 * are skipped, so a ramp needs OIZYS_CAL_MIN_PATCHES usable points above zero.
 * Returns 0 on success, -1 when there are too few usable patches.
 */
int oizys_calibration_fit(const OizysPatch *patches, int count, OizysResponse *out);

/*
 * The correction that makes `display` behave like `reference`.
 *
 * Composing gain*x^e with scale*x^exp stays in the same family, so this is exact rather than
 * iterative. Gain is clamped at 1: a panel cannot be driven above its own white, and asking
 * for it clips highlights instead of matching them. Matching therefore always darkens, which
 * is why the reference should be the dimmest display of the set.
 */
int oizys_calibration_solve(const OizysResponse *display, const OizysResponse *reference,
                            OizysCalibration *out);

/* Apply to one 8-bit pixel in place. Values are clamped to 0..255. */
void oizys_calibration_apply(const OizysCalibration *calibration, uint8_t rgb[3]);

/* Fill a 256-entry per-channel lookup table, for the encoder's hot path. */
void oizys_calibration_table(const OizysCalibration *calibration,
                             uint8_t table[OIZYS_CAL_CHANNELS][256]);

/* One line per channel, for `oizys calibrate show`. */
void oizys_calibration_print(const OizysCalibration *calibration, FILE *out);

/* Absolute path of the stored calibration, whether or not it exists. */
const char *oizys_calibration_path(void);

/* Load this head's stored correction. Returns 0 on success, -1 when none is stored. */
int oizys_calibration_load(int head, OizysCalibration *out);

/* Persist a head's correction. Passing NULL clears it. Returns 0 on success. */
int oizys_calibration_store(int head, const OizysCalibration *calibration);

/*
 * Fit every display in a readings file, solve each against the reference, and store the
 * results for the two heads. `path` is the JSON the capture page produced. Writes a summary
 * to `out`. Returns 0 on success.
 */
int oizys_calibration_run(const char *path, FILE *out);

/* Asserts over the fit, the solve and the clamp. Returns the number of failed checks. */
int oizys_calibration_selftest(void);

#ifdef __cplusplus
}
#endif
