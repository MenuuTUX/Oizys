#pragma once

/* Returns -1 for commands handled by the driver entry point. */
int oizys_terminal_command(int argc, char **argv);

/* Full-screen terminal UI. */
int oizys_tui(void);
