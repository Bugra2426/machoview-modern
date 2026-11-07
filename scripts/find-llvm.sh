#!/bin/bash
# Print libLTO from the compiler toolchain of the Xcode driving this build.
set -euo pipefail

# Xcode 26 can put the Metal toolchain first in TOOLCHAINS and TOOLCHAIN_DIR.
# DT_TOOLCHAIN_DIR still identifies the default compiler toolchain. Do not use
# TOOLCHAIN_DIR, the historical repository library, or a different active Xcode.
if [[ -n "${DT_TOOLCHAIN_DIR:-}" ]]; then
  candidate="${DT_TOOLCHAIN_DIR}/usr/lib/libLTO.dylib"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

# Older/custom build environments may omit DT_TOOLCHAIN_DIR. Keep the fallback
# anchored to the same Xcode, not xcode-select's potentially different default.
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  candidate="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/lib/libLTO.dylib"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

printf 'error: No libLTO in the selected Xcode compiler toolchain.\n' >&2
printf 'DT_TOOLCHAIN_DIR=%s\nDEVELOPER_DIR=%s\n' "${DT_TOOLCHAIN_DIR:-<unset>}" "${DEVELOPER_DIR:-<unset>}" >&2
printf 'Select a full Xcode installation containing XcodeDefault.xctoolchain/usr/lib/libLTO.dylib.\n' >&2
exit 1
