#include "supervisor.h"
#include "mview_usb.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* A separate C supervisor remains responsive even if an Apple framework call in
 * the worker stops returning. The worker owns all USB and capture state. */
#define WORKER_STATUS_FD 198
#define STARTUP_SECONDS 45
#define HEARTBEAT_SECONDS 15
#define STOP_SECONDS 10

static volatile sig_atomic_t stopping;
static void request_stop(int sig) { (void)sig; stopping = 1; }

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + now.tv_nsec / 1e9;
}

static void pause_briefly(void) {
    struct timespec delay = {0, 100000000};
    nanosleep(&delay, NULL);
}

static int displaylink_running(void) {
    int size = proc_listallpids(NULL, 0);
    if (size <= 0) return 0;
    pid_t *pids = calloc((size_t)size + 64, sizeof(*pids));
    if (!pids) return 0;
    int count = proc_listallpids(pids, (size + 64) * (int)sizeof(*pids));
    int found = 0;
    for (int i = 0; i < count; i++) {
        char name[PROC_PIDPATHINFO_MAXSIZE] = "";
        if (proc_name(pids[i], name, sizeof(name)) > 0 &&
            (strcmp(name, "DisplayLinkUserAgent") == 0 ||
             strcmp(name, "DisplayLink Manager") == 0)) found = 1;
    }
    free(pids);
    return found;
}

static int lock_supervisor(void) {
    char directory[1024], path[1200];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory));
    if (!length || length > sizeof(directory)) return -1;
    snprintf(path, sizeof(path), "%smview-driver.lock", directory);
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd);
        return -1;
    }
    // Do not unlink this inode on exit: another process may already have opened it.
    return fd;
}

static int supported_dock_present(void) {
    MViewHub hubs[MVIEW_MAX_HUBS];
    int count = mview_usb_probe(hubs, MVIEW_MAX_HUBS);
    // The transport currently selects one device. Never seize an ambiguous set.
    return count == 1 && hubs[0].pid == 0x6000 && mview_hub_is_dl3(&hubs[0]);
}

static pid_t start_worker(const char *executable, int profile, int stats, int *status_fd) {
    int channel[2];
    if (pipe(channel)) return -1;
    for (int i = 0; i < 2; i++) {
        if (channel[i] != WORKER_STATUS_FD) continue;
        int moved = fcntl(channel[i], F_DUPFD_CLOEXEC, WORKER_STATUS_FD + 1);
        if (moved < 0) { close(channel[0]); close(channel[1]); return -1; }
        close(channel[i]);
        channel[i] = moved;
    }
    fcntl(channel[0], F_SETFD, FD_CLOEXEC);
    fcntl(channel[1], F_SETFD, FD_CLOEXEC);
    fcntl(channel[0], F_SETFL, O_NONBLOCK);
    fcntl(channel[1], F_SETFL, O_NONBLOCK);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, channel[1], WORKER_STATUS_FD);
    posix_spawn_file_actions_addclose(&actions, channel[0]);
    posix_spawn_file_actions_addclose(&actions, channel[1]);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    // Terminal Ctrl-C belongs to the supervisor, which gives its worker time to stop.
    posix_spawnattr_setpgroup(&attributes, 0);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
                                           POSIX_SPAWN_SETSIGDEF);
    char command[] = "run", takeover[] = "--takeover", status_argument[] = "--worker-fd=198";
    char profile_argument[] = "--profile", stats_argument[] = "--stats", worker_argument[] = "--worker";
    char *arguments[] = {(char *)executable, command, takeover, status_argument,
                         profile ? profile_argument : stats ? stats_argument : worker_argument, NULL};
    pid_t child = -1;
    int error = posix_spawn(&child, executable, &actions, &attributes, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(channel[1]);
    if (error) {
        fprintf(stderr, "could not start MView worker: %s\n", strerror(error));
        close(channel[0]);
        return -1;
    }
    *status_fd = channel[0];
    return child;
}

static void stop_worker(pid_t child) {
    kill(child, SIGTERM);
    double deadline = monotonic_seconds() + STOP_SECONDS;
    for (;;) {
        pid_t result = waitpid(child, NULL, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        if (monotonic_seconds() >= deadline) break;
        pause_briefly();
    }
    fputs("worker did not stop in 10 seconds; terminating it\n", stderr);
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

int mview_supervise(const char *executable, int profile, int stats) {
    int lock = lock_supervisor();
    if (lock < 0) {
        fputs("another MView service is running, or its lock could not be acquired\n", stderr);
        return 0;
    }
    struct sigaction action = {0}, previous_int, previous_term;
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);
    stopping = 0;
    sigaction(SIGINT, &action, &previous_int);
    sigaction(SIGTERM, &action, &previous_term);
    int restore_vendor = displaylink_running();
    mview_stop_displaylink();
    puts("MView service started; failures will restart MView, not DisplayLink");
    int backoff = 1, waiting = 0, ok = 1;
    while (!stopping) {
        if (!supported_dock_present()) {
            if (!waiting) puts("waiting for one supported Ridge dock; Ctrl-C stops MView");
            waiting = 1;
            double deadline = monotonic_seconds() + 1;
            while (!stopping && monotonic_seconds() < deadline) pause_briefly();
            continue;
        }
        waiting = 0;
        int status_fd = -1;
        pid_t child = start_worker(executable, profile, stats, &status_fd);
        if (child < 0) { ok = 0; break; }
        printf("MView worker %d starting\n", child);
        double began = monotonic_seconds(), deadline = began + STARTUP_SECONDS, ready = 0;
        int reaped = 0;
        while (!stopping) {
            char status[64];
            if (read(status_fd, status, sizeof(status)) > 0) {
                double now = monotonic_seconds();
                if (!ready) {
                    ready = now;
                    printf("MView worker ready in %.1fs\n", now - began);
                }
                deadline = now + HEARTBEAT_SECONDS;
            }
            int exit_status;
            pid_t result = waitpid(child, &exit_status, WNOHANG);
            if (result == child || (result < 0 && errno == ECHILD)) {
                reaped = 1;
                puts("MView worker exited; releasing its session before retry");
                break;
            }
            if (monotonic_seconds() >= deadline) {
                fputs("MView worker stopped responding; restarting its session\n", stderr);
                break;
            }
            pause_briefly();
        }
        if (!reaped) stop_worker(child);
        close(status_fd);
        if (stopping) break;
        if (ready && monotonic_seconds() - ready >= 30) backoff = 1;
        printf("retrying MView in %ds\n", backoff);
        double retry = monotonic_seconds() + backoff;
        while (!stopping && monotonic_seconds() < retry) pause_briefly();
        if (backoff < 8) backoff *= 2;
    }
    if (restore_vendor) {
        mview_start_displaylink();
        puts("MView stopped; restored the DisplayLink session that preceded takeover");
    } else {
        puts("MView stopped; DisplayLink was not running and was not launched");
    }
    sigaction(SIGINT, &previous_int, NULL);
    sigaction(SIGTERM, &previous_term, NULL);
    close(lock);
    return ok;
}
