#!/bin/bash
# Embed the selected Xcode's native LLVM backend, never the historical Intel blob.
set -euo pipefail

: "${TARGET_BUILD_DIR:?Run this script from the Xcode build phase}"
: "${FRAMEWORKS_FOLDER_PATH:?}"
: "${ARCHS:?}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_library=$(bash "$script_dir/find-llvm.sh")
destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/libLTO.dylib"
printf 'Embedding compiler LLVM: %s\n' "$source_library"
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
