#!/bin/sh
# Standalone IPC integration tests; no Ghostty build, audio device, or network.
set -eu
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-mute-build.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
# CFLAGS/LDFLAGS are deliberately word-split, matching ordinary make conventions.
${CC:-cc} -std=c11 -Wall -Wextra -Werror -pthread ${CFLAGS:-} \
    test/sound-mute/control.c ${LDFLAGS:-} -o "$work/control-test"
"$work/control-test"
