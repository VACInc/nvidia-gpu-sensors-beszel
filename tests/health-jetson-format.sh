#!/usr/bin/env bash
# Jetson log line formatting: no readable zone and sub-zero zones.
# Usage: tests/health-jetson-format.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/th" "$T/hw" "$T/state" "$T/log"
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2; exit 1; }
run() {
    GPU_HEALTH_MODE=jetson GPU_HEALTH_LOG_DIR="$T/log" GPU_HEALTH_STATE_DIR="$T/state" \
    GPU_HEALTH_NTFY_ENV="$T/absent.env" GPU_HEALTH_THERMAL_SYSFS="$T/th" \
    GPU_HEALTH_HWMON_SYSFS="$T/hw" bash "$HERE/health/gpu-health-watch.sh"
}
# Every zone gated (no temp file): no sentinel arithmetic in the log.
mkdir -p "$T/th/thermal_zone0"; echo gpu-thermal >"$T/th/thermal_zone0/type"
run
grep -q 'jetson hottest=na hot=na throttle_margin=na' "$T"/log/* || fail "no-zone line"
# Sub-zero readings keep their sign and a valid decimal.
echo -500 >"$T/th/thermal_zone0/temp"; run
grep -q 'jetson hottest=gpu hot=-0.5 throttle_margin=99 .*zones="gpu=-0.5"' "$T"/log/* || fail "sub-zero line"
echo -12300 >"$T/th/thermal_zone0/temp"; run
grep -q 'hot=-12.3 .*zones="gpu=-12.3"' "$T"/log/* || fail "negative line"
echo "ok - jetson temperatures formatted"
