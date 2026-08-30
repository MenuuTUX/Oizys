/* Real process supervision with fake device/vendor discovery. Never touches USB or DLM. */
#include <libproc.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static size_t test_confstr(int name, char *buffer, size_t capacity) {
    (void)name;
    const char *directory = getenv("MVIEW_TEST_DIR");
    size_t size = strlen(directory) + 1;
    if (size <= capacity) memcpy(buffer, directory, size);
    return size;
}
static int test_proc_listallpids(void *buffer, int size) {
    if (!getenv("MVIEW_TEST_VENDOR")) return 0;
    if (buffer && size >= (int)sizeof(pid_t)) *(pid_t *)buffer = 1;
    return 1;
}
static int test_proc_name(int pid, void *buffer, uint32_t capacity) {
    (void)pid;
    const char *name = "DisplayLinkUserAgent";
    if (capacity <= strlen(name)) return 0;
    strcpy(buffer, name);
    return (int)strlen(name);
}
#define confstr test_confstr
#define proc_listallpids test_proc_listallpids
#define proc_name test_proc_name
#include "../../Sources/mview/supervisor.c"

int mview_usb_probe(MViewHub *hubs, int capacity) {
    (void)capacity;
    FILE *file = fopen(getenv("MVIEW_TEST_TOPOLOGY"), "r");
    int count = 0;
    if (file) { fscanf(file, "%d", &count); fclose(file); }
    memset(hubs, 0, sizeof(*hubs));
    hubs[0].pid = 0x6000;
    return count;
}
int mview_hub_is_dl3(const MViewHub *hub) { (void)hub; return 1; }
int mview_stop_displaylink(void) { puts("TEST vendor stop"); return 0; }
int mview_start_displaylink(void) { puts("TEST vendor restore"); return 0; }
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    return mview_supervise(argv[1], 0, 0) ? 0 : 1;
}
