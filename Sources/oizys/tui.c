/*
 * Full-screen terminal UI.
 *
 * The whole thing renders into one buffer and goes out in a single write, because a screen
 * drawn cell by cell tears visibly on every resize. It runs on the alternate screen so the
 * user's scrollback survives, and every path that can leave the terminal in raw mode routes
 * through restore().
 */
#include "terminal.h"
#include "logo.h"
#include "oizys.h"

#include <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
extern int oizys_service_command(const char *action);

#define DIM     "\033[38;5;242m"
#define TEXT    "\033[38;5;252m"
#define ACCENT  "\033[38;5;81m"
#define GOOD    "\033[38;5;114m"
#define WARN    "\033[38;5;215m"
#define SELECT  "\033[48;5;24m\033[38;5;231m"
#define RESET   "\033[0m"

#define LOGO_W 46
#define MAX_LINES 400
#define LINE_CAP 240

/* ---------------------------------------------------------------- output buffer */

typedef struct {
    char *data;
    size_t len, cap;
} Buf;

static int buf_reserve(Buf *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return 0;
    size_t want = b->cap ? b->cap : 8192;
    while (want < b->len + extra + 1) want *= 2;
    char *grown = realloc(b->data, want);
    if (!grown) return -1;
    b->data = grown;
    b->cap = want;
    return 0;
}

static void buf_puts(Buf *b, const char *text) {
    size_t n = strlen(text);
    if (buf_reserve(b, n) == 0) {
        memcpy(b->data + b->len, text, n);
        b->len += n;
        b->data[b->len] = '\0';
    }
}

static void buf_printf(Buf *b, const char *format, ...) {
    char line[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    buf_puts(b, line);
}

/* Printable width, ignoring escape sequences, so padding maths stays honest. */
static size_t visible(const char *text) {
    size_t width = 0;
    for (const char *p = text; *p;) {
        if (*p == '\033') {
            while (*p && *p != 'm') p++;
            if (*p) p++;
            continue;
        }
        /* Treat a UTF-8 lead byte as one column; the UI only uses box drawing and arrows. */
        if ((*p & 0xC0) != 0x80) width++;
        p++;
    }
    return width;
}

/* ---------------------------------------------------------------- scrollback */

static char lines[MAX_LINES][LINE_CAP];
static int line_count;
static int scroll;

static void log_line(const char *text) {
    if (line_count == MAX_LINES) {
        memmove(lines[0], lines[1], sizeof(lines) - sizeof(lines[0]));
        line_count--;
    }
    snprintf(lines[line_count++], LINE_CAP, "%s", text);
}

static void log_clear(void) { line_count = 0; scroll = 0; }

/* Run `action` with stdout and stderr captured into the scrollback. A temporary file rather
   than a pipe: a pipe deadlocks the moment a command writes more than its buffer holds. */
static void capture(void (*action)(void *), void *context) {
    char path[] = "/tmp/oizys-tui-XXXXXX";
    int file = mkstemp(path);
    if (file < 0) { action(context); return; }
    unlink(path);
    fflush(stdout);
    fflush(stderr);
    int saved_out = dup(STDOUT_FILENO), saved_err = dup(STDERR_FILENO);
    dup2(file, STDOUT_FILENO);
    dup2(file, STDERR_FILENO);
    action(context);
    fflush(stdout);
    fflush(stderr);
    dup2(saved_out, STDOUT_FILENO);
    dup2(saved_err, STDERR_FILENO);
    close(saved_out);
    close(saved_err);

    off_t size = lseek(file, 0, SEEK_END);
    if (size > 0) {
        lseek(file, 0, SEEK_SET);
        char *text = malloc((size_t)size + 1);
        if (text && read(file, text, (size_t)size) == size) {
            text[size] = '\0';
            for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) log_line(line);
        }
        free(text);
    }
    close(file);
}

/* ---------------------------------------------------------------- terminal state */

static struct termios saved_termios;
static int raw_active;
static volatile sig_atomic_t resized = 1;
static volatile sig_atomic_t interrupted;

static void restore(void) {
    if (!raw_active) return;
    raw_active = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios);
    /* Show cursor, leave the alternate screen. */
    ssize_t ignored = write(STDOUT_FILENO, "\033[?25h\033[?1049l", 15);
    (void)ignored;
}

static void on_winch(int signal_number) { (void)signal_number; resized = 1; }
static void on_stop(int signal_number) { (void)signal_number; interrupted = 1; }

static int raw_mode(void) {
    if (tcgetattr(STDIN_FILENO, &saved_termios) < 0) return -1;
    struct termios raw = saved_termios;
    raw.c_lflag &= (tcflag_t)~(ECHO | ICANON | ISIG);
    raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) < 0) return -1;
    raw_active = 1;
    atexit(restore);
    ssize_t ignored = write(STDOUT_FILENO, "\033[?1049h\033[?25l", 14);
    (void)ignored;
    return 0;
}

static void screen_size(int *rows, int *cols) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_row && size.ws_col) {
        *rows = size.ws_row;
        *cols = size.ws_col;
    } else {
        *rows = 24;
        *cols = 80;
    }
}

/* ---------------------------------------------------------------- status */

typedef struct {
    char service[6][160];
    int service_lines;
    char displays[8][160];
    int display_lines;
    time_t gathered;
} Status;

static void gather_service(void *context) {
    (void)context;
    oizys_service_command("status");
}

static void refresh_status(Status *status) {
    int before = line_count;
    capture(gather_service, NULL);
    status->service_lines = 0;
    for (int i = before; i < line_count && status->service_lines < 6; i++) {
        /* The trailing sentence about an undocked listener is printed unconditionally and
           says nothing about the current state, so it only costs a row here. */
        if (!strncmp(lines[i], "An undocked", 11)) continue;
        snprintf(status->service[status->service_lines++], 160, "%s", lines[i]);
    }
    line_count = before; /* Status output belongs in the panel, not the log. */

    status->display_lines = 0;
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, ids, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count && status->display_lines < 8; i++) {
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
            const char *kind = CGDisplayIsBuiltin(ids[i]) ? "built-in"
                             : CGDisplayVendorNumber(ids[i]) == 0x4d56 ? "Oizys" : "external";
            snprintf(status->displays[status->display_lines++], 160, "%-8s %zu×%zu @ %.0f Hz%s",
                     kind, mode ? CGDisplayModeGetPixelWidth(mode) : 0,
                     mode ? CGDisplayModeGetPixelHeight(mode) : 0,
                     mode ? CGDisplayModeGetRefreshRate(mode) : 0,
                     CGDisplayIsMain(ids[i]) ? "  (main)" : "");
            if (mode) CGDisplayModeRelease(mode);
        }
    }
    status->gathered = time(NULL);
}

/* ---------------------------------------------------------------- actions */

typedef struct {
    const char *label;
    const char *hint;
    const char *service;   /* oizys_service_command argument, or NULL */
    const char *spawn[6];  /* argv for a self-spawn, or NULL */
    int config;            /* print the settings table */
} Action;

static const Action ACTIONS[] = {
    {"Service status",     "what the login agent and supervisor are doing", "status",         {NULL}, 0},
    {"Start / resume",     "claim the dock and begin forwarding",           "start",          {NULL}, 0},
    {"Stop",               "release the dock for this login",               "stop",           {NULL}, 0},
    {"Restart",            "apply changed driver settings",                 "restart",        {NULL}, 0},
    {"Enable login start", "run Oizys automatically at login",              "login-enable",   {NULL}, 0},
    {"Disable login start","stop running Oizys at login",                   "login-disable",  {NULL}, 0},
    {"Screen Recording",   "check or request the capture permission",       "permissions",    {NULL}, 0},
    {"Driver settings",    "every key, its value and its range",            NULL,             {NULL}, 1},
    {"Monitors",           "resolution, refresh and position of each head", NULL,
     {"oizys", "monitors", NULL}, 0},
    {"Probe the dock",     "identity and endpoints, read-only",             NULL,
     {"oizys", "probe", NULL}, 0},
};
static const int ACTION_COUNT = (int)(sizeof(ACTIONS) / sizeof(ACTIONS[0]));

static void run_service(void *context) { oizys_service_command((const char *)context); }
static void run_config(void *context) { (void)context; oizys_config_print(stdout); }

static void run_spawn(void *context) {
    const char *const *argv = (const char *const *)context;
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size)) return;
    pid_t child;
    if (posix_spawn(&child, executable, NULL, NULL, (char *const *)argv, environ) != 0) {
        fputs("Could not run that command.\n", stderr);
        return;
    }
    int state;
    while (waitpid(child, &state, 0) < 0 && errno == EINTR) {}
}

static void perform(const Action *action, Status *status) {
    log_clear();
    char banner[160];
    snprintf(banner, sizeof(banner), "$ %s", action->label);
    log_line(banner);
    if (action->service) capture(run_service, (void *)action->service);
    else if (action->config) capture(run_config, NULL);
    else if (action->spawn[0]) capture(run_spawn, (void *)action->spawn);
    if (line_count == 1) log_line("(no output)");
    oizys_config_reload();
    refresh_status(status);
    scroll = 0;
}

/* ---------------------------------------------------------------- drawing */

static void rule(Buf *frame, int cols, const char *title) {
    buf_puts(frame, DIM "─");
    int used = 1;
    if (title) {
        buf_printf(frame, "─ " TEXT "%s" DIM " ", title);
        used += (int)strlen(title) + 4;
    }
    for (int i = used; i < cols; i++) buf_puts(frame, "─");
    buf_puts(frame, RESET "\033[K\r\n");
}

/* Emit one row of a two-column body: `left` padded to width, then `right`, both clipped. */
static void columns(Buf *frame, const char *left, const char *right, int width, int cols) {
    char clipped[LINE_CAP];
    snprintf(clipped, sizeof(clipped), "%s", left ? left : "");
    buf_puts(frame, clipped);
    for (size_t i = visible(clipped); i < (size_t)width; i++) buf_puts(frame, " ");
    buf_puts(frame, DIM "│ " RESET);
    if (right) {
        int room = cols - width - 2;
        char cut[LINE_CAP];
        snprintf(cut, sizeof(cut), "%s", right);
        if (room > 0 && visible(cut) > (size_t)room) {
            /* Escape-free truncation is enough: right-hand text is plain. */
            cut[room > 0 && room < LINE_CAP ? room : LINE_CAP - 1] = '\0';
        }
        buf_puts(frame, cut);
    }
    buf_puts(frame, "\033[K\r\n");
}

static void draw(Status *status, int selected) {
    int rows, cols;
    screen_size(&rows, &cols);
    int wide = cols >= 92;
    int width = wide ? LOGO_W : 0;

    Buf frame = {0};
    buf_puts(&frame, "\033[H");

    /* A one-line summary rides in the header so a narrow terminal, which has no room for the
       status column, still says whether anything is actually running. */
    const char *supervisor = "stopped";
    for (int i = 0; i < status->service_lines; i++) {
        if (!strncmp(status->service[i], "Capture supervisor: ", 20)) {
            supervisor = status->service[i] + 20;
            break;
        }
    }
    int heads = 0;
    for (int i = 0; i < status->display_lines; i++) {
        if (!strncmp(status->displays[i], "Oizys", 5)) heads++;
    }
    char header[256];
    snprintf(header, sizeof(header), ACCENT " OIZYS " DIM "· open DisplayLink driver" RESET);
    char badge[128];
    snprintf(badge, sizeof(badge), "%ssupervisor %s" RESET DIM "  ·  " RESET TEXT "%d head%s" RESET,
             strcmp(supervisor, "stopped") ? GOOD : WARN, supervisor, heads, heads == 1 ? "" : "s");
    buf_puts(&frame, header);
    int gap = cols - (int)visible(header) - (int)visible(badge) - 1;
    for (int i = 0; i < gap; i++) buf_puts(&frame, " ");
    if (gap > 0) buf_puts(&frame, badge);
    buf_puts(&frame, RESET "\033[K\r\n");
    rule(&frame, cols, NULL);

    const int logo_rows = (int)(sizeof(OIZYS_LOGO_LARGE) / sizeof(OIZYS_LOGO_LARGE[0]));
    /* header 2 + rule 1 + footer 2 */
    int body = rows - 5;
    if (body < 6) body = 6;

    int list_rows = ACTION_COUNT + 2;
    if (list_rows > body - 3) list_rows = body - 3;

    for (int row = 0; row < body; row++) {
        char left[LINE_CAP] = "";
        char right[LINE_CAP] = "";

        if (wide) {
            if (row < logo_rows) {
                snprintf(left, sizeof(left), DIM " %s" RESET, OIZYS_LOGO_LARGE[row]);
            } else if (row == logo_rows + 1) {
                snprintf(left, sizeof(left), TEXT " STATUS" RESET);
            } else if (row > logo_rows + 1) {
                int index = row - logo_rows - 2;
                if (index < status->service_lines) {
                    snprintf(left, sizeof(left), DIM "  %.42s" RESET, status->service[index]);
                } else if (index == status->service_lines && status->display_lines) {
                    snprintf(left, sizeof(left), TEXT " DISPLAYS" RESET);
                } else if (index > status->service_lines) {
                    int d = index - status->service_lines - 1;
                    if (d < status->display_lines) {
                        snprintf(left, sizeof(left), DIM "  %.42s" RESET, status->displays[d]);
                    }
                }
            }
        }

        if (row == 0) {
            snprintf(right, sizeof(right), TEXT "ACTIONS" RESET);
        } else if (row - 1 < ACTION_COUNT && row - 1 < list_rows) {
            int index = row - 1;
            const Action *action = &ACTIONS[index];
            if (index == selected) {
                snprintf(right, sizeof(right), SELECT " %-20s " RESET DIM " %s" RESET,
                         action->label, action->hint);
            } else {
                snprintf(right, sizeof(right), TEXT " %-20s " RESET DIM " %s" RESET,
                         action->label, action->hint);
            }
        } else if (row == list_rows) {
            /* Blank row between the list and the output pane. In narrow mode there is no
               second column to draw, so emitting the divider would leave a stray bar. */
            if (wide) columns(&frame, left, NULL, width, cols);
            else buf_puts(&frame, "\033[K\r\n");
            continue;
        } else if (row == list_rows + 1) {
            snprintf(right, sizeof(right), TEXT "OUTPUT" RESET);
        } else if (row > list_rows + 1) {
            int index = row - list_rows - 2 + scroll;
            if (index >= 0 && index < line_count) {
                snprintf(right, sizeof(right), DIM "%s" RESET, lines[index]);
            }
        }

        if (wide) columns(&frame, left, right, width, cols);
        else buf_printf(&frame, "%s\033[K\r\n", right);
    }

    rule(&frame, cols, NULL);
    buf_printf(&frame, DIM " ↑↓/jk" TEXT " move  " DIM "⏎" TEXT " run  "
                       DIM "PgUp/PgDn" TEXT " scroll  " DIM "r" TEXT " refresh  "
                       DIM "q" TEXT " quit" RESET "\033[K");
    buf_puts(&frame, "\033[J");

    ssize_t ignored = write(STDOUT_FILENO, frame.data, frame.len);
    (void)ignored;
    free(frame.data);
}

/* ---------------------------------------------------------------- loop */

int oizys_tui(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fputs("The TUI needs an interactive terminal. Use `oizys help` for scriptable commands.\n",
              stderr);
        return 2;
    }
    if (raw_mode() < 0) {
        fputs("Could not put the terminal into raw mode.\n", stderr);
        return 2;
    }
    signal(SIGWINCH, on_winch);
    signal(SIGINT, on_stop);
    signal(SIGTERM, on_stop);

    Status status = {0};
    refresh_status(&status);
    log_line("Oizys terminal UI. Pick an action and press Return.");

    int selected = 0;
    int running = 1;
    while (running && !interrupted) {
        draw(&status, selected);
        resized = 0;

        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        int ready = poll(&input, 1, 1000);
        if (ready < 0) {
            if (errno == EINTR) continue;   /* resize or signal */
            break;
        }
        if (ready == 0) {
            if (time(NULL) - status.gathered >= 3) refresh_status(&status);
            continue;
        }

        char key[8];
        ssize_t got = read(STDIN_FILENO, key, sizeof(key));
        if (got <= 0) continue;

        if (got >= 3 && key[0] == '\033' && key[1] == '[') {
            switch (key[2]) {
            case 'A': if (selected > 0) selected--; break;
            case 'B': if (selected < ACTION_COUNT - 1) selected++; break;
            case '5': if (scroll > 0) scroll -= 5; break;               /* PgUp */
            case '6': if (scroll < line_count - 1) scroll += 5; break;  /* PgDn */
            default: break;
            }
            continue;
        }
        switch (key[0]) {
        case 'q': running = 0; break;
        case 'k': if (selected > 0) selected--; break;
        case 'j': if (selected < ACTION_COUNT - 1) selected++; break;
        case 'r': refresh_status(&status); break;
        case '\r':
        case '\n': perform(&ACTIONS[selected], &status); break;
        default: break;
        }
    }

    restore();
    return 0;
}
