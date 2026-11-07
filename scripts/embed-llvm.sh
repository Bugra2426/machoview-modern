#!/bin/bash
# Embed the selected Xcode's native LLVM backend, never the historical Intel blob.
set -euo pipefail

: "${TOOLCHAIN_DIR:?Run this script from the Xcode build phase}"
: "${TARGET_BUILD_DIR:?}"
: "${FRAMEWORKS_FOLDER_PATH:?}"
: "${ARCHS:?}"
source_library="${TOOLCHAIN_DIR}/usr/lib/libLTO.dylib"
destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/libLTO.dylib"

if [[ ! -f "$source_library" ]]; then
  printf 'error: Selected Xcode has no libLTO: %s\n' "$source_library" >&2
  exit 1
fi
# An Intel-only dependency must fail the build, rather than fail at launch.
for architecture in $ARCHS; do
  /usr/bin/lipo "$source_library" -verify_arch "$architecture"
done

mkdir -p "$(dirname "$destination")"
/usr/bin/ditto "$source_library" "$destination"
chmod u+w "$destination"
/usr/bin/install_name_tool -id '@rpath/libLTO.dylib' "$destination"

# Xcode's libLTO is normally standalone apart from macOS system libraries.
# Refuse to ship an app that quietly depends on the builder's Xcode installation.
while IFS= read -r dependency; do
  case "$dependency" in
    @rpath/libLTO.dylib|/usr/lib/*|/System/Library/*) ;;
    *) printf 'error: libLTO has an unbundled dependency: %s\n' "$dependency" >&2; exit 1 ;;
  esac
done < <(/usr/bin/otool -L "$destination" | /usr/bin/awk '/^\t/ {print $1}')

# Signing outside-in: nested library now, application by Xcode afterward.
# Ad-hoc signing needs no Apple account, but does not confer notarization.
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$destination"
