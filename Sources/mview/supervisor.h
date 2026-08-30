#pragma once

/* Own the worker lifetime and vendor handoff; no pixels pass through the supervisor. */
int mview_supervise(const char *executable, int profile, int stats);
