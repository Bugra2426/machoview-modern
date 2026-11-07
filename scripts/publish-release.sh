#!/bin/bash
# Runs only in the release job after BOTH native build/package jobs succeed.
set -euo pipefail

if [[ $# != 2 ]]; then
  printf 'Usage: publish-release.sh DOWNLOADED_ARTIFACTS OUTPUT_DIRECTORY\n' >&2
  exit 2
fi
: "${GH_REPO:?}"
: "${GITHUB_EVENT_NAME:?}"
: "${GITHUB_REF:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_RUN_NUMBER:?}"
: "${DEFAULT_BRANCH:?}"
: "${RELEASE_VERSION:?}"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# macOS ships Bash 3.2: errexit does not reject bare [[ ... ]] compound
# commands there as it does in newer Bash. Every guard must exit explicitly.
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'RELEASE_VERSION must use MAJOR.MINOR.PATCH.'
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'GITHUB_SHA must be a full 40-character commit hash.'
[[ "$GITHUB_RUN_NUMBER" =~ ^[0-9]+$ ]] || fail 'GITHUB_RUN_NUMBER must be numeric.'

# Defense in depth: dispatches, PRs, and non-default branch pushes never publish.
if [[ "$GITHUB_EVENT_NAME" != push ]]; then
  printf 'error: Only push events may publish releases.\n' >&2
  exit 1
fi
if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  release_tag="${GITHUB_REF#refs/tags/}"
  [[ "$release_tag" == "v$RELEASE_VERSION" ]] || fail "Release tag must match v$RELEASE_VERSION exactly."
  release_title="MachOView $release_tag"
  release_options=(--verify-tag)
  release_summary='Stable version-tagged release.'
elif [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]]; then
  release_tag="build-$GITHUB_RUN_NUMBER"
  release_title="MachOView $RELEASE_VERSION — preview build $GITHUB_RUN_NUMBER"
  release_options=(--target "$GITHUB_SHA" --prerelease --latest=false)
  release_summary='Automated preview from the default branch, not a stable release.'
else
  printf 'error: Only version tags or the default branch may publish.\n' >&2
  exit 1
fi

source_dir=$1
dist=$2
[[ -d "$source_dir" ]] || fail "Downloaded artifact directory does not exist: $source_dir"
if [[ -e "$dist" || -L "$dist" ]]; then
  printf 'error: Refusing to overwrite output directory: %s\n' "$dist" >&2
  exit 1
fi

# Require precisely the expected format/baseline pairs, not any arbitrary files
# returned by a recursive glob. Missing one OS or one format aborts publication.
assets=()
for baseline in macos-15 macos-26; do
  for extension in dmg zip; do
    name="MachOView-$RELEASE_VERSION-$baseline-arm64.$extension"
    input="$source_dir/MachOView-$baseline-arm64/$name"
    if [[ ! -s "$input" || -L "$input" ]]; then
      printf 'error: Missing tested release asset: %s\n' "$input" >&2
      exit 1
    fi
    assets+=("$input")
  done
done
mkdir -p "$dist"
for asset in "${assets[@]}"; do
  cp "$asset" "$dist/"
done
(cd "$dist" && shasum -a 256 ./*.dmg ./*.zip > SHA256SUMS.txt)

notes="$dist/RELEASE_NOTES.md"
printf '%s\n\n' "$release_summary" > "$notes"
printf '%s\n' \
  '## Install' \
  '' \
  '- **macOS 15 or later:** choose the `macos-15-arm64.dmg` build.' \
  '- **macOS 26 or later:** either build works; `macos-26-arm64.dmg` uses the newer toolchain/baseline.' \
  '- Open the DMG, drag **MachOView** to **Applications**, then eject the disk image.' \
  '- ZIP downloads are also provided. `SHA256SUMS.txt` covers all four downloads.' \
  '' \
  '## Build and security' \
  '' \
  'Native Apple Silicon (arm64), optimized Release builds. No Rosetta, Xcode, or Homebrew is needed to run the app.' \
  'Both macOS builds, native regression tests, and DMG verification must pass before this release is published.' \
  '' \
  '**Ad-hoc signed, not Developer ID signed or Apple notarized.** If macOS blocks opening, verify that you trust the download and use the app-specific Privacy & Security → Open Anyway option if offered. Do not disable Gatekeeper globally.' \
  '' \
  'The custom DMG does not redesign the app UI; Dark Mode remains partial. See README.md for parser and appearance limitations.' >> "$notes"
printf '\nSource commit: `%s`\n' "$GITHUB_SHA" >> "$notes"

# Intentionally do not edit an existing release or clobber published assets.
# A new run gets a new preview tag; stable releases need a new version tag.
gh release create "$release_tag" "$dist"/*.dmg "$dist"/*.zip "$dist/SHA256SUMS.txt" \
  "${release_options[@]}" --title "$release_title" --generate-notes --notes-file "$notes"
