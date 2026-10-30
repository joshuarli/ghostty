#!/bin/sh
# vm.sh boots Alpine x86_64 under KVM, runs the Wayland Ghostty binary
# under cage (pixman), and proves it renders via monitor screendump.
#
# Usage: vm.sh COMMAND [ARGS]
#   setup     Install Alpine + provision cage/ghostty, snapshot "ready".
#             Takes very long; run once.
#   start     Boot in background, wait for login + ssh (interactive use).
#   test      Boot its own VM, prove rendering (non-blank screendump,
#             wayland socket owned, no Xwayland, key smoke adds a prompt
#             line), power off. Prints PASS.
#   stop      Power off.  reset  Back to "ready" (VM stopped).
#   ssh [CMD] ssh to the VM.  status  Running?  help  This text.
#
# State is .work/vm-wayland (never /tmp). setup/test provision HEAD,
# so they need a clean tree. Full PASS deferred to M2.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$repo/.work/vm-wayland
iso=alpine-virt-3.24.3-x86_64.iso
mirror=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64
edge=https://dl-cdn.alpinelinux.org/alpine/edge
rootpw=waylandvmroot
userpw=waylandvmuser
console=$work/console.log
pidfile=$work/qemu.pid
disk=$work/disk.qcow2
port=${GHOSTTY_WAYLAND_VM_SSH_PORT:-2223}
cpus=${GHOSTTY_WAYLAND_VM_CPUS:-4}
memory=${GHOSTTY_WAYLAND_VM_MEMORY:-4096}
timeout=${GHOSTTY_WAYLAND_VM_TIMEOUT:-600}
key=$work/id_ed25519
ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=5 -i $key -p $port"
usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
log() { echo "vm.sh: $*" >&2; }
die() { log "$*"; exit 1; }
say() { printf 'vm: %s\n' "$*"; }
running() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
clean_tree() { [ -z "$(git -C "$repo" status --porcelain)" ] || die "commit changes first; the VM provisions HEAD"; }
guest_ssh() { ssh $ssh_opts root@127.0.0.1 "$@"; }
monitor() { { printf '%s\n' "$1"; sleep 1; } | nc -U "$work/monitor.sock" >/dev/null; }
send() { printf '%s\r' "$1" >&3; }
size() { echo $(($(wc -c < "$console"))); }
since() { tail -c "+$(($1 + 1))" "$console"; }
fail() {
	printf 'vm: FAIL: %s (console: %s)\n' "$*" "$console" >&2
	if [ -n "${diagnose:-}" ] && running; then
		send "$diagnose"
		monitor "screendump $work/failure.ppm"
		sleep 3
	fi
	tail -n 20 "$console" >&2 || true
	stop_vm
	exit 1
}
wait_for() {
	start=$1 pattern=$2 limit=$3
	while [ "$limit" -gt 0 ]; do
		since "$start" | grep -aq -- "$pattern" && return 0
		running || fail "vm exited while waiting for: $pattern"
		sleep 1; limit=$((limit - 1))
	done
	fail "timed out waiting for: $pattern"
}
run() {
	start=$(size)
	printf 'vm: + %s\n' "$1" >&2
	send "$1; echo RC=\$?:$start:"
	wait_for "$start" "RC=[0-9]*:$start:" "${2:-300}"
	since "$start" | grep -ao "RC=[0-9]*:$start:" | head -n 1 | sed 's/RC=\([0-9]*\):.*/\1/'
}
must() { rc=$(run "$@"); [ "$rc" = 0 ] || fail "exit $rc: $1"; }
poll() { must "for i in \$(seq 90); do $1 && break; sleep 1; done; $1" 120; }
nonblank() {
	python3 - "$1" <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
assert data[:2] == b'P6', 'not a P6 ppm'
toks, i = [], 2
while len(toks) < 3:
    while data[i:i + 1].isspace(): i += 1
    if data[i:i + 1] == b'#':
        while data[i:i + 1] != b'\n': i += 1
    else:
        j = i
        while not data[j:j + 1].isspace(): j += 1
        toks.append(data[i:j]); i = j
n = int(toks[0]) * int(toks[1])
px, step = data[i + 1:], max(1, n // 20000)
base, offs = px[:3], range(0, n, step)
frac = sum(1 for o in offs if px[3 * o:3 * o + 3] != base) / len(offs)
print('nonblank pixels: %.2f%%' % (100 * frac))
sys.exit(0 if frac > 0.02 else 1)
EOF
}
boot() {
	rm -f "$work/serial.sock" "$work/qemu.pid" "$work/console.fifo"
	: > "$console"
	$qemu || fail 'qemu did not start'
	mkfifo "$work/console.fifo"
	nc -U "$work/serial.sock" < "$work/console.fifo" >> "$console" &
	bridge=$!
	exec 3> "$work/console.fifo"
	wait_for 0 'login:' 180
}
login() {
	start=$(size)
	send root; sleep 2
	! since "$start" | grep -aq 'Password:' || send "$rootpw"
	send "stty -echo; PS1='VM# '"
	wait_for "$start" 'VM# ' 30
}
wait_ssh() {
	began=$(date +%s)
	while ! guest_ssh true 2>/dev/null; do
		running || fail 'QEMU exited during boot'
		[ $(($(date +%s) - began)) -lt "$timeout" ] || fail "ssh dead after ${timeout}s"
		sleep 5
	done
	say "ssh works after $(($(date +%s) - began))s"
}
stop_vm() {
	exec 3>&- 2>/dev/null || true
	if running; then kill "$(cat "$pidfile")" 2>/dev/null || true; fi
	if [ -n "${bridge:-}" ]; then kill "$bridge" 2>/dev/null || true; fi
	bridge=
}
poweroff() {
	send poweroff
	i=0
	while running && [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
	if running; then fail 'vm did not power off'; fi
	stop_vm
}
find_qemu() {
	[ "$(uname -m)" = x86_64 ] || die 'this harness is x86_64-only'
	command -v qemu-system-x86_64 >/dev/null || die 'qemu-system-x86_64 is required'
	command -v qemu-img >/dev/null || die 'qemu-img is required'
	command -v nc >/dev/null || die 'nc is required'
	[ -f /usr/share/qemu/edk2-x86_64-code.fd ] || die 'edk2 firmware missing at /usr/share/qemu/'
	if [ -w /dev/kvm ]; then accel='-accel kvm -cpu host'; else accel='-accel tcg -cpu max'; fi
}
qemu_base() {
	printf '%s' "qemu-system-x86_64 -M q35 $accel -m $memory -smp $cpus"
	printf '%s' " -drive if=pflash,format=raw,readonly=on,file=/usr/share/qemu/edk2-x86_64-code.fd -drive if=pflash,format=raw,file=$work/vars.fd"
	printf '%s' " -drive file=$disk,if=virtio -drive file=fat:ro:$work/share,format=raw,if=virtio,readonly=on"
	printf '%s' " -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22"
	printf '%s' " -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -display none"
	printf '%s' " -serial unix:$work/serial.sock,server=on,wait=off -monitor unix:$work/monitor.sock,server=on,wait=off -pidfile $pidfile -daemonize -D $work/qemu.log"
}
fetch_iso() {
	mkdir -p "$work/share"
	if [ -f "$work/$iso" ]; then return; fi
	curl -fsS -o "$work/$iso.part" "$mirror/$iso"
	curl -fsS -o "$work/$iso.sha256" "$mirror/$iso.sha256"
	(cd "$work" && sed "s/$iso\$/$iso.part/" "$iso.sha256" | sha256sum -c -s -) ||
		{ rm -f "$work/$iso.part"; die "$iso checksum mismatch"; }
	mv "$work/$iso.part" "$work/$iso"
}
answer_setup() {
	must 'mkdir -p /media/share && mount -t vfat -o ro /dev/vdb1 /media/share'
	start=$(size)
	send "APKREPOSOPTS='$edge/main $edge/community' DISKOPTS='-m sys -k stable /dev/vda' ERASE_DISKS=/dev/vda setup-alpine -f /media/share/answers; echo SETUP=\$?:"
	answered=0 key_answered=
	until since "$start" | grep -aq 'SETUP=[0-9]*:'; do
		prompts=$(since "$start" | grep -ao 'New password:\|Retype password:' | wc -l)
		if [ "$prompts" -gt "$answered" ]; then
			answered=$((answered + 1))
			if [ "$answered" -le 2 ]; then send "$rootpw"; else send "$userpw"; fi
		fi
		if [ -z "$key_answered" ] && since "$start" | grep -aq 'ssh key or URL'; then send none; key_answered=1; fi
		running || fail 'vm exited during setup-alpine'
		sleep 1
	done
	since "$start" | grep -aq 'SETUP=0:' || fail 'setup-alpine failed'
}
provision() {
	must 'mkdir -p /media/share && mount -t vfat -o ro /dev/vdb1 /media/share'
	must 'apk update && apk add -q cage foot mesa-dri-gallium mesa-egl ttf-dejavu openssh libxkbcommon fontconfig' 600
	must 'cp /media/share/ghostty-wayland /usr/local/bin/ && chmod +x /usr/local/bin/ghostty-wayland && mkdir -p /root/.config/ghostty && cp /media/share/config /root/.config/ghostty/config'
	must 'mkdir -p /root/.ssh && cp /media/share/id_ed25519.pub /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
	must "sed -i 's|^tty1::.*|tty1::respawn:/bin/login -f root|' /etc/inittab && kill -HUP 1"
	must "printf '%s\n' 'export XDG_RUNTIME_DIR=/run' 'export WLR_RENDERER=pixman' 'export XKB_DEFAULT_LAYOUT=us' '[ \"\$(tty)\" = /dev/tty1 ] && exec cage -- /usr/local/bin/ghostty-wayland >/root/cage.log 2>&1' > /root/.profile"
	must 'rc-update add sshd default && mkdir -p /run/sshd'
}
setup() {
	clean_tree; find_qemu; fetch_iso
	[ -f "$repo/zig-out/bin/ghostty" ] || die 'build the wayland binary first (W1), then run setup'
	if [ ! -f "$key" ]; then ssh-keygen -q -t ed25519 -N '' -C ghostty-wayland-vm -f "$key"; fi
	rm -f "$work"/share/* "$work/qemu.log" "$work/monitor.sock" "$disk" "$work/vars.fd"
	cp "$repo/zig-out/bin/ghostty" "$work/share/ghostty-wayland"
	cp "$here/answers" "$work/share/answers"
	cp "$key.pub" "$work/share/id_ed25519.pub"
	printf 'font-size = 14\n' >"$work/share/config"
	qemu-img create -q -f qcow2 "$disk" 8G
	truncate -s "$(stat -c%s /usr/share/qemu/edk2-x86_64-code.fd)" "$work/vars.fd"
	qemu="$(qemu_base) -drive file=$work/$iso,if=virtio,media=cdrom,readonly=on"
	say 'installing Alpine'
	boot; login; answer_setup; poweroff
	say 'provisioning'
	qemu=$(qemu_base)
	boot; login; provision
	qemu-img snapshot -c ready "$disk"
	poweroff
	say 'saved snapshot "ready"'
}
start() {
	find_qemu
	if running; then say "already running, ssh on 127.0.0.1:$port"; return; fi
	[ -f "$disk" ] || die "$work has no disk. Run vm.sh setup first."
	qemu=$(qemu_base)
	say "booting with $accel"
	boot; wait_ssh
}
test_vm() {
	clean_tree; find_qemu
	command -v python3 >/dev/null || die 'python3 is required for the screendump check'
	qemu-img snapshot -l "$disk" 2>/dev/null | grep -q ' ready ' || die 'no "ready" snapshot. Run vm.sh setup first.'
	if running; then die 'the VM is running. Run vm.sh stop first (test boots its own VM).'; fi
	qemu=$(qemu_base)
	boot; wait_ssh
	diagnose="ps -o user,tty,args | grep -v '\\['; tail -20 /root/cage.log"
	login
	say 'waiting for cage + ghostty'
	poll 'pgrep -f "cage" >/dev/null && pgrep -f ghostty-wayland >/dev/null'
	must 'test -S /run/wayland-0'
	must 'test "$(stat -c %U /run/wayland-0)" = root'
	must '! pidof Xwayland >/dev/null'
	sleep 5
	monitor "screendump $work/desktop.ppm"; sleep 2
	nonblank "$work/desktop.ppm" || fail 'screendump is blank'
	say 'key smoke: enter adds a shell prompt line'
	monitor "screendump $work/before.ppm"; sleep 2
	monitor 'sendkey ret'; sleep 3
	monitor "screendump $work/after.ppm"; sleep 2
	if cmp -s "$work/before.ppm" "$work/after.ppm"; then fail 'key smoke changed nothing on screen'; fi
	cp "$work/after.ppm" "$work/desktop.ppm"
	poweroff
	say PASS
}
stop() {
	if ! running; then say stopped; return; fi
	guest_ssh 'poweroff' >/dev/null 2>&1 || true
	i=0
	while running && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
	if running; then kill "$(cat "$pidfile")"; sleep 1; fi
	rm -f "$pidfile"
	say stopped
}
cmd=${1:-}
if [ $# -gt 0 ]; then shift; fi
case $cmd in
setup) trap 'stop_vm' EXIT INT TERM; setup ;;
start) start ;;
test) trap 'stop_vm' EXIT INT TERM; test_vm ;;
stop) stop ;;
reset)
	if running; then die 'the VM is running. Run vm.sh stop first.'; fi
	find_qemu
	[ -f "$disk" ] || die "$work has no disk. Run vm.sh setup first."
	qemu-img snapshot -a ready "$disk"
	say 'the disk is back at the "ready" snapshot'
	;;
ssh)
	running || die 'the VM is not running. Run vm.sh start first.'
	if [ $# -eq 0 ]; then exec ssh $ssh_opts root@127.0.0.1; fi
	guest_ssh "$@"
	;;
status) if running; then echo "running, ssh on 127.0.0.1:$port"; else echo stopped; fi ;;
help | -h | --help) usage ;;
*) usage >&2; exit 2 ;;
esac
