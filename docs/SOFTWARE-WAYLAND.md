# CPU Software Wayland Profile

This profile runs Ghostty's terminal core as a single-window Wayland terminal
with a CPU rasterizer and `wl_shm` presentation. It does not create an EGL or
OpenGL context, read pixels back from a GPU, or load Mesa's software GL driver.

## Build

Native debug build:

```sh
zig build -Dapp-runtime=wayland -Drenderer=software
```

Static musl release build for x86_64:

```sh
zig build -Dapp-runtime=wayland -Drenderer=software \
  -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast -Dstrip=true \
  -Demit-themes=false -Di18n=false -Dcpu=baseline
```

The release workflow publishes this build for x86_64 as its own artifact,
`ghostty-custom-software-x86_64-linux-musl.tar.gz`, after running the Wayland and
renderer tests and checking for zero `PT_INTERP` and `DT_NEEDED` entries. The
build needs `libxkbcommon-static` and `libffi-dev` on Alpine. An aarch64 static
artifact is not built yet: the static `libxkbcommon.a` and host `/usr/include`
must match the target, so it needs a native aarch64 Alpine build.

The executable has no `PT_INTERP` and no `DT_NEEDED` entries:

```sh
readelf -l zig-out/bin/ghostty | grep INTERP
readelf -d zig-out/bin/ghostty | grep NEEDED
```

Both commands print nothing. Check the artifact itself, not only its symbol
table:

```sh
file zig-out/bin/ghostty
```

The static build compiles the pinned Wayland client sources because Alpine's
`wayland-static` archive contains GCC LTO objects that lld cannot consume. It
links `libxkbcommon.a` and `libffi.a` for the same musl target. Fontconfig,
FreeType, HarfBuzz, and the terminal core are already linked from source.

## Renderer Boundary

`-Drenderer=software` selects `src/renderer/Software.zig` through the existing
`GenericRenderer` interface. The terminal parser, screen and scrollback, PTY,
configuration, keyboard encoding, font discovery, HarfBuzz shaping, glyph
atlases, Kitty image decoding, overlays, and search state remain the existing
Ghostty implementations.

The software backend supplies only the graphics API surface:

- CPU buffers for uniforms, cell backgrounds, cell text, images, and background
  images.
- CPU textures for grayscale and BGRA font atlases and RGBA images.
- A target holding top-left RGBA8 pixels with premultiplied alpha.
- A rasterizer for background color, cell backgrounds, glyphs, Kitty images,
  background images, clipping, and alpha blending.

The target is sRGB encoded. The default `linear-corrected` blending decodes to
16-bit linear channels, blends there, and re-encodes. Text coverage correction
uses the same luminance mapping as the GPU shaders. The `native` mode blends in
encoded space.

Custom GLSL and CRT shaders are a GPU-profile feature. The software profile
logs `custom shaders are unsupported by this renderer; ignoring them` and keeps
running with the built-in raster pipeline.

## Presentation

`src/apprt/wayland/window.zig` owns at most three `wl_shm` buffers. Each buffer
has its own memfd and pool, is never resized while busy, and is marked busy
until the compositor sends `wl_buffer.release`. A `wl_surface.frame` callback
paces frames but does not authorize buffer reuse.

`src/renderer/software/Damage.zig` describes changed pixel rows. The renderer
keeps a snapshot of cell backgrounds and text instances, repaints changed rows
with one row of overhang on each side, and falls back to a full frame for:

- geometry, scale, font metrics, palette, or uniform changes;
- first use, resize, or an invalid target;
- Kitty images, overlays, or background images;
- damage that spans more than 64 row runs.

The target and the frames handed to the apprt are top-down. `Software.present`
snapshots the target once, because the render thread keeps drawing into it, and
`Window.presentMemory` writes into the shared-memory buffer from that snapshot.
A buffer that the damage history can repair receives only the damaged
rectangles; otherwise the whole frame is copied. The OpenGL profile's readback
is bottom-up and is still flipped whole.

The compositor receives damage from an eight-revision history ring. A stale
recycled buffer receives the union of every missed revision. A gap older than
the ring, or any missed full frame, sends a full-buffer damage rectangle.
Empty damage frames are dropped without a commit.

## Sound

Keyboard sound and the terminal bell play through ALSA, by talking to the
kernel's PCM devices (`/dev/snd/pcmC*D*p`) with ioctls. There is no libasound,
PulseAudio, PipeWire, or sound-server dependency, and the static build stays
static. The structs and ioctl numbers in `src/sound/alsa.zig` mirror
`sound/asound.h`, and the negotiation follows tinyalsa.

- `keyboard-sound` and its `keyboard-sound-*` options select and shape the
  buckling-spring sounds, which are keyed by physical key. Ctrl+Shift stands in
  for the command key that triggers the copy, paste, cut, and undo chimes.
- `bell-features = audio` rings the terminal bell. `bell-audio-path` names an
  uncompressed PCM or float WAV file, and an unset or unplayable path plays a
  short built-in tone. `bell-audio-volume` sets its volume, independent of
  `keyboard-sound-volume`, and the bell sounds whether or not the window is
  focused.
- `sound-device = hw:CARD,DEVICE` picks the device. Unset, the first free
  playback device that is not an HDMI or DisplayPort output is used.

This is plain hardware access with no mixing plugin, so it cannot play while
another program holds the device, and it needs permission for `/dev/snd`,
usually the `audio` group. Ghostty opens the device when a sound is queued and
releases it two seconds after the last one, and it logs a warning when the
device is busy or missing. Sounds queued while the device is unavailable are
dropped, not replayed later. Sound settings are read at startup and are not
applied on configuration reload.

## Limits

The profile is Wayland-only and Linux-only. It excludes GTK, libadwaita,
GLib/GObject/GIO, X11, D-Bus clients, portals, systemd integration, desktop
notifications, global-shortcut services, quick-terminal UI, theme monitoring,
the inspector GUI, EGL, OpenGL, Vulkan, GBM, libdrm, and shader compilers.

The system clipboard is served through `wl_data_device`: text from other
Wayland clients can be pasted and copies are advertised to the compositor.
Only the standard clipboard is supported; primary selection is not.

Keys repeat on the client from the compositor's `wl_keyboard.repeat_info`; a
compositor that reports no rate gets no repeat. Keyboard focus follows
`wl_keyboard` enter and leave only.

Input methods use text-input-v3 when the compositor offers it. The client
enables it while the keyboard holds focus, declares a terminal content type, and
reports the cursor cell as the candidate window anchor. Preedit text is drawn at
the cursor and committed text is sent as input with no key attached. Surrounding
text and `delete_surrounding_text` are not supported. Without the protocol,
composition degrades to ordinary key events.

The OpenGL profile (`-Drenderer=opengl` with `-Dapp-runtime=wayland`) keeps
Ghostty's GPU renderer and custom shaders but does not negotiate DMA-BUF with
the compositor. It reports GPU presentation as unhealthy so frames are read
back to CPU memory and presented through `wl_shm`; it is not a zero-copy path.

The profile needs a Wayland compositor, fonts discoverable by Fontconfig,
compose data when used, a shell, and a PTY device. Static linkage does not
remove those runtime requirements.

## Prior Art

The CPU rasterizer adapts the sRGB/linear blending and coverage-cache approach
from Monstar at commit
`203e1013b184b47e6c0482671882bb791aba21f3`,
`src/pixel_raster.zig` (MIT, Copyright (c) 2026 Tim Culverhouse). The port
changes the color storage to Ghostty's RGBA target, uses Ghostty's existing
glyph atlas and draw list, and does not copy Monstar's application, font
discovery, PTY, or configuration layers.

Monstar's `ShmBuffer.zig`, `Window.zig`, `AsyncRaster.zig`,
`AsyncJobSnapshot.zig`, `FrameDamageTracker.zig`, and `CellDamageTracker.zig`
informed the ownership model: bounded buffer count, explicit busy state,
stale-buffer full repaint, and immutable draw snapshots. Ghostty's render thread
and single latest-frame queue replace Monstar's separate raster scheduler.

## Verification

The Wayland apprt tests run with
`zig build test -Dapp-runtime=wayland -Drenderer=software -Dtest-filter=wayland`.
The software backend's tests run with
`zig build test -Dapp-runtime=wayland -Drenderer=software -Dtest-filter=renderer`.
Unit tests cover key repeat timing, damage-only buffer repair, buffer growth,
texture row updates, damage intersection, glyph placement, opaque and
translucent compositing, incremental row repaint against a full repaint, and
renderer damage detection.

`src/renderer/software/reference_test.zig` holds a floating-point reference
transcribed from the GLSL shaders and the blend state they run under. It renders
whole scenes and compares them with the rasterizer pixel by pixel, in native,
linear, and linear-corrected blending, within a few levels of 8-bit rounding.
Scenes cover translucent text and backgrounds, combining marks, box drawing,
wide glyphs with a wide cursor, color glyphs, minimum contrast, Kitty images at
fractional offsets, and background images in every fit, position, and repeat
mode. It shares no code with `raster.zig`, so a mismatch means the rasterizer
drifted from the shaders. Runtime checks use a headless `cage`/pixman compositor
and screenshot the real executable:

```sh
XDG_RUNTIME_DIR=$PWD/.work/tmp/xdg \
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
cage -- ./zig-out/bin/ghostty -e sh -c "printf 'hello\n'; sleep 1000"
```

`sh host/wayland-fake/run.sh` runs the binary against a scripted compositor built
on libwayland-server. It checks the text-input-v3 traffic and rendering, that
losing the compositor ends in an error exit rather than an abort, and that a
compositor without ABGR8888 is refused with that reason.

The QEMU acceptance path is `sh host/wayland-vm/vm.sh test`.
