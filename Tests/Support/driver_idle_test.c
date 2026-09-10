/* Regression for content-aware idle detection. The unchanged-frame path must not
 * refresh last_change_ns, otherwise capture never reaches its low-rate target. */
#define OIZYS_LOG_IMPLEMENTATION
#include "../../Sources/OizysCore/driver.c"
#include <pthread.h>

static OizysConfig config;
const OizysConfig *oizys_config(void) { return &config; }

static void *exercise(void *raw) {
    OizysDriver *driver = raw;
    uint8_t *surface = calloc(1920 * 1080 * 4, 1);
    if (!surface) return (void *)4;
    if (present_bgra_mosaic(driver, 0, surface, 1920 * 4, 1920, 1080, NULL, 0) != 0) return (void *)4;
    if (driver->last_change_ns[0] != 1) return (void *)5;
    if (oizys_driver_capture_fps_target(driver) != 10) return (void *)6;
    free(surface);
    return 0;
}

int main(void) {
    OizysDriver *driver = calloc(1, sizeof(*driver));
    if (!driver) return 2;
    const OizysDL3Profile *profile = oizys_dl3_profile(0x6000);
    if (!profile) return 2;
    driver->profile = profile;
    driver->active[0] = 1;
    driver->gain_q8[0] = 256;
    driver->contrast_q8[0] = 256;
    oizys_damage_init(&driver->damage[0], 1920, 1080);
    int presentations = 0;
    uint8_t *surface = calloc(1920 * 1080 * 4, 1);
    OizysStrip *owed = malloc(sizeof(*owed) * OIZYS_MAX_STRIPS);
    if (!surface || !owed) return 2;
    if (oizys_damage_plan(&driver->damage[0], surface, 1920 * 4, owed,
                           OIZYS_MAX_STRIPS, &presentations) <= 0) return 3;
    oizys_damage_presented(&driver->damage[0]);
    driver->last_change_ns[0] = 1;
    config.power_saving = 1;
    config.capture_fps = 60;
    config.power_idle_fps = 10;
    config.power_idle_after_s = 1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, exercise, driver) != 0) return 4;
    void *result = NULL;
    pthread_join(thread, &result);
    if (result) return (int)(uintptr_t)result;
    free(owed);
    free(surface);
    free(driver);
    return 0;
}
