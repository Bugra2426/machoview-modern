#!/bin/bash
# Verify the exact bundle that will be distributed, not just the executable.
set -euo pipefail
app="${1:?Usage: verify-app.sh APP [ARCH]}"
architecture="${2:-arm64}"
executable="$app/Contents/MacOS/MachOView"
backend="$app/Contents/Frameworks/libLTO.dylib"

test -f "$executable"
test -f "$backend"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/lipo "$executable" -verify_arch "$architecture"
/usr/bin/lipo "$backend" -verify_arch "$architecture"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

# Reject hidden Intel-only helpers and build-machine dependencies, including
# @rpath dependencies that are not actually bundled. Keep this list explicit.
while IFS= read -r -d '' binary; do
  if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/lipo "$binary" -verify_arch "$architecture"
    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/lib/*|/System/Library/*|@rpath/libLTO.dylib) ;;
        *) printf 'error: Unbundled dependency in %s: %s\n' "$binary" "$dependency" >&2; exit 1 ;;
      esac
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/awk '/^\t/ {print $1}')
  fi
done < <(find "$app" -type f -print0)
printf 'Verified %s bundle: %s\n' "$architecture" "$app"
