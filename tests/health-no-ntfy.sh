#!/usr/bin/env bash
# Without /etc/ntfy.env alerts are logged only: once per key per cooldown,
# not re-logged every minute forever. Usage: tests/health-no-ntfy.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log"
export FIXTURE_ROOT="$T"
echo 0 >"$T/replay"
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
case "$1" in
    --query-gpu=*) echo '0, Fixture GPU, 00000000:41:00.0, 60, 20, 40, 0, 0, 0, 0' ;;
    -q) printf 'GPU 00000000:41:00.0\n    Replays Since Reset : %s\n' "$(cat "$FIXTURE_ROOT/replay")" ;;
esac
SH
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl must not run without ntfy.env" >&2; exit 1
SH
chmod +x "$T/bin/"*
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2; exit 1; }
run() {
    GPU_HEALTH_MODE=nvidia GPU_HEALTH_PATH_PREFIX="$T/bin" GPU_HEALTH_HELPER="$T/missing" \
    GPU_HEALTH_LOG_DIR="$T/log" GPU_HEALTH_STATE_DIR="$T/state" \
    GPU_HEALTH_NTFY_ENV="$T/absent.env" GPU_HEALTH_PCI_SYSFS="$T/pci" \
        bash "$HERE/health/gpu-health-watch.sh"
}
# Simulate an hour of runs a minute apart by clearing the retry clock.
later() { echo 'LAST_ATTEMPT=()' >>"$T/state/state"; run; }

run
echo 2 >"$T/replay"; echo 'LAST_ERRPOLL=0' >>"$T/state/state"; run
for _ in 1 2 3 4 5; do later; done
n=$(grep -c 'alert-not-sent reason=no-ntfy-env key=gpu0.pcie' "$T"/log/*)
[[ $n == 1 ]] || fail "logged $n times"
grep -q 'alert key=gpu0.pcie .*PCIe replays +2' "$T"/log/* || fail "alert not logged"
# shellcheck disable=SC1091
( source "$T/state/state"; [[ ${#PENDING_TITLE[@]} == 0 && -n ${LAST_ALERT[gpu0.pcie]:-} ]] ) \
    || fail "alert kept pending or cooldown not started"
echo "ok - without ntfy alerts are logged once per cooldown"
