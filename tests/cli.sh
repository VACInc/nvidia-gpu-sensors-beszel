#!/usr/bin/env bash
# Option parsing of nvidia-gpu-sensors (runs before any device access, so it
# needs no GPU). Usage: tests/cli.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
gcc -std=gnu11 -O2 -Wall -Wextra -o "$T/ngs" "$HERE/src/nvidia-gpu-sensors.c"

"$T/ngs" --help >"$T/out" || fail "--help exit status"
grep -q -- '--detail' "$T/out" || fail "--help text"

rc=0; "$T/ngs" --cvs >"$T/out" 2>"$T/err" || rc=$?
[[ $rc == 2 ]] || fail "unknown option exit status $rc"
grep -q "unknown option '--cvs'" "$T/err" || fail "unknown option message"
[[ ! -s "$T/out" ]] || fail "unknown option wrote to stdout"

rc=0; "$T/ngs" --csv extra >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "stray argument accepted"
echo "ok - cli rejects unknown options"
