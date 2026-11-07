#!/bin/sh
# Run portable loader/output tests on Linux or macOS; no SDK or libLTO needed.
set -eu
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/disasm-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM
cc=${CC:-clang}
"$cc" -std=c11 -Wall -Wextra -Werror -pthread -I"$src" \
    "$src/tests/llvm_loader_test.c" -o "$build/loader"
for mode in missing incomplete minimal legacy modern; do
    "$build/loader" "$mode"
done
"$cc" -std=c11 -Wall -Wextra -Werror -pthread -I"$src" \
    "$src/tests/disasm_output_test.c" "$src/disasm_output.c" -o "$build/output"
"$build/output"
if [ "$#" -gt 0 ]; then
    "$cc" -std=c11 -Wall -Wextra -Werror -pthread -I"$src" \
        "$src/tests/llvm_backend_test.c" -ldl -o "$build/backend"
    "$build/backend" "$1"
fi
