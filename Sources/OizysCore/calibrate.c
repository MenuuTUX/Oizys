#include "oizys_calibrate.h"
#include "oizys_config.h"

#include <stdlib.h>

#include <math.h>
#include <string.h>

/* Below this an input carries no usable signal: the camera's noise floor and the panel's
 * own black level dominate, and log space amplifies both. */
#define CAL_FLOOR 0.02

OizysCalibration oizys_calibration_identity(void) {
    OizysCalibration identity;
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        identity.gain[channel] = 1.0;
        identity.exponent[channel] = 1.0;
    }
    identity.valid = 1;
    return identity;
}

int oizys_calibration_fit(const OizysPatch *patches, int count, OizysResponse *out) {
    if (!patches || !out || count < OIZYS_CAL_MIN_PATCHES || count > OIZYS_CAL_MAX_PATCHES) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        /*
         * measured = scale * input^exponent
         *   =>  log(measured) = log(scale) + exponent * log(input)
         * which is a straight line, so the fit is an ordinary least-squares slope and
         * intercept. No solver, no iteration, no library.
         */
        double sum_x = 0, sum_y = 0, sum_xx = 0, sum_xy = 0;
        int used = 0;
        for (int i = 0; i < count; i++) {
            double input = patches[i].input, measured = patches[i].measured[channel];
            if (input < CAL_FLOOR || measured < CAL_FLOOR || input > 1.0 || measured > 1.0) {
                continue;
            }
            double x = log(input), y = log(measured);
            sum_x += x; sum_y += y; sum_xx += x * x; sum_xy += x * y;
            used++;
        }
        if (used < OIZYS_CAL_MIN_PATCHES) {
            return -1;
        }
        double denominator = (double)used * sum_xx - sum_x * sum_x;
        if (fabs(denominator) < 1e-12) {
            /* Every usable patch was at the same level, so the ramp has no slope to fit. */
            return -1;
        }
        double exponent = ((double)used * sum_xy - sum_x * sum_y) / denominator;
        double intercept = (sum_y - exponent * sum_x) / (double)used;
        if (!isfinite(exponent) || !isfinite(intercept) || exponent <= 0.05 || exponent > 6.0) {
            return -1;
        }
        out->exponent[channel] = exponent;
        out->scale[channel] = exp(intercept);
    }
    out->valid = 1;
    return 0;
}

int oizys_calibration_solve(const OizysResponse *display, const OizysResponse *reference,
                            OizysCalibration *out) {
    if (!display || !reference || !out || !display->valid || !reference->valid) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        double scale = display->scale[channel], exponent = display->exponent[channel];
        double target_scale = reference->scale[channel];
        double target_exponent = reference->exponent[channel];
        if (scale <= 0 || exponent <= 0 || target_scale <= 0 || target_exponent <= 0) {
            return -1;
        }
        /*
         * Want: scale * (gain * x^e)^exponent == target_scale * x^target_exponent
         * Matching the exponent of x gives  e = target_exponent / exponent,
         * and matching the constant gives   gain = (target_scale / scale)^(1/exponent).
         */
        double gain = pow(target_scale / scale, 1.0 / exponent);
        double power = target_exponent / exponent;
        if (!isfinite(gain) || !isfinite(power)) {
            return -1;
        }
        /* A panel cannot be driven brighter than its own white; asking clips instead of
         * matching. Matching therefore only ever darkens. */
        out->gain[channel] = gain > 1.0 ? 1.0 : gain;
        out->exponent[channel] = power;
    }
    out->valid = 1;
    return 0;
}

static double corrected(const OizysCalibration *calibration, int channel, double value) {
    if (value <= 0) {
        return 0;
    }
    double out = calibration->gain[channel] * pow(value, calibration->exponent[channel]);
    return out < 0 ? 0 : out > 1 ? 1 : out;
}

void oizys_calibration_apply(const OizysCalibration *calibration, uint8_t rgb[3]) {
    if (!calibration || !calibration->valid || !rgb) {
        return;
    }
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        double value = corrected(calibration, channel, (double)rgb[channel] / 255.0);
        rgb[channel] = (uint8_t)lround(value * 255.0);
    }
}

void oizys_calibration_table(const OizysCalibration *calibration,
                             uint8_t table[OIZYS_CAL_CHANNELS][256]) {
    if (!table) {
        return;
    }
    OizysCalibration identity = oizys_calibration_identity();
    const OizysCalibration *use = (calibration && calibration->valid) ? calibration : &identity;
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        for (int level = 0; level < 256; level++) {
            double value = corrected(use, channel, (double)level / 255.0);
            table[channel][level] = (uint8_t)lround(value * 255.0);
        }
    }
}

void oizys_calibration_print(const OizysCalibration *calibration, FILE *out) {
    static const char *const NAME[OIZYS_CAL_CHANNELS] = {"red", "green", "blue"};
    if (!calibration || !calibration->valid) {
        fputs("no calibration; displays are driven uncorrected\n", out);
        return;
    }
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        fprintf(out, "  %-6s gain %.4f  exponent %.4f\n", NAME[channel],
                calibration->gain[channel], calibration->exponent[channel]);
    }
}

/* -- storage -------------------------------------------------------------------------- */

/*
 * Stored beside the driver's settings and read through the same bridge, because C here has
 * no JSON parser and adding one to persist twelve numbers would be the wrong trade. The keys
 * are flat for the same reason the settings are: this file is meant to be readable, and a
 * correction that cannot be inspected is a correction nobody will trust.
 */
extern void oizys_settings_read(const char *path, void *context,
                                void (*apply)(void *, const char *, const char *));
extern int oizys_settings_write(const char *path, const char *key, const char *value, int type);
extern int oizys_settings_reset(const char *path);

static char g_path[1024];

const char *oizys_calibration_path(void) {
    if (!g_path[0]) {
        const char *config = oizys_config_path();
        size_t length = strlen(config);
        /* Same directory, different file. The config path always ends in a file name. */
        const char *slash = strrchr(config, '/');
        size_t prefix = slash ? (size_t)(slash - config + 1) : 0;
        if (prefix + 20 < sizeof(g_path) && prefix < length) {
            memcpy(g_path, config, prefix);
            snprintf(g_path + prefix, sizeof(g_path) - prefix, "calibration.json");
        } else {
            snprintf(g_path, sizeof(g_path), "calibration.json");
        }
    }
    return g_path;
}

static const char *const CHANNEL[OIZYS_CAL_CHANNELS] = {"r", "g", "b"};

typedef struct {
    int head;
    OizysCalibration *out;
    int found;
} LoadContext;

static void load_value(void *raw, const char *key, const char *value) {
    LoadContext *context = raw;
    char wanted[64];
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        snprintf(wanted, sizeof(wanted), "head.%d.%s.gain", context->head, CHANNEL[channel]);
        if (strcmp(key, wanted) == 0) {
            context->out->gain[channel] = atof(value);
            context->found++;
            return;
        }
        snprintf(wanted, sizeof(wanted), "head.%d.%s.exponent", context->head, CHANNEL[channel]);
        if (strcmp(key, wanted) == 0) {
            context->out->exponent[channel] = atof(value);
            context->found++;
            return;
        }
    }
}

int oizys_calibration_load(int head, OizysCalibration *out) {
    if (!out || head < 0 || head > 1) {
        return -1;
    }
    *out = oizys_calibration_identity();
    LoadContext context = {head, out, 0};
    oizys_settings_read(oizys_calibration_path(), &context, load_value);
    /* All six or none. A half-written correction would tint the panel it was meant to fix. */
    if (context.found != OIZYS_CAL_CHANNELS * 2) {
        *out = oizys_calibration_identity();
        return -1;
    }
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        if (!(out->gain[channel] > 0) || out->gain[channel] > 1.0 ||
            !(out->exponent[channel] > 0) || out->exponent[channel] > 6.0) {
            *out = oizys_calibration_identity();
            return -1;
        }
    }
    out->valid = 1;
    return 0;
}

int oizys_calibration_store(int head, const OizysCalibration *calibration) {
    if (head < 0 || head > 1) {
        return -1;
    }
    char key[64], value[64];
    for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
        double gain = calibration ? calibration->gain[channel] : 1.0;
        double exponent = calibration ? calibration->exponent[channel] : 1.0;
        snprintf(key, sizeof(key), "head.%d.%s.gain", head, CHANNEL[channel]);
        snprintf(value, sizeof(value), "%.6f", gain);
        if (oizys_settings_write(oizys_calibration_path(), key, value, 1) != 0) {
            return -1;
        }
        snprintf(key, sizeof(key), "head.%d.%s.exponent", head, CHANNEL[channel]);
        snprintf(value, sizeof(value), "%.6f", exponent);
        if (oizys_settings_write(oizys_calibration_path(), key, value, 1) != 0) {
            return -1;
        }
    }
    return 0;
}

/* -- solving a captured session -------------------------------------------------------- */

/*
 * The readings file is written by the capture page and read here rather than in Swift,
 * because the fit and the solve live in this file and shipping the numbers across the
 * process boundary twice would put the arithmetic somewhere it cannot be tested.
 *
 * Its shape is deliberately flat, one key per measurement, so the same settings bridge that
 * reads the config reads this too:
 *
 *   display.<n>.patch.<k>.input      the level that was displayed
 *   display.<n>.patch.<k>.r|g|b      what the camera reported
 *   reference                        which display everything is matched onto
 *   display.<n>.head                 which head this display is, -1 for none
 */
#define CAL_MAX_DISPLAYS 8

typedef struct {
    OizysPatch patch[OIZYS_CAL_MAX_PATCHES];
    int patches;
    int head;
} CalDisplay;

typedef struct {
    CalDisplay display[CAL_MAX_DISPLAYS];
    int reference;
} CalSession;

static void session_value(void *raw, const char *key, const char *value) {
    CalSession *session = raw;
    int index = 0, patch = 0;
    char field[16] = {0};
    if (strcmp(key, "reference") == 0) {
        session->reference = atoi(value);
        return;
    }
    /*
     * sscanf reports how many items it assigned, not whether the format matched to the end,
     * so "display.0.patch.0.input" satisfies "display.%d.head" with a count of one and would
     * be filed as a head. %n records how far it actually got, and only a match that consumed
     * the whole key is a match.
     */
    int consumed = 0;
    if (sscanf(key, "display.%d.head%n", &index, &consumed) == 1 &&
        consumed == (int)strlen(key)) {
        if (index >= 0 && index < CAL_MAX_DISPLAYS) {
            session->display[index].head = atoi(value);
        }
        return;
    }
    consumed = 0;
    if (sscanf(key, "display.%d.patch.%d.%15[rgbinput]%n", &index, &patch, field, &consumed) != 3 ||
        consumed != (int)strlen(key)) {
        return;
    }
    if (index < 0 || index >= CAL_MAX_DISPLAYS || patch < 0 || patch >= OIZYS_CAL_MAX_PATCHES) {
        return;
    }
    CalDisplay *display = &session->display[index];
    if (patch + 1 > display->patches) {
        display->patches = patch + 1;
    }
    double number = atof(value);
    if (strcmp(field, "input") == 0) {
        display->patch[patch].input = number;
    } else if (strcmp(field, "r") == 0) {
        display->patch[patch].measured[0] = number;
    } else if (strcmp(field, "g") == 0) {
        display->patch[patch].measured[1] = number;
    } else if (strcmp(field, "b") == 0) {
        display->patch[patch].measured[2] = number;
    }
}

int oizys_calibration_run(const char *path, FILE *out) {
    if (!path || !out) {
        return -1;
    }
    CalSession session;
    memset(&session, 0, sizeof(session));
    session.reference = -1;
    for (int i = 0; i < CAL_MAX_DISPLAYS; i++) {
        session.display[i].head = -1;
    }
    oizys_settings_read(path, &session, session_value);

    OizysResponse fitted[CAL_MAX_DISPLAYS];
    int usable = 0;
    for (int i = 0; i < CAL_MAX_DISPLAYS; i++) {
        memset(&fitted[i], 0, sizeof(fitted[i]));
        if (session.display[i].patches >= OIZYS_CAL_MIN_PATCHES &&
            oizys_calibration_fit(session.display[i].patch, session.display[i].patches,
                                  &fitted[i]) == 0) {
            usable++;
        }
    }
    if (usable < 2) {
        fputs("Fewer than two displays were measured well enough to match. Re-run the "
              "capture, keeping the phone still and the patch filling the frame.\n", out);
        return -1;
    }

    /*
     * The reference must be the dimmest display of the set. Matching can only darken -- a
     * panel cannot be driven above its own white -- so choosing a bright one would pull
     * everything else down to meet it and lose the brightness of the whole desk.
     */
    int reference = session.reference;
    if (reference < 0 || reference >= CAL_MAX_DISPLAYS || !fitted[reference].valid) {
        reference = -1;
        double dimmest = 1e9;
        for (int i = 0; i < CAL_MAX_DISPLAYS; i++) {
            if (!fitted[i].valid) {
                continue;
            }
            double white = (fitted[i].scale[0] + fitted[i].scale[1] + fitted[i].scale[2]) / 3.0;
            if (white < dimmest) {
                dimmest = white;
                reference = i;
            }
        }
    }
    if (reference < 0) {
        fputs("No usable reference display.\n", out);
        return -1;
    }
    fprintf(out, "Matching onto display %d.\n", reference);

    int stored = 0;
    for (int i = 0; i < CAL_MAX_DISPLAYS; i++) {
        if (!fitted[i].valid || session.display[i].head < 0 || session.display[i].head > 1) {
            continue;
        }
        OizysCalibration correction;
        if (oizys_calibration_solve(&fitted[i], &fitted[reference], &correction) != 0) {
            fprintf(out, "Display %d could not be solved; left uncorrected.\n", i);
            continue;
        }
        if (oizys_calibration_store(session.display[i].head, &correction) != 0) {
            fprintf(out, "Could not save the correction for head %d.\n", session.display[i].head);
            return -1;
        }
        fprintf(out, "Head %d:\n", session.display[i].head);
        oizys_calibration_print(&correction, out);
        stored++;
    }
    if (!stored) {
        fputs("No Oizys head was among the measured displays, so nothing was stored. Only "
              "heads Oizys drives can be corrected this way.\n", out);
        return -1;
    }
    fputs("\nA running driver picks this up within a second.\n", out);
    return 0;
}

/* -- self test ------------------------------------------------------------------------ */

static int g_failures;
#define CHECK(condition)                                                           \
    do {                                                                           \
        if (!(condition)) {                                                        \
            g_failures++;                                                          \
            fprintf(stderr, "calibrate selftest: %s:%d %s\n", __FILE__, __LINE__,   \
                    #condition);                                                   \
        }                                                                          \
    } while (0)

/* Synthesise what a camera would report from a display with a known response, so the fit
 * can be checked against the answer it is supposed to recover. */
static void synthesise(OizysPatch *patches, int count, const double *scale,
                       const double *exponent) {
    for (int i = 0; i < count; i++) {
        patches[i].input = (double)(i + 1) / (double)count;
        for (int channel = 0; channel < OIZYS_CAL_CHANNELS; channel++) {
            patches[i].measured[channel] = scale[channel] * pow(patches[i].input, exponent[channel]);
        }
    }
}

int oizys_calibration_selftest(void) {
    g_failures = 0;
    OizysPatch patches[8];
    OizysResponse fitted;

    /* The fit recovers the response it was generated from. */
    const double scale[3] = {0.92, 1.00, 0.81};
    const double exponent[3] = {2.20, 2.20, 2.35};
    synthesise(patches, 8, scale, exponent);
    CHECK(oizys_calibration_fit(patches, 8, &fitted) == 0);
    for (int channel = 0; channel < 3; channel++) {
        CHECK(fabs(fitted.scale[channel] - scale[channel]) < 1e-6);
        CHECK(fabs(fitted.exponent[channel] - exponent[channel]) < 1e-6);
    }

    /* Too few patches is refused rather than fitted through noise. */
    CHECK(oizys_calibration_fit(patches, 2, &fitted) == -1);

    /* Correcting a display onto itself is a no-op to within rounding. */
    OizysResponse self;
    CHECK(oizys_calibration_fit(patches, 8, &self) == 0);
    OizysCalibration same;
    CHECK(oizys_calibration_solve(&self, &self, &same) == 0);
    for (int channel = 0; channel < 3; channel++) {
        CHECK(fabs(same.gain[channel] - 1.0) < 1e-9);
        CHECK(fabs(same.exponent[channel] - 1.0) < 1e-9);
    }

    /* Correcting a blue-heavy display onto a neutral one pulls blue down and leaves the
     * channel that already matches alone. This is the whole point of the exercise. */
    const double blue_scale[3] = {0.90, 0.90, 1.00};
    const double neutral_scale[3] = {0.90, 0.90, 0.90};
    const double flat[3] = {2.20, 2.20, 2.20};
    OizysPatch cool[8], neutral[8];
    synthesise(cool, 8, blue_scale, flat);
    synthesise(neutral, 8, neutral_scale, flat);
    OizysResponse cool_fit, neutral_fit;
    OizysCalibration fix;
    CHECK(oizys_calibration_fit(cool, 8, &cool_fit) == 0);
    CHECK(oizys_calibration_fit(neutral, 8, &neutral_fit) == 0);
    CHECK(oizys_calibration_solve(&cool_fit, &neutral_fit, &fix) == 0);
    CHECK(fix.gain[2] < 0.99);
    CHECK(fabs(fix.gain[0] - 1.0) < 1e-6 && fabs(fix.gain[1] - 1.0) < 1e-6);

    /* And the corrected display then measures like the reference. */
    for (int i = 1; i < 8; i++) {
        double input = (double)(i + 1) / 8.0;
        double driven = fix.gain[2] * pow(input, fix.exponent[2]);
        double result = cool_fit.scale[2] * pow(driven, cool_fit.exponent[2]);
        double wanted = neutral_fit.scale[2] * pow(input, neutral_fit.exponent[2]);
        CHECK(fabs(result - wanted) < 1e-6);
    }

    /* Gain never exceeds 1: a dim panel cannot be matched up to a bright one. */
    OizysPatch dim[8], bright[8];
    const double dim_scale[3] = {0.50, 0.50, 0.50};
    const double bright_scale[3] = {1.00, 1.00, 1.00};
    synthesise(dim, 8, dim_scale, flat);
    synthesise(bright, 8, bright_scale, flat);
    OizysResponse dim_fit, bright_fit;
    OizysCalibration raise;
    CHECK(oizys_calibration_fit(dim, 8, &dim_fit) == 0);
    CHECK(oizys_calibration_fit(bright, 8, &bright_fit) == 0);
    CHECK(oizys_calibration_solve(&dim_fit, &bright_fit, &raise) == 0);
    for (int channel = 0; channel < 3; channel++) {
        CHECK(raise.gain[channel] <= 1.0);
    }

    /* Identity leaves pixels alone; the table agrees with the scalar path. */
    OizysCalibration identity = oizys_calibration_identity();
    uint8_t pixel[3] = {17, 128, 240};
    oizys_calibration_apply(&identity, pixel);
    CHECK(pixel[0] == 17 && pixel[1] == 128 && pixel[2] == 240);

    uint8_t table[OIZYS_CAL_CHANNELS][256];
    oizys_calibration_table(&fix, table);
    uint8_t probe[3] = {200, 200, 200};
    uint8_t expected[3] = {table[0][200], table[1][200], table[2][200]};
    oizys_calibration_apply(&fix, probe);
    CHECK(probe[0] == expected[0] && probe[1] == expected[1] && probe[2] == expected[2]);

    /* An invalid calibration falls back to pass-through rather than to zero. */
    OizysCalibration broken;
    memset(&broken, 0, sizeof(broken));
    oizys_calibration_table(&broken, table);
    CHECK(table[0][200] == 200 && table[2][17] == 17);

    return g_failures;
}
