#!/usr/bin/env bash
# Run every test: strict build, shellcheck (if installed), each tests/*.c
# under ASan/UBSan, and each tests/*.sh. Needs no GPU. Usage: tests/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$HERE"
CC=${CC:-gcc}
failed=0
step() { printf '== %s\n' "$*"; }

step "build (warnings are errors)"
"$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -o "$T/nvidia-gpu-sensors" src/nvidia-gpu-sensors.c

if command -v shellcheck >/dev/null 2>&1; then
    step shellcheck
    find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck
else
    step "shellcheck not installed: skipped"
fi

for t in tests/*.c; do
    step "$t"
    "$CC" -std=gnu11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
        -fno-sanitize-recover=all -o "$T/test" "$t"
    "$T/test" || { echo "FAILED: $t" >&2; failed=1; }
done

for t in tests/*.sh; do
    [[ "$t" == tests/run.sh ]] && continue
    step "$t"
    bash "$t" || { echo "FAILED: $t" >&2; failed=1; }
done

(( failed == 0 )) && echo "all tests passed"
exit "$failed"
