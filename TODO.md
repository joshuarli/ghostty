Prefix: GHO
Next: 2
### GHO-1 · P1 · musl release binaries need librust_fontconfig that the release does not ship

- **Area:** Linux release
- **Where:** `.github/workflows/release.yml`, `dist/linux/build-rust-fontconfig.sh` (since c4f036c)
- **Problem:** Release `release-c4f036c721c3e48f02568222b5f3dfbc86acd817` publishes `ghostty-custom-<arch>-linux-musl.tar.gz` with a `ghostty` binary whose NEEDED list includes `librust_fontconfig.so.5.0.2`, but the tarball holds only the binary and no Alpine package provides the library. On Alpine edge x86_64 the extracted binary fails at load: `Error loading shared library librust_fontconfig.so.5.0.2: No such file or directory (needed by ./ghostty)`, then unresolved `fc_*` symbols. Reproduce: download that asset, `tar -xzf` it, run `./ghostty --version`. The usr Alpine provisioner (`host/alpine/build/ghostty.sh`) installs the newest `release-*` prerelease and expects a single self-contained binary, so every desktop provision fails at its `+ssh --terminfo=true` export and usr's `host/alpine/tests/vm.sh` cannot pass its desktop layer on either architecture. The release verification checks NEEDED but never runs the extracted binary.
- **Recommendation:** Link rust-fontconfig statically into the musl binaries (or otherwise make the published tarball self-contained), and make the release job run the extracted binary's `--version`, `+show-config` and `+ssh --terminfo=true` on a clean Alpine edge container before publishing. Acceptance: a new `release-*` asset whose `ghostty` passes those three commands on clean Alpine edge with only usr `host/alpine/packages-desktop.txt` installed, and usr `VM_ARCH=x86_64 sh host/alpine/tests/vm.sh` passes its desktop layer.
- **Fix with:** none
- **Effort:** S

