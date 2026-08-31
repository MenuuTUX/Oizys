#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Foundation file serialization only. Configuration validation remains C. */
void oizys_settings_read(const char *path, void *context,
                         void (*value)(void *, const char *, const char *));
int oizys_settings_write(const char *path, const char *key, const char *value, int type);
int oizys_settings_reset(const char *path);
#ifdef __cplusplus
}
#endif
