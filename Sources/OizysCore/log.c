#define OIZYS_LOG_IMPLEMENTATION
#include "oizys_usb.h"

#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static FILE *g_log;

void oizys_log_open(const char *path) {
    if (g_log && g_log != stdout) {
        fclose(g_log);
    }
    // Stream to the debug UI. Only direct CLI sessions also need their own file.
    const char *stream = getenv("OIZYS_LOG_STDOUT");
    g_log = stream && strcmp(stream, "1") == 0 ? stdout : path ? fopen(path, "a") : stdout;
    if (g_log) {
        setvbuf(g_log, NULL, _IONBF, 0);
    }
}

void oizys_log(const char *fmt, ...) {
    if (!OIZYS_DIAGNOSTICS) return;
    FILE *f = g_log ? g_log : stdout;
    flockfile(f);
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    fprintf(f, "%02d:%02d:%02d ", tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    size_t n = strlen(fmt);
    if (n == 0 || fmt[n - 1] != '\n') {
        fputc('\n', f);
    }
    funlockfile(f);
}
