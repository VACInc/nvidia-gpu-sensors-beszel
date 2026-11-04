#!/usr/bin/env bash
# The Beszel agent release (VACInc/beszel supplemental/scripts/
# package-gpu-hotspot-helper.sh) bundles beszel/update-hwmon.sh after this
# exact rewrite, and fails the release if the rewritten line is missing.
# Usage: tests/packaging-contract.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

sed 's|^BIN=/opt/gpu-hotspot/bin/nvidia-gpu-sensors$|BIN=/opt/gpu-hotspot/.beszel-release/bin/nvidia-gpu-sensors|' \
    "$HERE/beszel/update-hwmon.sh" >"$T/update-hwmon.sh"
grep -Fqx 'BIN=/opt/gpu-hotspot/.beszel-release/bin/nvidia-gpu-sensors' "$T/update-hwmon.sh" \
    || fail "packager rewrite of the BIN line no longer applies"
echo "ok - packager rewrite applies"

# The rewritten script must default to the bundled binary, and the test
# override must still win. Evaluate just its BIN assignments.
grep -E '^BIN=' "$T/update-hwmon.sh" >"$T/bin.sh"
# shellcheck disable=SC2016  # literal line for the generated script
echo 'echo "$BIN"' >>"$T/bin.sh"
[[ $(env -u GPU_HOTSPOT_BIN bash "$T/bin.sh") == /opt/gpu-hotspot/.beszel-release/bin/nvidia-gpu-sensors ]] \
    || fail "rewritten script does not default to the bundled binary"
[[ $(GPU_HOTSPOT_BIN=/x/tool bash "$T/bin.sh") == /x/tool ]] \
    || fail "GPU_HOTSPOT_BIN override lost"
echo "ok - bundled binary is the default, override still wins"
