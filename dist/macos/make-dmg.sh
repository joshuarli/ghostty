#!/usr/bin/env bash
# Build a drag-to-Applications DMG from a .app bundle.
# No Apple Developer account, signing identity, or third-party tools required.
# Uses only /usr/bin/hdiutil + ditto (both ship with macOS).
#
# Usage:
#   dist/macos/make-dmg.sh <path-to-.app> <output.dmg> [Volume Name]
#
# Example:
#   dist/macos/make-dmg.sh "macos/build/ReleaseLocal/Ghostty.app" \
#     "Ghostty-Custom-aarch64-apple-darwin.dmg" "Ghostty Custom"
set -euo pipefail

APP_SRC="${1:?path to .app required}"
OUT_DMG="${2:?output .dmg path required}"
VOLNAME="${3:-$(basename "$APP_SRC" .app)}"

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: app not found: $APP_SRC" >&2
  exit 1
fi

STAGE="$(mktemp -d /tmp/ghostty-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

APP_NAME="$(basename "$APP_SRC")"

# ditto preserves resource forks, xattrs, and the ad-hoc signature.
# cp -R does not; don't swap this out.
/usr/bin/ditto "$APP_SRC" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<EOF
Ghostty Custom — first launch
-----------------------------
1. Drag "$APP_NAME" onto Applications.
2. Eject this disk image, open Applications in Finder.
3. Right-click "$APP_NAME" > Open, then click Open.
   (One time only. This build is ad-hoc signed, not notarized,
   so Gatekeeper blocks a plain double-click.)

Why: Apple only skips that warning for Developer ID-signed +
notarized apps, which needs a paid Apple Developer account.
This DMG removes the unzip + Terminal (xattr -cr) steps,
but it can't remove the one-time Right-click > Open.
EOF

rm -f "$OUT_DMG"
/usr/bin/hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUT_DMG" >/dev/null

/usr/bin/hdiutil verify "$OUT_DMG" >/dev/null
echo "created: $OUT_DMG"
