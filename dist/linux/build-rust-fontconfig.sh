#!/bin/sh
set -eu

VERSION=5.0.2
TAG=v5.0.2-laputa.2
SHA256=f8ae910d451336d2241821af5748abcbf547559fd083b73eefd097eb7558f593
SONAME="librust_fontconfig.so.$VERSION"
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 3 "https://github.com/laputa-systems/rust-fontconfig/archive/refs/tags/$TAG.tar.gz" -o "$WORK/src.tar.gz"
echo "$SHA256  $WORK/src.tar.gz" | sha256sum -c -
tar -xzf "$WORK/src.tar.gz" -C "$WORK"
tree="$WORK/rust-fontconfig-${TAG#v}"
cp "$HERE/rust-fontconfig.Cargo.lock" "$tree/Cargo.lock"
printf '\n[workspace]\n' >>"$tree/Cargo.toml"

(
    cd "$tree"
    RUSTFLAGS="-C target-feature=-crt-static -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-soname,$SONAME" \
    CARGO_TARGET_DIR="$WORK/target" \
    cargo rustc --locked --release --lib --crate-type cdylib \
        --no-default-features --features ffi \
        --config 'profile.release.lto="fat"' \
        --config 'profile.release.opt-level="s"' \
        --config 'profile.release.codegen-units=1'
)

install -D -m 755 "$WORK/target/release/librust_fontconfig.so" "/usr/lib/$SONAME"
ln -sfn "$SONAME" /usr/lib/librust_fontconfig.so
install -D -m 644 "$tree/ffi/rust_fontconfig.h" /usr/include/rust-fontconfig/rust_fontconfig.h
install -d /usr/lib/pkgconfig
cat >/usr/lib/pkgconfig/rust-fontconfig.pc <<PC
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include/rust-fontconfig

Name: rust-fontconfig
Description: Pure-Rust font discovery, matching, and fallback with a C API
Version: $VERSION
Libs: -L\${libdir} -lrust_fontconfig
Cflags: -I\${includedir}
PC
