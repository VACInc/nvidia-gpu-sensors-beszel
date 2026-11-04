#!/usr/bin/env bash
# gpu-health-watch must finish (log, save state) when nvidia-smi hangs, and a
# down ntfy server must cost one send timeout per run, not one per alert.
# Usage: tests/health-runtime.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log"
export FIXTURE_ROOT="$T"
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
[[ ! -e "$FIXTURE_ROOT/hang" ]] || exec sleep 60
case "$1" in
    --query-gpu=*) printf '0, Fixture GPU, 00000000:41:00.0, 60, 20, 40, 0, 0, %s, 0\n' "$(cat "$FIXTURE_ROOT/hwt")" ;;
    -q) printf 'GPU 00000000:41:00.0\n    Replays Since Reset : %s\n' "$(cat "$FIXTURE_ROOT/replay")" ;;
esac
SH
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >>"$FIXTURE_ROOT/attempts"
exit 28
SH
chmod +x "$T/bin/"*
printf 'NTFY_URL=https://ntfy.invalid/fixture\n' >"$T/ntfy.env"
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2; exit 1; }
run() {
    GPU_HEALTH_MODE=nvidia GPU_HEALTH_PATH_PREFIX="$T/bin" GPU_HEALTH_HELPER="$T/missing" \
    GPU_HEALTH_LOG_DIR="$T/log" GPU_HEALTH_STATE_DIR="$T/state" \
    GPU_HEALTH_NTFY_ENV="$T/ntfy.env" GPU_HEALTH_PCI_SYSFS="$T/pci" \
    GPU_HEALTH_CMD_TIMEOUT=1 bash "$HERE/health/gpu-health-watch.sh"
}

# Hung nvidia-smi: the run is bounded, the failure is logged, state is saved.
touch "$T/hang"
start=$SECONDS; run
(( SECONDS - start < 15 )) || fail "run not bounded: $(( SECONDS - start )) s"
grep -q 'nvidia-smi-query-failed rc=124' "$T"/log/* || fail "query failure not logged"
[[ -s "$T/state/state" ]] || fail "state not saved"
rm "$T/hang"
echo "ok - hung nvidia-smi bounded and logged"

# Two alert keys pending while ntfy is down: one attempt per run.
echo 0 >"$T/hwt"; echo 0 >"$T/replay"
echo 'LAST_ERRPOLL=0' >>"$T/state/state"; run
echo 40000000 >"$T/hwt"; echo 3 >"$T/replay"
echo 'LAST_ERRPOLL=0' >>"$T/state/state"; run
# shellcheck disable=SC1091
( source "$T/state/state"; [[ ${#PENDING_TITLE[@]} == 2 ]] ) || fail "expected two pending alerts"
[[ $(wc -l <"$T/attempts") == 1 ]] || fail "sent $(wc -l <"$T/attempts") times while ntfy down"
# The one not tried stays due and goes first on the next run.
run
[[ $(wc -l <"$T/attempts") == 2 ]] || fail "deferred alert not retried next run"
echo "ok - one send attempt per run while ntfy is down"
