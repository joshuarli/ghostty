# Buckling Spring soundpack

Recordings by Thomas Lai, from the [kbsim](https://github.com/th0ma7/kbsim) project, MIT License.
The license text is `LICENSE-kbsim.md` in this directory and is linked into the
macOS binary.

`buckling-spring.rvpack` is the predecoded rvpack v1 pack. Ghostty does not
decode audio at build time or at runtime. The file is the output of Klack's
offline pack builder (`cargo xtask packs` in the klack repository), which
reads `assets/soundpacks/catalog.json` and the kbsim MP3s, trims and
normalizes them, and writes mono `i16` PCM with guard samples.

To regenerate from a checkout of joshuarli/klack:

```
cargo xtask packs
cp target/packs/buckling-spring.rvpack <ghostty>/src/sound/assets/buckling-spring.rvpack
```

The pack id is `buckling-spring`. It is the only pack this build plays.
