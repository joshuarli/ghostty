#!/bin/sh
# run.sh drives the Wayland Ghostty binary against a scripted compositor built on
# libwayland-server and checks the protocol traffic and the process outcome.
#
# Usage: run.sh [GHOSTTY_BINARY]
#   ime       text-input-v3: enable on enter, cursor rectangle follows the cursor,
#             preedit renders, committed text reaches the PTY, disable on leave.
#   die       the compositor vanishes mid-session; Ghostty must exit with an error,
#             not abort.
#   no-abgr   the compositor does not advertise ABGR8888; Ghostty must refuse to
#             start with that reason.
#
# Needs cc, wayland-scanner, and the wayland-server development files. Protocol
# XML comes from the pinned wayland-protocols dependency in zig-pkg.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$repo/.work/wayland-fake
ghostty=${1:-$repo/zig-out/bin/ghostty}
pkg_hash=$(jaq -r 'to_entries[] | select(.value.name == "wayland_protocols") | .key' "$repo/build.zig.zon.json" | head -n 1)
protocols=$repo/zig-pkg/$pkg_hash
wayland_xml=$(pkg-config --variable=pkgdatadir wayland-scanner)/wayland.xml

log() { echo "run.sh: $*" >&2; }
die() { log "FAIL: $*"; exit 1; }
need() { grep -aq -- "$1" "$2" || die "$3 (missing '$1' in $2)"; }
refuse() { ! grep -aq -- "$1" "$2" || die "$3 (found '$1' in $2)"; }

build() {
	mkdir -p "$work"
	wayland-scanner server-header "$wayland_xml" "$work/wayland-server-protocol.h"
	wayland-scanner server-header "$protocols/stable/xdg-shell/xdg-shell.xml" "$work/xdg-shell-server-protocol.h"
	wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" "$work/xdg-shell-protocol.c"
	wayland-scanner server-header "$protocols/unstable/text-input/text-input-unstable-v3.xml" "$work/text-input-server-protocol.h"
	wayland-scanner private-code "$protocols/unstable/text-input/text-input-unstable-v3.xml" "$work/text-input-protocol.c"
	# shellcheck disable=SC2046
	cc -O0 -o "$work/compositor" "$here/compositor.c" "$work/xdg-shell-protocol.c" "$work/text-input-protocol.c" \
		-I"$work" $(pkg-config --cflags --libs wayland-server)
}

start() {
	scenario=$1
	dir=$work/$scenario
	rm -rf "$dir"
	mkdir -p "$dir/xdg"
	chmod 700 "$dir/xdg"
	export XDG_RUNTIME_DIR="$dir/xdg"
	"$work/compositor" "$scenario" fake-0 "$dir" 2> "$dir/compositor.log" &
	compositor=$!
	i=0
	while [ ! -S "$dir/xdg/fake-0" ]; do
		i=$((i + 1))
		[ "$i" -lt 50 ] || die "$scenario: compositor did not start"
		sleep 0.1
	done
}

run_client() {
	status=0
	WAYLAND_DISPLAY=fake-0 timeout 30 "$ghostty" "$@" > "$dir/ghostty.log" 2>&1 || status=$?
	wait "$compositor" || true
}

scenario_ime() {
	start ime
	run_client -e sh -c "stty raw; tee '$dir/out.bin'"
	log=$dir/compositor.log
	need 'FAKE client enable' "$log" "ime: input method was not enabled"
	need 'purpose=13' "$log" "ime: content purpose is not terminal"
	need 'FAKE client disable' "$log" "ime: input method was not disabled on leave"
	rects=$(grep -c 'FAKE client cursor_rect' "$log")
	[ "$rects" -ge 2 ] || die "ime: cursor rectangle did not follow the cursor ($rects sent)"
	printf '\343\201\213\343\202\223' > "$dir/expected.bin"
	cmp -s "$dir/expected.bin" "$dir/out.bin" || die "ime: committed text did not reach the PTY"
	[ -s "$dir/preedit.ppm" ] || die "ime: no preedit frame captured"
	! cmp -s "$dir/preedit.ppm" "$dir/committed.ppm" || die "ime: preedit and committed frames are identical"
	refuse panic "$dir/ghostty.log" "ime: ghostty panicked"
	log "ime: PASS"
}

scenario_die() {
	start die
	run_client -e sleep 60
	[ "$status" -eq 1 ] || die "die: expected exit status 1, got $status"
	need 'error:' "$dir/ghostty.log" "die: failure was not reported"
	refuse panic "$dir/ghostty.log" "die: ghostty panicked on compositor loss"
	log "die: PASS"
}

scenario_no_abgr() {
	start no-abgr
	run_client -e sleep 60
	[ "$status" -eq 1 ] || die "no-abgr: expected exit status 1, got $status"
	need 'NoShmAbgr8888' "$dir/ghostty.log" "no-abgr: refusal reason not reported"
	refuse panic "$dir/ghostty.log" "no-abgr: ghostty panicked"
	log "no-abgr: PASS"
}

build
scenario_ime
scenario_die
scenario_no_abgr
log "PASS"
