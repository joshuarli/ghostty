/* POSIX-only transport for the native macOS and Wayland runtimes.
 * No audio work, configuration writes, D-Bus, shelling out, or polling timer.
 * The worker blocks in poll; every client transaction has one absolute deadline.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "control.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifndef GHOSTTY_MUTE_DIR_PREFIX
#define GHOSTTY_MUTE_DIR_PREFIX "/tmp/ghostty-mute-"
#endif
#define IO_TIMEOUT_MS 750
#define DISCOVERY_TIMEOUT_MS 2000
#define PATH_CAP sizeof(((struct sockaddr_un *)0)->sun_path)

struct ghostty_mute_server {
    int listener;
    int stop[2];
    pthread_t thread;
    void *context;
    ghostty_mute_callback callback;
    char path[PATH_CAP];
    dev_t device;
    ino_t inode;
    int bound;
};

static int diagnostic(char *out, size_t size, const char *format, ...) {
    if (size != 0) {
        va_list args;
        va_start(args, format);
        vsnprintf(out, size, format, args);
        va_end(args);
    }
    return -1;
}

static int64_t now_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_ready(int fd, short events, int stop, int64_t deadline) {
    struct pollfd fds[2] = {{fd, events, 0}, {stop, POLLIN, 0}};
    for (;;) {
        int64_t now = now_ms();
        if (now < 0) return -1;
        int64_t remaining = deadline - now;
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        int result = poll(fds, stop < 0 ? 1 : 2,
                          remaining > INT_MAX ? INT_MAX : (int)remaining);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return -1;
        if (result == 0) { errno = ETIMEDOUT; return -1; }
        if (stop >= 0 && fds[1].revents) { errno = ECANCELED; return -1; }
        if (fds[0].revents & POLLNVAL) { errno = EBADF; return -1; }
        /* POLLHUP is useful: recv must observe EOF, not wait indefinitely. */
        if (fds[0].revents & (events | POLLHUP | POLLERR)) return 0;
    }
}

static int configure_fd(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) return -1;
    flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return 0;
}

static int new_socket(void) {
#if defined(SOCK_CLOEXEC) && defined(SOCK_NONBLOCK)
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
#endif
    if (fd < 0) return -1;
    if (configure_fd(fd) < 0) goto fail;
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) < 0) goto fail;
#endif
    return fd;
fail:;
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}

static int peer_matches(int fd, int expected_pid) {
#ifdef __linux__
    struct ucred peer;
    socklen_t size = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size) < 0) return -1;
    if (peer.uid != geteuid() || (expected_pid > 0 && peer.pid != expected_pid)) {
        errno = EACCES;
        return -1;
    }
#else
    uid_t uid;
    gid_t gid;
    (void)expected_pid;
    if (getpeereid(fd, &uid, &gid) < 0) return -1;
    if (uid != geteuid()) { errno = EACCES; return -1; }
#endif
    return 0;
}

static int directory(char *path, size_t size, int create) {
    if (geteuid() != getuid() || getegid() != getgid()) {
        errno = EPERM;
        return -1;
    }
    int n = snprintf(path, size, "%s%lu", GHOSTTY_MUTE_DIR_PREFIX,
                     (unsigned long)geteuid());
    if (n < 0 || (size_t)n >= size) { errno = ENAMETOOLONG; return -1; }
    if (create && mkdir(path, 0700) < 0 && errno != EEXIST) return -1;
    struct stat st;
    if (lstat(path, &st) < 0) return -1;
    if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0777) != 0700) {
        errno = EACCES;
        return -1;
    }
    return 0;
}

static int endpoint(char *path, size_t size, const char *dir, int pid) {
    int n = snprintf(path, size, "%s/%d.sock", dir, pid);
    if (n < 0 || (size_t)n >= size) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

static int check_endpoint(const char *path) {
    struct stat st;
    if (lstat(path, &st) < 0) return -1;
    if (!S_ISSOCK(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 0777) != 0600) {
        errno = EACCES;
        return -1;
    }
    return 0;
}

static void address(struct sockaddr_un *addr, const char *path) {
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    memcpy(addr->sun_path, path, strlen(path) + 1);
#ifdef __APPLE__
    addr->sun_len = sizeof(*addr);
#endif
}

static int connect_endpoint(const char *path, int pid, int64_t deadline) {
    if (check_endpoint(path) < 0) return -1;
    int fd = new_socket();
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    address(&addr, path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (errno != EINPROGRESS && errno != EAGAIN) goto fail;
        if (wait_ready(fd, POLLOUT, -1, deadline) < 0) goto fail;
        int error = 0;
        socklen_t size = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0) goto fail;
        if (error != 0) { errno = error; goto fail; }
    }
    if (peer_matches(fd, pid) < 0) goto fail;
    return fd;
fail:;
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}

static int send_bytes(int fd, const unsigned char *data, size_t size,
                      int stop, int64_t deadline) {
    while (size != 0) {
        if (wait_ready(fd, POLLOUT, stop, deadline) < 0) return -1;
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, data, size, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, data, size, 0);
#endif
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n < 0) return -1;
        if (n == 0) { errno = EPIPE; return -1; }
        data += n;
        size -= (size_t)n;
    }
    return 0;
}

static void serve(struct ghostty_mute_server *server, int fd) {
    unsigned char request[6];
    size_t used = 0;
    int64_t start = now_ms();
    if (start < 0 || peer_matches(fd, 0) < 0) return;
    int64_t deadline = start + IO_TIMEOUT_MS;
    /* Require EOF after exactly one frame. Oversized/truncated frames never
     * reach the state callback, including valid prefixes with trailing bytes. */
    for (;;) {
        if (wait_ready(fd, POLLIN, server->stop[0], deadline) < 0) return;
        ssize_t n = recv(fd, request + used, sizeof(request) - used, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n < 0) return;
        if (n == 0) break;
        used += (size_t)n;
        if (used == sizeof(request)) return;
    }
    if (used != 5 || memcmp(request, "GMU1", 4) != 0 ||
        request[4] > GHOSTTY_MUTE_OFF) return;
    int muted = server->callback(server->context, request[4]);
    unsigned char reply[5] = {'G', 'M', 'U', '1', (unsigned char)(muted ? '1' : '0')};
    (void)send_bytes(fd, reply, sizeof(reply), server->stop[0], deadline);
}

static void *server_main(void *context) {
    struct ghostty_mute_server *server = context;
    struct pollfd fds[2] = {{server->listener, POLLIN, 0}, {server->stop[0], POLLIN, 0}};
    for (;;) {
        int n = poll(fds, 2, -1);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 || fds[1].revents) break;
        if (!(fds[0].revents & POLLIN)) break;
#ifdef __linux__
        int fd = accept4(server->listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
#else
        int fd = accept(server->listener, NULL, NULL);
#endif
        if (fd < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        if (configure_fd(fd) == 0) {
#ifdef SO_NOSIGPIPE
            int yes = 1;
            if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) == 0)
#endif
                serve(server, fd);
        }
        close(fd);
    }
    return NULL;
}

static void dispose(struct ghostty_mute_server *server) {
    if (server->listener >= 0) close(server->listener);
    if (server->stop[0] >= 0) close(server->stop[0]);
    if (server->stop[1] >= 0) close(server->stop[1]);
    /* Never remove a replacement endpoint installed by another instance. */
    struct stat st;
    if (server->bound && lstat(server->path, &st) == 0 &&
        st.st_dev == server->device && st.st_ino == server->inode &&
        S_ISSOCK(st.st_mode)) (void)unlink(server->path);
    free(server);
}

struct ghostty_mute_server *ghostty_mute_server_start(
    void *context, ghostty_mute_callback callback, char *error, size_t error_size) {
    char dir[PATH_CAP];
    if (callback == NULL || directory(dir, sizeof(dir), 1) < 0) {
        diagnostic(error, error_size, "cannot use private mute directory: %s", strerror(errno));
        return NULL;
    }
    struct ghostty_mute_server *server = calloc(1, sizeof(*server));
    if (server == NULL) {
        diagnostic(error, error_size, "cannot allocate mute server");
        return NULL;
    }
    server->listener = server->stop[0] = server->stop[1] = -1;
    server->context = context;
    server->callback = callback;
    if (endpoint(server->path, sizeof(server->path), dir, getpid()) < 0) goto fail;

    struct stat previous;
    if (lstat(server->path, &previous) == 0) {
        /* Only recover a dead, owned socket for this PID. Do not unlink a live
         * listener, symlink, ordinary file, or another user's endpoint. */
        int64_t now = now_ms();
        if (now < 0) goto fail;
        int fd = connect_endpoint(server->path, getpid(), now + IO_TIMEOUT_MS);
        if (fd >= 0) { close(fd); errno = EADDRINUSE; goto fail; }
        if (errno != ECONNREFUSED) goto fail;
        struct stat current;
        if (lstat(server->path, &current) < 0) goto fail;
        if (current.st_dev != previous.st_dev || current.st_ino != previous.st_ino) {
            errno = EADDRINUSE;
            goto fail;
        }
        if (unlink(server->path) < 0) goto fail;
    } else if (errno != ENOENT) goto fail;

    server->listener = new_socket();
    if (server->listener < 0) goto fail;
    struct sockaddr_un addr;
    address(&addr, server->path);
    if (bind(server->listener, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto fail;
    struct stat st;
    if (lstat(server->path, &st) < 0) goto fail;
    server->bound = 1;
    server->device = st.st_dev;
    server->inode = st.st_ino;
    if (chmod(server->path, 0600) < 0 || listen(server->listener, 16) < 0) goto fail;
#ifdef __linux__
    if (pipe2(server->stop, O_CLOEXEC | O_NONBLOCK) < 0) goto fail;
#else
    if (pipe(server->stop) < 0) goto fail;
    if (configure_fd(server->stop[0]) < 0 || configure_fd(server->stop[1]) < 0) goto fail;
#endif
    int thread_error = pthread_create(&server->thread, NULL, server_main, server);
    if (thread_error != 0) { errno = thread_error; goto fail; }
    return server;
fail:;
    int saved = errno;
    dispose(server);
    diagnostic(error, error_size, "cannot start runtime mute control: %s", strerror(saved));
    return NULL;
}

void ghostty_mute_server_stop(struct ghostty_mute_server *server) {
    if (server == NULL) return;
    unsigned char byte = 1;
    ssize_t result;
    do { result = write(server->stop[1], &byte, 1); } while (result < 0 && errno == EINTR);
    /* EAGAIN means a wake byte is already pending. The pipe is closed only
     * after the worker has joined, including during an incomplete request. */
    (void)pthread_join(server->thread, NULL);
    dispose(server);
}

static int transact(const char *dir, int pid, unsigned char command,
                    int *muted, int64_t deadline) {
    char path[PATH_CAP];
    if (endpoint(path, sizeof(path), dir, pid) < 0) return -1;
    int fd = connect_endpoint(path, pid, deadline);
    if (fd < 0) return -1;
    unsigned char request[5] = {'G', 'M', 'U', '1', command};
    int result = -1;
    if (send_bytes(fd, request, sizeof(request), -1, deadline) < 0) goto done;
    if (shutdown(fd, SHUT_WR) < 0) goto done;
    unsigned char reply[5];
    size_t used = 0;
    while (used < sizeof(reply)) {
        if (wait_ready(fd, POLLIN, -1, deadline) < 0) goto done;
        ssize_t n = recv(fd, reply + used, sizeof(reply) - used, 0);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n < 0) goto done;
        if (n == 0) { errno = EPROTO; goto done; }
        used += (size_t)n;
    }
    if (memcmp(reply, "GMU1", 4) != 0 || (reply[4] != '0' && reply[4] != '1')) {
        errno = EPROTO;
        goto done;
    }
    *muted = reply[4] == '1';
    result = 0;
done:;
    int saved = errno;
    close(fd);
    errno = saved;
    return result;
}

static int parse_pid(const char *text, size_t length) {
    if (length == 0 || length > 10) return 0;
    unsigned long n = 0;
    for (size_t i = 0; i < length; i++) {
        if (text[i] < '0' || text[i] > '9') return 0;
        unsigned digit = (unsigned)(text[i] - '0');
        if (n > ((unsigned long)INT_MAX - digit) / 10) return 0;
        n = n * 10 + digit;
    }
    return (int)n;
}

int ghostty_mute_request(int pid, unsigned char command, int *muted,
                         char *error, size_t error_size) {
    if (pid < 0 || command > GHOSTTY_MUTE_OFF || muted == NULL)
        return diagnostic(error, error_size, "invalid mute request");
    if (pid == 0) {
        const char *inherited = getenv("GHOSTTY_MUTE_PID");
        if (inherited != NULL) {
            pid = parse_pid(inherited, strlen(inherited));
            if (pid == 0) return diagnostic(error, error_size,
                "invalid GHOSTTY_MUTE_PID; use --pid=PID or unset it");
        }
    }
    char dir[PATH_CAP];
    if (directory(dir, sizeof(dir), 0) < 0) {
        if (errno == ENOENT) return diagnostic(error, error_size,
            "no running Ghostty with runtime mute support; rebuild and restart Ghostty");
        return diagnostic(error, error_size, "cannot use private mute directory: %s", strerror(errno));
    }
    if (pid == 0) {
        DIR *entries = opendir(dir);
        if (entries == NULL) return diagnostic(error, error_size, "cannot discover Ghostty: %s", strerror(errno));
        int64_t start = now_ms();
        if (start < 0) { closedir(entries); return diagnostic(error, error_size, "cannot read monotonic clock"); }
        int64_t deadline = start + DISCOVERY_TIMEOUT_MS;
        struct dirent *entry;
        int failure = 0;
        errno = 0;
        while ((entry = readdir(entries)) != NULL) {
            size_t size = strlen(entry->d_name);
            if (size > 5 && strcmp(entry->d_name + size - 5, ".sock") == 0) {
                int candidate = parse_pid(entry->d_name, size - 5);
                if (candidate != 0) {
                    int status;
                    int64_t now = now_ms();
                    int64_t limit = now + IO_TIMEOUT_MS;
                    if (now < 0 || now >= deadline) {
                        failure = diagnostic(error, error_size, "Ghostty discovery timed out; use --pid=PID");
                        break;
                    }
                    if (limit > deadline) limit = deadline;
                    if (transact(dir, candidate, GHOSTTY_MUTE_STATUS, &status, limit) == 0) {
                        if (pid != 0) {
                            failure = diagnostic(error, error_size,
                                "multiple Ghostty instances (%d, %d); use --pid=PID", pid, candidate);
                            break;
                        }
                        pid = candidate;
                    } else if (errno != ENOENT && errno != ECONNREFUSED) {
                        failure = diagnostic(error, error_size,
                            "cannot verify Ghostty pid %d: %s; use --pid=PID", candidate, strerror(errno));
                        break;
                    }
                }
            }
            errno = 0;
        }
        int read_error = errno;
        closedir(entries);
        if (failure) return -1;
        if (read_error) return diagnostic(error, error_size, "cannot enumerate Ghostty: %s", strerror(read_error));
        if (pid == 0) return diagnostic(error, error_size,
            "no running Ghostty with runtime mute support; rebuild and restart Ghostty");
    }
    int64_t now = now_ms();
    if (now >= 0 && transact(dir, pid, command, muted, now + IO_TIMEOUT_MS) == 0) return 0;
    return diagnostic(error, error_size,
        "mute request to Ghostty pid %d failed: %s (not retried)", pid, strerror(errno));
}

int ghostty_mute_pid(void) { return (int)getpid(); }
