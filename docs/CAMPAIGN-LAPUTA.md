# Campaign: Laputa — minimal Wayland runtime for Ghostty

## Status

Goal: `src/apprt/wayland/` native Wayland runtime in this fork, musl, no GTK/X11/D-Bus, single window, GPU dmabuf + shm fallback, QEMU-proven.
Base: `d1b1ba52c`, tree at W5. Accepted: L0-W5 (fractional-scale/viewporter plumbing with graceful absence, Kitty-graphics shm run clean exit, forced-shm fallback never crashes, renderer/dmabuf/fractional tests green). Red: none. Parked: none.
Next: W6 (ReleaseFast musl size triage) || Q1 (QEMU harness) in parallel.
Resume: `/burn-down-the-backlog docs/CAMPAIGN-LAPUTA.md` from clean tree; first command `sh .work/smoke-graphics.sh`.

## Charter

- Decide and keep going. Record a decision only when a later slice depends on it.
- Within the execution grant, proceed without approval. Park items needing outside authority.
- Hard stops park the item: irreversible or outside-repo actions, forbidden boundaries, uncheckable loops. Pushing is forbidden.
- Fix egregious breakage met on the way in its own commit to numeric thresholds below. Otherwise record and leave.
- Parity before optimization. Size/polish gates only in P4.
- One writer by default. Parallel lanes only for the disjoint pairs in Sequence, in `.work/wt/<lane>`, never `/tmp`, per orchestrate worktree lifecycle.
- Every commit is Conventional Commit with workstream scope; item ID in body. Code comments never cite this doc.
- After each accepted slice run the parent steering checkpoint; rewrite Status in place. Git history is the log.

## Decisions

Owner-decided (from goal brief, 2026-10-30):
- Additive runtime: keep GTK backend intact, add `-Dapp-runtime=wayland`. No replacement.
- Single window, no tabs/splits/inspector GUI, no D-Bus/portals/notifications/systemd.
- Mostly-static musl + dynamic EGL/Mesa drivers; keep FreeType+HarfBuzz+Fontconfig. Fully-static EGL is a non-goal.

Prescribed (code settles it, overrule with reason):
- Reuse `renderer/OpenGL`, `Device` surfaceless EGL, `Target.exportDmabuf` + `readPixelsAlloc` verbatim; new code is only the Wayland present path. Renderer has zero GTK imports; only consumer is `gtk/class/render_surface.zig`.
- Protocol set: `wl_compositor, xdg_wm_base, wl_seat, zwp_linux_dmabuf_v1, wp_viewporter/fractional-scale, xdg-activation`. Drop kde/vicinae/slide/layer-shell.
- QEMU harness merges `.github/scripts/freebsd-vm/vm.sh` lifecycle with `~/usr/host/alpine/tests/vm.sh` serial/monitor helpers; native x86_64 Alpine + `cage`, pixman, KVM, `-display none`, `screendump` oracle.
- Loop: narrowest suite per slice; full suite only at M1/M2/close.

Delegated (executor decides, smallest reversible assumption, log it):
- Exact `wayland/App.zig` structure within the ~15-fn `App/Surface` contract, bound: no new cross-runtime shared types.
- Cage vs weston-headless for local (non-QEMU) smoke, bound: must run without host compositor changes.
- Fontconfig elimination sketch stays a P4 note, bound: no behavior change before close.

## Baseline

Known red: none established; tree clean at `d1b1ba52c`. Top commits are local tweaks (`35369bcdb` personal defaults, `73f54a1fe` key-sound) — rebase risk noted, not red.
Loop timings (2026-10-30, this x86_64 Linux host): `zig: NOT INSTALLED` (need >=0.17.0 per `build.zig.zon`), no `zig-out/`, no `.zig-cache/`; proxy `200x git rev-parse HEAD = 0.56s`. First build is cold-cache + LLVM link, the critical path. QEMU `11.1.2` present, `nc`+`qemu-img` present, edk2 `x86_64`+`aarch64` firmware present.
Numbers the goal moves (set by L0, targets in Acceptance): GTK/x11 ldd closure, wayland `readelf -d` closure, RSS idle, binary bytes.

## Sequence

P0 ground. L0 provisions Zig 0.17.0+, records GTK baseline (size, ldd, configure+build seconds). No parallel work until W1 lands.

- L0 provision+baseline. Owns: nothing (env) + this doc Status. Prereq: none. Accept: `zig version | grep -q 0.17 && zig build -Dapp-runtime=gtk -Demit-themes=false -Di18n=false -Doptimize=Debug && ls -lh zig-out/bin/ghostty && ldd zig-out/bin/ghostty | tee .work/baseline-ldd.txt`.
- W1 runtime stub + build gate. Owns: `src/apprt/runtime.zig`, `src/apprt.zig`, `src/build_config.zig`, `src/build/Config.zig`, `src/build/SharedDeps.zig`, `src/apprt/wayland/*`. Prereq: L0. Accept: `zig build -Dapp-runtime=wayland -Dtarget=x86_64-linux-musl -Demit-themes=false -Di18n=false && readelf -d zig-out/bin/ghostty | tee .work/wayland-dyn.txt && ! grep -Ei 'gtk|adwaita|gobject|X11' .work/wayland-dyn.txt`.

P1 parity, serial (all share `src/apprt/wayland/` + renderer contract). May parallelize with Q-harness skeleton only (disjoint: `host/wayland-vm/*`).

- W2 window+present. Owns: `src/apprt/wayland/{App,Surface,present}.zig`, scanner protocol list. Prereq: W1. Accept: `zig build -Dapp-runtime=wayland && zig build test -Dtest-filter=wayland && WAYLAND_DISPLAY=test .work/smoke-present.sh` (headless compositor, opens 800x600, dmabuf or shm frame, resize, exit 0; blank-screen fails).
- W3 input+clipboard. Owns: `src/apprt/wayland/{seat,keyboard,pointer,clipboard}.zig`. Prereq: W2. Accept: `zig build test -Dtest-filter='wayland.*input|kitty|clipboard' && .work/smoke-input.sh` (xkb layout, modifiers, repeat, Kitty encode, paste roundtrip; mismatch fails).
- W4 config/single-window parity, no-desktop-baggage. Owns: `src/apprt/wayland/config.zig`, action allowlist. Prereq: W3. Accept: `zig-out/bin/ghostty +show-config >/dev/null && zig-out/bin/ghostty --version | grep -q wayland && ! strings zig-out/bin/ghostty | grep -Ei 'org\.gtk\.Actions|libadwaita'`.

P2 hardening (serial on `src/apprt/wayland/`).

- W5 scaling+graphics+fallback. Owns: `src/apprt/wayland/*`. Prereq: W4. Accept: `zig build test -Dtest-filter='renderer|dmabuf|fractional' && .work/smoke-graphics.sh` (fractional 150%, Kitty graphics, animation frame, forced-shm fallback all render; `DmabufBuildFailed` must fall back, never crash).

P3 optimization + QEMU harness build-out. Disjoint pair: W6 (tree: `src/`, build flags) || Q1 (tree: `host/wayland-vm/`) may run parallel once W5 green.

- W6 size/static triage. Owns: build flags, docs. Prereq: W5. Accept: `zig build -Dapp-runtime=wayland -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast -Dstrip=true -Demit-themes=false -Di18n=false && ls -l zig-out/bin/ghostty && readelf -d zig-out/bin/ghostty | ! grep -Ei 'gtk|adwaita|X11'` + RSS logged (`ps -o rss` idle < GTK baseline).
- Q1 QEMU harness. Owns: `host/wayland-vm/{vm.sh,answers,smoke.sh}` only. Prereq: W1 (binary to test); full pass needs W5. Accept: `sh host/wayland-vm/vm.sh test` PASS (boots Alpine x86_64 KVM, cage+pixman, autologin, ghostty-wayland opens, `screendump` non-blank, wayland socket owned, `! pidof Xwayland`, key smoke adds a shell prompt line).

Milestones: M1 after W4 (narrow suites + `zig build test-lib-vt`); M2 after W6+Q1 (full `zig build test` + Q1 PASS). Red tree blocks new slices. Attempt cap 3 per slice, then park on branch with cause + retry condition.

## Acceptance

- D1 Wayland binary exists, GTK-free: `readelf -d zig-out/bin/ghostty` shows no `libgtk-4|libadwaita|libglib-2.0|X11`; `ldd` subset of GTK baseline. Fail: any listed NEEDED present.
- D2 Single window opens under Wayland, renders text: Q1 `screendump` ppm differs from blank by >2% pixels and `pgrep -f ghostty-wayland` alive. Fail: blank or exit !=0.
- D3 Present path correct: dmabuf presented when compositor advertises `zwp_linux_dmabuf_v1`, else shm `readPixelsAlloc` fallback with identical sRGB bytes (±1 LSB). Fail: crash on forced-shm or `DmabufBuildFailed` without fallback.
- D4 Input correct: en-US layout, modifiers, repeat, Kitty keyboard encode/decode roundtrip, clipboard paste == copy bytes. Fail: any byte mismatch.
- D5 musl mostly-static: `file zig-out/bin/ghostty` reports static-pie or musl with only `libEGL/libwayland-client/libxkbcommon/c` dynamic; `strip=true` ReleaseFast boots in Q1. Fail: GTK/X11 NEEDED or Q1 boot fail.
- D6 QEMU harness reproducible: `sh host/wayland-vm/vm.sh test` PASS twice from clean `.work/vm` with checksummed guest image; console log tail on failure + `failure.ppm` saved. Fail: second run needs manual steps.

## Needs environment

- Physical HiDPI fractional-scale eyeball (150%/200% on real panel): owner runs Q1 guest with `-device virtio-gpu-pci,xres=3840,yres=2160` and compares `desktop.ppm` to eyeball. Local proof is `smoke-graphics.sh` only.
- Real GPU EGL (virtio-gpu virgl vs pixman): default harness forces `WLR_RENDERER=pixman`; owner with GPU runs `WLR_RENDERER=gles2 sh host/wayland-vm/vm.sh test`.

## Execution boundary and non-goals

Authorized: provision Zig 0.17.0+ via pinned channel; edit `src/apprt/wayland/*`, `src/apprt/{runtime,}.zig`, `src/build*`, `host/wayland-vm/*`, `docs/CAMPAIGN-LAPUTA.md` Status; run `zig build`, `zig build test*`, QEMU with KVM on this host; download Alpine virt ISO + apk packages with sha256 check.
Forbidden: `git push`, replacing/removing GTK backend, changing pinned dep URLs/hashes without owner note, host network/DNS changes, touching `~` outside repo, `/tmp` for worktrees/scratch (use `.work/`), adding CI workflows.
Non-goals: tabs/splits/tab-overview, D-Bus single-instance/portals/notifications, X11 backend, libadwaita/GResource/blueprint, fully-static EGL/Mesa, `libghostty-vt` renderer rewrite, foot-parity software renderer.
Contract changes for owner: new `-Dapp-runtime=wayland` value; `Action` allowlist limited to `new_window/close/quit` in wayland runtime; no D-Bus activation contract.

## Reference

Verified map (all at `d1b1ba52c`):
- `src/apprt/runtime.zig:5-24` enum `{none,gtk}`, default gtk on linux/freebsd.
- `src/apprt.zig:43-50` comptime `runtime` switch; `src/build_config.zig:41` forwards `app_runtime`; `src/main_ghostty.zig:77,104-114` init/run/terminate.
- `src/build/Config.zig:202-206` `-Dapp-runtime`, `:256-266` `-Dgtk-wayland/-Dgtk-x11` (GTK-only wording to generalize).
- `src/build/SharedDeps.zig:672-678` EGL link gated on `.gtk`, `:697-700` `switch app_runtime {.none,.gtk}`, `:711-882` `addGtk` (gobject `:719-737`, x11 `:755-772`, wayland scanner `:774-864`, gresource `:866-881`).
- Renderer reuse: `src/renderer/OpenGL.zig:52-90` surfaceless-agnostic context, `:277-324` `ExportedFrame{memory|dmabuf}`; `src/renderer/opengl/Device.zig:37-74` `SURFACELESS_MESA` + injectable `Options.display`; `src/renderer/opengl/Target.zig:148-215` `exportDmabuf`, `:224-242` `readPixelsAlloc`; `src/renderer/Dmabuf.zig:10-75` wire format. Zero GTK imports in `src/renderer/`.
- Sole GTK consumer: `src/apprt/gtk/class/render_surface.zig:149-175` `takeFrame`, `:307-365` dmabuf builder + `DmabufBuildFailed`, `:390-429` shm `GdkMemoryTexture` fallback — mirror for Wayland present.
- Exhaustive `app_runtime` switches to arm: `src/input/Binding.zig:995`, `src/datastruct/split_tree.zig:1332`, `src/config/Config.zig:4941,9021,9419,10141`, `src/apprt/{surface:174,structs:47+53+216,action:733}`, `src/font/face.zig:61`, `src/terminal/mouse.zig:84`, `src/cli/version.zig:45-49`.
- Deps pinned: `build.zig.zon:57-59` zig_wayland, `:104-110` wayland_protocols; no existing `src/apprt/wayland/`.
- Harness prior art: `.github/scripts/freebsd-vm/vm.sh:351-381,383-417` daemonize/pidfile/ssh-wait/stop, `:437-444` snapshot; `test-freebsd.sh:1-92` proves cross-built test binaries in-VM; `~/usr/host/alpine/tests/vm.sh:38-66` `wait_for/send/run/must/poll`, `:78-88` serial fifo bridge, `:206-221` cage-like dwl+foot + `screendump` + `! pidof Xwayland`, `:115-141` accel/firmware/virtio-gpu flags.
