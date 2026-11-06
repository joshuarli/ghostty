# Runtime keyboard-sound mute

```sh
ghostty mute             # Toggle the keyboard-sound mute override.
ghostty mute on          # Mute keyboard sounds.
ghostty mute off         # Remove the mute override.
ghostty mute status      # Query without changing state.
ghostty mute --help
```

The conventional `ghostty +mute` spelling also works. `toggle` can be supplied
explicitly. Successful commands print `on` or `off`, meaning **mute on/off**,
not sound on/off. Invalid arguments exit 2; transport/platform failures exit 1.

This controls an already-running application. It does not launch another
window/application, change a configuration file, or adjust system volume.
Muting is application-wide across that process's windows and tabs, affects
keyboard sounds only, and leaves terminal bells alone. The override survives
configuration reloads and sound-engine recreation, but resets when the app
restarts. `off` still respects `keyboard-sound=off` and the configured volume;
`status` reports the override, not whether an audio device is producing sound.

Both the CLI executable and running application must be built from this code.
Rebuild/install the fork normally, then restart the application once to start
its listener. Thereafter commands take effect without a restart or config
reload. The listener is integrated with macOS and native Wayland. GTK does not
implement the fork's keyboard sounds or this listener.

## Instance selection

Inside a new Ghostty terminal, `GHOSTTY_MUTE_PID` identifies the application
that owns it. This reserved variable is set when constructing the child's
environment, including for nested Ghostty instances; process-global environment
mutation is not used.

An explicit target takes priority:

```sh
ghostty mute on --pid=12345
ghostty mute --pid=12345 status
```

Without `--pid`, the inherited PID is used. A stale/invalid inherited PID is an
error; it never silently falls back to another instance. This also makes stale
terminal-multiplexer environments diagnosable. Supply the correct `--pid` or
unset `GHOSTTY_MUTE_PID` to request discovery.

Without either target, discovery must find exactly one responsive listener.
Discovery sends only read-only status probes. Multiple listeners produce an
error before any mutation is sent. Dead sockets are ignored, not deleted by
clients. Unresponsive or unverifiable candidates make discovery fail closed;
use an explicit PID instead of guessing which application should be affected.

## Implementation

`src/sound/mute.zig` owns the policy: a single atomic value contains the mute
flag and a transition generation. The application owns this state independently
of its audio engine. Repeated `on` or `off` commands are idempotent. `toggle`
uses an atomic compare-and-exchange loop, so concurrent requests do not lose
transitions.

The input path tags queued keyboard samples with the generation. The render
path clears keyboard voices and discards old-generation samples on a change,
including delayed shortcut chimes and an entire mute/unmute cycle between audio
callbacks. Held keys keep their physical/modifier state, but an old attack
cannot generate a release click after unmuting. The separate bell mixer is not
cleared. No I/O, allocation, lock, or IPC runs on the real-time audio callback;
it reads the app-owned atomic state. Audio already handed to the device cannot
be recalled; suppression begins with the next render block.

`src/sound/control.c` is a small libc/POSIX transport boundary. It uses local
Unix-domain sockets, a blocking `poll` worker, and an interruptible shutdown
pipe. It has no third-party dependency, D-Bus dependency, network listener,
persistent mute-state file, or periodic polling timer. The worker calls only
the atomic state callback; it does not touch the UI, configuration, key state,
play ring, or mixers.

Endpoints are `/tmp/ghostty-mute-<uid>/<pid>.sock`, inside an owner-checked 0700
directory, with 0600 socket permissions and same-user peer checks. Linux also
verifies the server PID. Symlink directories and non-socket endpoints are
rejected. Startup can recover its own stale PID socket, but never unlinks a live
listener. Shutdown unlinks only the endpoint inode it created. Descriptors are
close-on-exec and all accepted client transactions have absolute deadlines.

Each request is a versioned five-byte frame, terminated with a write-side
shutdown. Acknowledgements report the resulting state. Empty, oversized,
truncated, unknown-version and unknown-command frames do not mutate anything.
The command never automatically retries: a connection failure after applying a
toggle can lose the acknowledgement. Query `status` or use explicit `on`/`off`
when recovering from an uncertain result.

## Tests

The isolated transport integration suite requires only a POSIX C compiler and
pthreads; it does not touch production socket paths or require a display/audio
device:

```sh
sh test/sound-mute/run.sh
CFLAGS='-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer' \
  sh test/sound-mute/run.sh
```

It covers protocol framing, concurrent toggles, idempotent commands, status,
instance ambiguity, inherited/explicit/stale targets, descriptor permissions,
stale sockets, unsafe paths, disconnected/incomplete clients, shutdown, and
repeated startup/teardown. It is written for both Linux and macOS.

Run the Zig CLI, atomic-state, IPC callback, input-state and mixer tests with the
repository's required Zig toolchain:

```sh
zig build test -Dtest-filter=mute
```

For a manual smoke test, start a rebuilt application with keyboard sounds
enabled. Check `status`, toggle twice, then use explicit `on` and `off`. While
muted, type and release held keys, and use `printf '\a'` to confirm the configured
bell is unaffected. On macOS, reload the configuration while muted and verify
that it remains muted. Finally, run two application processes: each shell's
inherited PID must select its own process, while discovery from a shell with
`GHOSTTY_MUTE_PID` unset must reject ambiguity. Restarting a process must reset
its override to `off`.
