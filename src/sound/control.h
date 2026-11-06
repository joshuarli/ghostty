#ifndef GHOSTTY_SOUND_CONTROL_H
#define GHOSTTY_SOUND_CONTROL_H

#include <stddef.h>

/* Local, one-request-per-connection protocol: "GMU1" and one command byte,
 * followed by SHUT_WR. The response is "GMU1" and ASCII '0' or '1'. */
enum ghostty_mute_command {
    GHOSTTY_MUTE_STATUS = 0,
    GHOSTTY_MUTE_TOGGLE = 1,
    GHOSTTY_MUTE_ON = 2,
    GHOSTTY_MUTE_OFF = 3,
};

struct ghostty_mute_server;
/* Called only on the control thread. The callback must be thread-safe and
 * return the resulting mute flag (0 or 1); it must not touch UI/audio objects. */
typedef int (*ghostty_mute_callback)(void *, unsigned char);

struct ghostty_mute_server *ghostty_mute_server_start(
    void *, ghostty_mute_callback, char *error, size_t error_size);
void ghostty_mute_server_stop(struct ghostty_mute_server *);

/* pid=0: GHOSTTY_MUTE_PID, otherwise discover exactly one responsive instance.
 * An explicit positive pid overrides the environment. No mutation is sent
 * during discovery. Returns 0 on acknowledgement, -1 with a diagnostic. */
int ghostty_mute_request(int pid, unsigned char command, int *muted,
                         char *error, size_t error_size);
int ghostty_mute_pid(void);

#endif
