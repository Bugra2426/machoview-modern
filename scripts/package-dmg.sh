#!/bin/bash
# Headless drag-to-Applications packaging; no Finder/AppleScript or app launches.
# Requires a reviewed, preinstalled dmgbuild==1.6.7 (Python >=3.10) and Xcode's
# command-line tools. Dependency metadata: https://pypi.org/project/dmgbuild/1.6.7/
# This script NEVER installs dependencies, changes the app, or re-signs it.
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/package-dmg.sh APP OUTPUT.dmg [ARCH]' \
    '' \
    'APP must be a complete, signed MachOView.app. ARCH defaults to arm64;' \
    'x86_64 is also accepted. OUTPUT must not exist; its parent must exist' \
    'on a filesystem supporting hard links (for atomic no-clobber publication).' \
    '' \
    'Requires macOS 15 or later, Xcode command-line tools, Python 3.10+ and' \
    'dmgbuild==1.6.7 already installed on PATH. No Finder/login session needed.' \
    'Dependency setup is a separate, explicitly authorized step; for example,' \
    'inside a dedicated Python virtual environment:' \
    "  python3 -m pip install 'dmgbuild==1.6.7'" \
    '' \
    'The source and read-only mounted copy are checked with verify-app.sh.' \
    'Neither the source app nor the mounted app is executed. No notarization' \
    'or signing is performed; supply the final signed/stapled bundle.'
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

app_input="${1%/}"
output_input="$2"
architecture="${3:-arm64}"
case "$architecture" in arm64|x86_64) ;; *) fail 'ARCH must be arm64 or x86_64.' ;; esac
case "$app_input$output_input" in *$'\n'*|*$'\r'*) fail 'Paths must not contain newlines.' ;; esac
[[ -n "$app_input" && -d "$app_input" && ! -L "$app_input" ]] || fail 'APP must be a real app directory, not a symlink.'
app="$(cd -- "$app_input" && pwd -P)"
[[ "${app##*/}" == MachOView.app ]] || fail 'APP must be named MachOView.app.'
[[ -f "$app/Contents/Info.plist" && -f "$app/Contents/MacOS/MachOView" ]] || fail 'APP is not a complete MachOView bundle.'
[[ "$output_input" == *.dmg ]] || fail 'OUTPUT must end in .dmg.'
[[ ! -e "$output_input" && ! -L "$output_input" ]] || fail "Refusing existing output: $output_input"
output_parent="$(dirname -- "$output_input")"
[[ -d "$output_parent" ]] || fail 'The output parent directory must already exist.'
output_parent="$(cd -- "$output_parent" && pwd -P)"
output="$output_parent/$(basename -- "$output_input")"
case "$output_parent" in "$app"|"$app"/*) fail 'OUTPUT must not be inside the source app.' ;; esac
[[ -w "$output_parent" ]] || fail 'The output parent directory is not writable.'
[[ "$(uname -s)" == Darwin ]] || fail 'DMG packaging requires macOS (15 or later).'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
settings="$script_dir/dmg-settings.py"
artwork="$script_dir/../packaging/dmg-background.swift"
verifier="$script_dir/verify-app.sh"
[[ -f "$settings" && -f "$artwork" && -f "$verifier" ]] || fail 'Required packaging source files are missing.'
python="$(command -v python3)" || fail 'Python 3.10+ is required on PATH.'
"$python" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || fail 'Python 3.10+ is required.'
dmgbuild="$(command -v dmgbuild)" || fail "dmgbuild==1.6.7 must be preinstalled. See --help for a separate dependency setup example; nothing was installed."
# dmgbuild 1.6.7 has no --version option. The separately reviewed installation
# pin controls its version; do not inspect a potentially different Python env.
# Xcode 26 CI environments can put Metal first in TOOLCHAINS. Select Swift's
# toolchain explicitly for both discovery and rendering.
/usr/bin/xcrun --sdk macosx --toolchain com.apple.dt.toolchain.XcodeDefault --find swift >/dev/null || fail 'Xcode command-line tools (Swift) are required.'

# Verify before generating anything. Verification reads the app; it never runs it.
/bin/bash "$verifier" "$app" "$architecture"

work=""
mount_attempted=0
mountpoint=""
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "$mount_attempted" -eq 1 ]]; then
    # Never recursively remove a directory that might still be a mounted image.
    # A failed/partial attach is treated conservatively, too. Do not force-unmount.
    if ! /usr/bin/hdiutil detach "$mountpoint" >/dev/null 2>&1; then
      printf 'error: Could not detach %s; retained temporary files at %s.\n' "$mountpoint" "$work" >&2
      printf 'Detach the volume before removing that directory.\n' >&2
      [[ "$status" -ne 0 ]] || status=1
      exit "$status"
    fi
  fi
  if [[ -n "$work" ]]; then
    # dmgbuild also mounts an intermediate image. If it failed before detaching,
    # never delete its mountpoint or backing file. Unknown mount state is unsafe.
    if ! /usr/bin/hdiutil info -plist > "$work/attached-images.plist" ||
       ! "$python" -I - "$work" "$work/attached-images.plist" <<'PY'
import os
import plistlib
import sys

root = os.path.realpath(sys.argv[1]) + os.sep
with open(sys.argv[2], "rb") as stream:
    images = plistlib.load(stream)["images"]
for image in images:
    paths = [image.get("image-path", ""), image.get("shadow-path", "")]
    paths += [entity.get("mount-point", "") for entity in image.get("system-entities", [])]
    if any(path and (os.path.realpath(path) + os.sep).startswith(root) for path in paths):
        raise SystemExit("A temporary disk image is still attached.")
PY
    then
      printf 'error: Cannot safely remove temporary files at %s; inspect hdiutil info and detach any associated images first.\n' "$work" >&2
      [[ "$status" -ne 0 ]] || status=1
      exit "$status"
    fi
    /bin/rm -rf -- "$work"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep the image on the destination filesystem so publication can be atomic.
work="$(/usr/bin/mktemp -d "$output_parent/.machoview-dmg.XXXXXX")"
mountpoint="$work/mounted"
/bin/mkdir "$mountpoint" "$work/tmp" "$work/module-cache"
background="$work/background.tiff"
image="$work/MachOView.dmg"

# Native AppKit drawing only; no GUI process or third-party artwork libraries.
TMPDIR="$work/tmp" CLANG_MODULE_CACHE_PATH="$work/module-cache" \
  /usr/bin/xcrun --sdk macosx --toolchain com.apple.dt.toolchain.XcodeDefault swift \
    -module-cache-path "$work/module-cache" "$artwork" "$background"

# dmgbuild authors .DS_Store directly, avoiding Finder's asynchronous GUI state.
# It copies the bundle without us editing any resources or re-signing anything.
TMPDIR="$work/tmp" "$dmgbuild" -s "$settings" \
  -D "app=$app" -D "background=$background" 'MachOView' "$image"
[[ -s "$image" ]] || fail 'dmgbuild did not produce a nonempty image.'
/usr/bin/hdiutil verify "$image"

# The final compressed artifact is checked read-only, not its writable build image.
mount_attempted=1
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -owners on \
  -mountpoint "$mountpoint" "$image" >/dev/null
[[ -L "$mountpoint/Applications" ]] || fail 'The image is missing its Applications link.'
[[ "$(/usr/bin/readlink "$mountpoint/Applications")" == /Applications ]] || fail 'The Applications link has an unexpected target.'
[[ -s "$mountpoint/.DS_Store" ]] || fail 'The image is missing its Finder layout.'
[[ -d "$mountpoint/MachOView.app" && ! -L "$mountpoint/MachOView.app" ]] || fail 'The image is missing the copied app.'
/bin/bash "$verifier" "$mountpoint/MachOView.app" "$architecture"
# Check copied bytes as well as the copied code signature and dependencies.
/usr/bin/diff -qr "$app" "$mountpoint/MachOView.app"
/usr/bin/hdiutil detach "$mountpoint"
mount_attempted=0

# os.link is exclusive even if another process creates OUTPUT during the build.
# Unlike ln/mv command-line tools, a directory destination is never reinterpreted.
"$python" -I - "$image" "$output" <<'PY'
import os
import sys

try:
    os.link(sys.argv[1], sys.argv[2])
except OSError as error:
    raise SystemExit(f"error: Could not publish DMG without overwriting: {error}")
PY
printf 'Packaged and verified: %s\n' "$output"
