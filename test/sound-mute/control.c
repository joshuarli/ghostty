#define _GNU_SOURCE
/* Compile the transport into this test to exercise its framing/security helpers
 * without a GUI, audio hardware, a Zig toolchain, or production socket paths. */
static char test_prefix[80];
#define GHOSTTY_MUTE_DIR_PREFIX test_prefix
#include "../../src/sound/control.c"
#include <stdatomic.h>
#include <sys/wait.h>

static atomic_uint assertions;
#define CHECK(expr) do { \
    atomic_fetch_add(&assertions, 1); \
    if (!(expr)) { fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, errno); exit(1); } \
} while (0)

struct state { atomic_int muted; atomic_uint changes; };
static int apply(void *context, unsigned char command) {
    struct state *state = context;
    int old = atomic_load(&state->muted);
    for (;;) {
        int next;
        switch (command) {
            case GHOSTTY_MUTE_STATUS: return old;
            case GHOSTTY_MUTE_TOGGLE: next = !old; break;
            case GHOSTTY_MUTE_ON: next = 1; break;
            case GHOSTTY_MUTE_OFF: next = 0; break;
            default: abort();
        }
        if (next == old) return next;
        if (atomic_compare_exchange_weak(&state->muted, &old, next)) {
            atomic_fetch_add(&state->changes, 1);
            return next;
        }
    }
}

static int request(int pid, unsigned char command) {
    char error[256] = {0};
    int muted = -1;
    int result = ghostty_mute_request(pid, command, &muted, error, sizeof(error));
    if (result != 0) fprintf(stderr, "%s\n", error);
    CHECK(result == 0);
    CHECK(muted == 0 || muted == 1);
    return muted;
}

static void fails(int pid, unsigned char command, const char *expected) {
    char error[256] = {0};
    int muted = -1;
    CHECK(ghostty_mute_request(pid, command, &muted, error, sizeof(error)) == -1);
    CHECK(strstr(error, expected) != NULL);
    CHECK(muted == -1);
}

static struct ghostty_mute_server *start(struct state *state) {
    char error[256] = {0};
    struct ghostty_mute_server *server = ghostty_mute_server_start(state, apply, error, sizeof(error));
    if (!server) fprintf(stderr, "%s\n", error);
    CHECK(server != NULL);
    return server;
}

static void malformed(const char *path, const unsigned char *data, size_t size) {
    int fd = connect_endpoint(path, getpid(), now_ms() + 1000);
    CHECK(fd >= 0);
    CHECK(send_bytes(fd, data, size, -1, now_ms() + 1000) == 0);
    CHECK(shutdown(fd, SHUT_WR) == 0);
    CHECK(wait_ready(fd, POLLIN, -1, now_ms() + 1000) == 0);
    unsigned char reply[8];
    ssize_t n = recv(fd, reply, sizeof(reply), 0);
    CHECK(n == 0 || (n == -1 && errno == ECONNRESET));
    close(fd);
}

static void *toggle_many(void *unused) {
    (void)unused;
    for (int i = 0; i < 17; i++) (void)request(getpid(), GHOSTTY_MUTE_TOGGLE);
    return NULL;
}

struct child { pid_t pid; int input; };
static struct child spawn(const char *executable) {
    int input[2], output[2];
    CHECK(pipe(input) == 0);
    CHECK(pipe(output) == 0);
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        /* Only async-signal-safe operations between fork and exec. */
        if (dup2(input[0], STDIN_FILENO) < 0 || dup2(output[1], STDOUT_FILENO) < 0) _exit(125);
        close(input[0]); close(input[1]); close(output[0]); close(output[1]);
        execl(executable, executable, "--server", test_prefix, (char *)NULL);
        _exit(126);
    }
    close(input[0]); close(output[1]);
    char ready = 0;
    CHECK(read(output[0], &ready, 1) == 1 && ready == 'R');
    close(output[0]);
    return (struct child){pid, input[1]};
}

static void stop_child(struct child child) {
    CHECK(write(child.input, "Q", 1) == 1);
    close(child.input);
    int status;
    CHECK(waitpid(child.pid, &status, 0) == child.pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static int dead_socket(const char *path) {
    int fd = new_socket();
    CHECK(fd >= 0);
    struct sockaddr_un addr;
    address(&addr, path);
    CHECK(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    CHECK(chmod(path, 0600) == 0);
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--server") == 0) {
        snprintf(test_prefix, sizeof(test_prefix), "%s", argv[2]);
        struct state state = {0};
        struct ghostty_mute_server *server = start(&state);
        CHECK(write(STDOUT_FILENO, "R", 1) == 1);
        char stop;
        CHECK(read(STDIN_FILENO, &stop, 1) == 1);
        ghostty_mute_server_stop(server);
        return 0;
    }
    CHECK(argc == 1);
    CHECK(unsetenv("GHOSTTY_MUTE_PID") == 0);
    char root[] = "/tmp/ghostty-mute-test-XXXXXX";
    CHECK(mkdtemp(root) != NULL);
    snprintf(test_prefix, sizeof(test_prefix), "%s/instance-", root);
    fails(0, GHOSTTY_MUTE_TOGGLE, "no running Ghostty");
    struct state state = {0};
    struct ghostty_mute_server *server = start(&state);
    char path[PATH_CAP], dir[PATH_CAP];
    snprintf(path, sizeof(path), "%s", server->path);
    CHECK(directory(dir, sizeof(dir), 0) == 0);
    CHECK(check_endpoint(path) == 0);
    CHECK((fcntl(server->listener, F_GETFD) & FD_CLOEXEC) != 0);
    CHECK((fcntl(server->listener, F_GETFL) & O_NONBLOCK) != 0);
    CHECK((fcntl(server->stop[0], F_GETFD) & FD_CLOEXEC) != 0);
    CHECK((fcntl(server->stop[1], F_GETFD) & FD_CLOEXEC) != 0);

    CHECK(request(0, GHOSTTY_MUTE_STATUS) == 0);
    CHECK(request(0, GHOSTTY_MUTE_TOGGLE) == 1);
    CHECK(request(getpid(), GHOSTTY_MUTE_ON) == 1);
    CHECK(request(getpid(), GHOSTTY_MUTE_OFF) == 0);
    CHECK(request(getpid(), GHOSTTY_MUTE_OFF) == 0);
    CHECK(atomic_load(&state.changes) == 2);
    puts("PASS acknowledged toggle, on/off, status, private endpoint, descriptor flags");

    unsigned changes = atomic_load(&state.changes);
    malformed(path, (const unsigned char *)"BAD!\1", 5);
    malformed(path, (const unsigned char *)"GMU1\377", 5);
    malformed(path, (const unsigned char *)"GMU1", 4);
    malformed(path, (const unsigned char *)"GMU1\1x", 6);
    malformed(path, (const unsigned char *)"", 0);
    CHECK(atomic_load(&state.changes) == changes);
    puts("PASS malformed, truncated, empty and oversized requests do not mutate");

    int fd = connect_endpoint(path, getpid(), now_ms() + 1000);
    CHECK(fd >= 0);
    const unsigned char frame[5] = {'G','M','U','1',GHOSTTY_MUTE_ON};
    for (size_t i = 0; i < sizeof(frame); i++) CHECK(send_bytes(fd, frame + i, 1, -1, now_ms() + 1000) == 0);
    CHECK(shutdown(fd, SHUT_WR) == 0);
    unsigned char response[5];
    size_t used = 0;
    while (used < sizeof(response)) {
        CHECK(wait_ready(fd, POLLIN, -1, now_ms() + 1000) == 0);
        ssize_t n = recv(fd, response + used, sizeof(response) - used, 0);
        CHECK(n > 0);
        used += (size_t)n;
    }
    CHECK(memcmp(response, "GMU11", 5) == 0);
    close(fd);
    fd = connect_endpoint(path, getpid(), now_ms() + 1000);
    CHECK(fd >= 0);
    CHECK(send_bytes(fd, frame, sizeof(frame), -1, now_ms() + 1000) == 0);
    CHECK(shutdown(fd, SHUT_WR) == 0);
    close(fd); // server must survive sending to a disappeared peer (SIGPIPE)
    CHECK(request(getpid(), GHOSTTY_MUTE_OFF) == 0);
    puts("PASS fragmented frames and disconnected clients");

    pthread_t threads[8];
    changes = atomic_load(&state.changes);
    for (size_t i = 0; i < 8; i++) CHECK(pthread_create(&threads[i], NULL, toggle_many, NULL) == 0);
    for (size_t i = 0; i < 8; i++) CHECK(pthread_join(threads[i], NULL) == 0);
    CHECK(request(getpid(), GHOSTTY_MUTE_STATUS) == 0);
    CHECK(atomic_load(&state.changes) == changes + 8 * 17);
    puts("PASS 136 concurrent toggles, no lost commands");

    char error[256] = {0};
    CHECK(ghostty_mute_server_start(&state, apply, error, sizeof(error)) == NULL);
    CHECK(request(getpid(), GHOSTTY_MUTE_STATUS) == 0);
    struct child child = spawn(argv[0]);
    changes = atomic_load(&state.changes);
    fails(0, GHOSTTY_MUTE_TOGGLE, "multiple Ghostty instances");
    CHECK(atomic_load(&state.changes) == changes);
    CHECK(request(child.pid, GHOSTTY_MUTE_STATUS) == 0);
    char pid_text[32];
    snprintf(pid_text, sizeof(pid_text), "%d", getpid());
    CHECK(setenv("GHOSTTY_MUTE_PID", pid_text, 1) == 0);
    CHECK(request(0, GHOSTTY_MUTE_ON) == 1);
    CHECK(request(child.pid, GHOSTTY_MUTE_STATUS) == 0);
    CHECK(request(child.pid, GHOSTTY_MUTE_ON) == 1);
    CHECK(setenv("GHOSTTY_MUTE_PID", "2147483647", 1) == 0);
    fails(0, GHOSTTY_MUTE_TOGGLE, "2147483647");
    CHECK(setenv("GHOSTTY_MUTE_PID", "-1", 1) == 0);
    fails(0, GHOSTTY_MUTE_TOGGLE, "invalid GHOSTTY_MUTE_PID");
    CHECK(request(getpid(), GHOSTTY_MUTE_OFF) == 0); // explicit PID wins
    CHECK(unsetenv("GHOSTTY_MUTE_PID") == 0);
    stop_child(child);
    CHECK(request(0, GHOSTTY_MUTE_STATUS) == 0);
    puts("PASS duplicate listeners, ambiguity, inherited/explicit/stale PID targeting");

    char stale[PATH_CAP];
    CHECK(endpoint(stale, sizeof(stale), dir, INT_MAX - 1) == 0);
    dead_socket(stale);
    CHECK(request(0, GHOSTTY_MUTE_STATUS) == 0);
    CHECK(check_endpoint(stale) == 0); // clients do not unlink stale endpoints
    CHECK(unlink(stale) == 0);
    puts("PASS stale discovery endpoints are ignored without deleting files");

    fd = connect_endpoint(path, getpid(), now_ms() + 1000);
    CHECK(fd >= 0);
    int64_t before = now_ms();
    CHECK(wait_ready(fd, POLLIN, -1, before + IO_TIMEOUT_MS + 1000) == 0);
    unsigned char byte;
    CHECK(recv(fd, &byte, 1, 0) == 0);
    CHECK(now_ms() - before < IO_TIMEOUT_MS + 1000);
    close(fd);
    CHECK(request(getpid(), GHOSTTY_MUTE_STATUS) == 0);
    puts("PASS incomplete requests time out and do not wedge the listener");

    fd = connect_endpoint(path, getpid(), now_ms() + 1000);
    CHECK(fd >= 0);
    before = now_ms();
    ghostty_mute_server_stop(server);
    CHECK(now_ms() - before < 500);
    close(fd);
    CHECK(access(path, F_OK) == -1 && errno == ENOENT);
    puts("PASS shutdown interrupts an incomplete request and removes its socket");

    dead_socket(path);
    server = start(&state);
    CHECK(request(getpid(), GHOSTTY_MUTE_STATUS) == 0);
    ghostty_mute_server_stop(server);
    CHECK(access(path, F_OK) == -1 && errno == ENOENT);
    puts("PASS stale own-PID socket recovery");

    CHECK(chmod(dir, 0755) == 0);
    CHECK(ghostty_mute_server_start(&state, apply, error, sizeof(error)) == NULL);
    fails(0, GHOSTTY_MUTE_ON, "private mute directory");
    CHECK(chmod(dir, 0700) == 0);
    CHECK(rmdir(dir) == 0);
    CHECK(symlink(root, dir) == 0);
    CHECK(ghostty_mute_server_start(&state, apply, error, sizeof(error)) == NULL);
    CHECK(unlink(dir) == 0);
    CHECK(directory(dir, sizeof(dir), 1) == 0);
    int file = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    CHECK(file >= 0); close(file);
    CHECK(ghostty_mute_server_start(&state, apply, error, sizeof(error)) == NULL);
    CHECK(access(path, F_OK) == 0);
    CHECK(unlink(path) == 0);
    puts("PASS insecure/symlink directories and ordinary files are rejected, not overwritten");

    server = start(&state);
    char renamed[PATH_CAP + 5];
    snprintf(renamed, sizeof(renamed), "%s.old", path);
    CHECK(rename(path, renamed) == 0);
    dead_socket(path);
    ghostty_mute_server_stop(server);
    CHECK(check_endpoint(path) == 0);
    CHECK(unlink(path) == 0);
    CHECK(unlink(renamed) == 0);
    puts("PASS shutdown cannot unlink a replacement endpoint");

    for (int i = 0; i < 10; i++) {
        server = start(&state);
        CHECK(request(getpid(), GHOSTTY_MUTE_STATUS) == 0);
        ghostty_mute_server_stop(server);
    }
    CHECK(parse_pid("2147483647", 10) == INT_MAX);
    CHECK(parse_pid("2147483648", 10) == 0);
    CHECK(parse_pid("4294967297", 10) == 0);
    CHECK(parse_pid("+1", 2) == 0);
    CHECK(parse_pid("0", 1) == 0);
    CHECK(rmdir(dir) == 0);
    CHECK(rmdir(root) == 0);
    printf("PASS repeated lifecycle and PID validation; %u assertions\n", atomic_load(&assertions));
    return 0;
}
