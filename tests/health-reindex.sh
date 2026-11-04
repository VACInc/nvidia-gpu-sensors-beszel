#!/usr/bin/env bash
# gpu-health-watch keys state by nvidia-smi index. When a GPU drops off the
# bus the remaining cards are renumbered; another card's lifetime counters
# must not be read as a sudden rise. Usage: tests/health-reindex.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log"
export FIXTURE_ROOT="$T"
# query rows: idx, bus, hw thermal us. -q rows: bus, replays.
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
case "$1" in
    --query-gpu=*)
        while read -r idx bus hwt; do
            printf '%s, Fixture GPU, 00000000:%s:00.0, 60, 20, 40, 0, 0, %s, 0\n' "$idx" "$bus" "$hwt"
        done <"$FIXTURE_ROOT/gpus" ;;
    -q)
        while read -r bus replay; do
            printf 'GPU 00000000:%s:00.0\n    Replays Since Reset : %s\n' "$bus" "$replay"
        done <"$FIXTURE_ROOT/replays" ;;
esac
SH
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_ROOT/delivered"
SH
chmod +x "$T/bin/"*
printf 'NTFY_URL=https://ntfy.invalid/fixture\n' >"$T/ntfy.env"
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2; exit 1; }
run() {
    GPU_HEALTH_MODE=nvidia GPU_HEALTH_PATH_PREFIX="$T/bin" GPU_HEALTH_HELPER="$T/missing" \
    GPU_HEALTH_LOG_DIR="$T/log" GPU_HEALTH_STATE_DIR="$T/state" \
    GPU_HEALTH_NTFY_ENV="$T/ntfy.env" GPU_HEALTH_PCI_SYSFS="$T/pci" \
        bash "$HERE/health/gpu-health-watch.sh"
}
poll() { echo 'LAST_ERRPOLL=0' >>"$T/state/state"; run; }

# Two cards; the second has 900 s of hw thermal time and 50 replays from
# earlier in its uptime.
printf '0 41 0\n1 42 900000000\n' >"$T/gpus"
printf '41 0\n42 50\n' >"$T/replays"
run
# Card 41 falls off the bus; card 42 becomes index 0 with unchanged counters.
printf '0 42 900000000\n' >"$T/gpus"
printf '42 50\n' >"$T/replays"
poll
[[ ! -e "$T/delivered" ]] || fail "renumbered card's lifetime counters alerted: $(cat "$T/delivered")"
grep -q 'gpu=0 bdf=0000:42:00.0 previous_bdf=0000:41:00.0 state=reset' "$T"/log/* || fail "reset not logged"
echo "ok - renumbered card does not inherit another card's baselines"

# Real rises on the renumbered card still alert.
printf '0 42 940000000\n' >"$T/gpus"
printf '42 53\n' >"$T/replays"
poll
grep -q 'Title: GPU slowdown' "$T/delivered" || fail "slowdown after renumbering missed"
grep -q 'PCIe replays +3 (total 53)' "$T/delivered" || fail "replay rise after renumbering missed"
echo "ok - rises after renumbering still alert"
