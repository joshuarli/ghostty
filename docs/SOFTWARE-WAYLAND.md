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

The aarch64 release job uses the same flags inside an aarch64 Alpine container,
because the static `libxkbcommon.a` and host `/usr/include` must match the target.

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

The compositor receives damage from an eight-revision history ring. A stale
recycled buffer receives the union of every missed revision. A gap older than
the ring, or any missed full frame, sends a full-buffer damage rectangle.
Empty damage frames are dropped without a commit.

## Limits

The profile is Wayland-only and Linux-only. It excludes GTK, libadwaita,
GLib/GObject/GIO, X11, D-Bus clients, portals, systemd integration, desktop
notifications, global-shortcut services, quick-terminal UI, theme monitoring,
the inspector GUI, EGL, OpenGL, Vulkan, GBM, libdrm, and shader compilers.

The system clipboard is served through `wl_data_device`: text from other
Wayland clients can be pasted and copies are advertised to the compositor.
Only the standard clipboard is supported; primary selection is not. The profile
does not implement text-input-v3 IME, so composition degrades to ordinary key
events when absent.

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

Unit tests cover buffer growth, texture row updates, damage intersection,
glyph placement, opaque and translucent compositing, incremental row repaint
against a full repaint, and renderer damage detection. Runtime checks use a
headless `cage`/pixman compositor and screenshot the real executable:

```sh
XDG_RUNTIME_DIR=$PWD/.work/tmp/xdg \
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
cage -- ./zig-out/bin/ghostty -e sh -c "printf 'hello\n'; sleep 1000"
```

The QEMU acceptance path is `sh host/wayland-vm/vm.sh test`.
