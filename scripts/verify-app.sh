#!/bin/bash
# Verify the exact bundle that will be distributed, not just the executable.
set -euo pipefail
app="${1:?Usage: verify-app.sh APP [universal|arm64|x86_64]}"
architecture="${2:-universal}"
case "$architecture" in
  universal) architectures=(arm64 x86_64) ;;
  arm64|x86_64) architectures=("$architecture") ;;
  *) printf 'error: ARCH must be universal, arm64, or x86_64.\n' >&2; exit 1 ;;
esac
executable="$app/Contents/MacOS/MachOView"
backend="$app/Contents/Frameworks/libLTO.dylib"

test -f "$executable"
test -f "$backend"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/lipo "$executable" -verify_arch "${architectures[@]}"
/usr/bin/lipo "$backend" -verify_arch "${architectures[@]}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

# Reject hidden Intel-only helpers and build-machine dependencies, including
# @rpath dependencies that are not actually bundled. Keep this list explicit.
while IFS= read -r -d '' binary; do
  if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/lipo "$binary" -verify_arch "${architectures[@]}"
    # Inspect all slices, not just the architecture of the verification host.
    dependencies=$(/usr/bin/otool -arch all -L "$binary")
    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/lib/*|/System/Library/*|@rpath/libLTO.dylib) ;;
        *) printf 'error: Unbundled dependency in %s: %s\n' "$binary" "$dependency" >&2; exit 1 ;;
      esac
    done < <(printf '%s\n' "$dependencies" | /usr/bin/awk '/^\t/ {print $1}')
  fi
done < <(find "$app" -type f -print0)
printf 'Verified %s bundle: %s\n' "$architecture" "$app"
