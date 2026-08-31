#pragma once

/* Exclusive per-user driver lease, also used by an unsupervised CLI run. */
int oizys_lock_driver(void);

/* Own the worker lifetime and vendor handoff; no pixels pass through the supervisor. */
int oizys_supervise(const char *executable, int profile, int stats);
