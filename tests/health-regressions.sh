#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export FIXTURE_ROOT="$T"
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
case "$1" in
    --query-gpu=*) printf '3, Fixture GPU, 00000000:41:00.0, %s, 20, 40, 0, %s, %s, 0\n' "$(cat "$FIXTURE_ROOT/core")" "$(cat "$FIXTURE_ROOT/swt")" "$(cat "$FIXTURE_ROOT/hwt")" ;;
    -q) printf 'GPU 00000000:41:00.0\n Replays Since Reset : %s\n Replay Number Rollovers : %s\n' "$(cat "$FIXTURE_ROOT/replay")" "$(cat "$FIXTURE_ROOT/roll")" ;;
    nvlink) cat "$FIXTURE_ROOT/nvlink" ;;
esac
SH
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >>"$FIXTURE_ROOT/attempts"
[[ $(cat "$FIXTURE_ROOT/send") == success ]] || exit 22
printf '%s\n' "$*" >>"$FIXTURE_ROOT/delivered"
SH
chmod +x "$T/bin/"*
printf 'NTFY_URL=https://ntfy.invalid/fixture\nNTFY_AUTH=fixture\n' >"$T/ntfy.env"
fail() { echo "FAIL: $*" >&2; exit 1; }
reset_case() {
    mkdir -p "$T/$1/state" "$T/$1/log"
    STATE_DIR="$T/$1/state" LOG_DIR="$T/$1/log"
    echo 85 >"$T/core"
    for c in swt hwt replay roll; do echo 0 >"$T/$c"; done
    : >"$T/nvlink"; : >"$T/attempts"; : >"$T/delivered"
    echo success >"$T/send"
}
run() {
    GPU_HEALTH_MODE=nvidia GPU_HEALTH_PATH_PREFIX="$T/bin" GPU_HEALTH_HELPER="$T/missing" \
    GPU_HEALTH_LOG_DIR="$LOG_DIR" GPU_HEALTH_STATE_DIR="$STATE_DIR" \
    GPU_HEALTH_NTFY_ENV="$T/ntfy.env" GPU_HEALTH_PCI_SYSFS="$T/pci" \
      bash "$HERE/health/gpu-health-watch.sh"
}
poll() { echo 'LAST_ERRPOLL=0' >>"$STATE_DIR/state"; run; }
retry_due() { echo 'LAST_ATTEMPT=()' >>"$STATE_DIR/state"; }

# One-shot errors must survive failed delivery even with no further rise.
reset_case delivery
run
echo fail >"$T/send"; echo 3 >"$T/replay"; poll
[[ $(wc -l <"$T/attempts") == 1 ]] || fail "first send attempt"
( source "$STATE_DIR/state"; [[ -z ${LAST_ALERT[gpu3.pcie]:-} ]] ) || fail "failure consumed cooldown"
run
[[ $(wc -l <"$T/attempts") == 1 ]] || fail "retry was not bounded"
echo success >"$T/send"; retry_due; run
[[ $(wc -l <"$T/attempts") == 2 ]] || fail "failed counter event not retried"
grep -q 'PCIe replays +3' "$T/delivered" || fail "retry body lost"
( source "$STATE_DIR/state"; [[ -n ${LAST_ALERT[gpu3.pcie]:-} && ${#PENDING_TITLE[@]} == 0 ]] ) || fail "success did not consume cooldown"
echo 4 >"$T/replay"; retry_due; poll
[[ $(wc -l <"$T/attempts") == 2 ]] || fail "success cooldown ignored"
echo 'ok - failed delivery retries once due, then cooldown'

# New metrics in the same family must not overwrite undelivered one-shot
# faults. Repeated rises coalesce without an unbounded message queue.
reset_case coalescing
mkdir -p "$T/pci/0000:41:00.0"
echo 'TOTAL_ERR_FATAL 0' >"$T/pci/0000:41:00.0/aer_dev_fatal"
run
echo fail >"$T/send"
echo 'TOTAL_ERR_FATAL 1' >"$T/pci/0000:41:00.0/aer_dev_fatal"; poll
echo 3 >"$T/replay"; poll
echo 8 >"$T/replay"; poll
( source "$STATE_DIR/state"; [[ ${#PENDING_DETAILS[@]} == 2 ]] ) || fail "pending counters not bounded by kind"
echo success >"$T/send"; retry_due; run
grep -q 'AER fatal +1 (total 1)' "$T/delivered" || fail "one-shot fatal event overwritten"
grep -q 'PCIe replays +8 (total 8)' "$T/delivered" || fail "pending replay rises not coalesced"
( source "$STATE_DIR/state"; [[ ${#PENDING_DETAILS[@]} == 0 && ${#PENDING_RISE[@]} == 0 ]] ) || fail "delivered counters retained"
echo 'ok - distinct pending counters preserved, repeated rises coalesced'

reset_case rollovers
echo 900 >"$T/replay"; echo 7 >"$T/roll"; run
echo 903 >"$T/replay"; echo 8 >"$T/roll"; poll
grep -q 'PCIe replays +3 (total 903)' "$T/delivered" || fail "independent replay delta"
grep -q 'PCIe replay rollovers +1 (total 8)' "$T/delivered" || fail "independent rollover delta"
grep -q '100000' "$T/delivered" && fail "fabricated replay delta"
# Reset replay independently while rollover rises again.
echo 'LAST_ALERT=()' >>"$STATE_DIR/state"; retry_due
echo 1 >"$T/replay"; echo 9 >"$T/roll"; poll
grep -q 'PCIe replay rollovers +1 (total 9)' "$T/delivered" || fail "rollover hidden by replay reset"
echo 'ok - replay and rollover deltas independent'

for temp in '[N/A]' '' garbage 69 70 85; do
    reset_case "temp-${temp:-empty}"
    echo "$temp" >"$T/core"; run
    echo 40000000 >"$T/swt"; run
    case "$temp" in
        70|85) grep -q 'GPU slowdown' "$T/delivered" || fail "warm temp did not count: $temp" ;;
        *) [[ ! -s "$T/delivered" ]] || fail "invalid/cool temp counted: $temp" ;;
    esac
done
reset_case unknown-hardware
echo '[N/A]' >"$T/core"; run; echo 40000000 >"$T/hwt"; run
grep -q 'GPU slowdown' "$T/delivered" || fail "invalid core must not gate hardware slowdown"
echo 'ok - software thermal requires valid hot core, hardware independent'

for gen in 1 2 3 4 5; do
    reset_case "nvlink$gen"
    sed -e 's/@COUNT@/0/g' -e 's/@TRAFFIC@/10/g' "$HERE/tests/fixtures/nvlink$gen.txt" >"$T/nvlink"
    run
    sed -e 's/@COUNT@/0/g' -e 's/@TRAFFIC@/1000000/g' "$HERE/tests/fixtures/nvlink$gen.txt" >"$T/nvlink"
    poll
    [[ ! -s "$T/delivered" ]] || fail "NVLink $gen traffic counted as errors"
    sed -e 's/@COUNT@/2/g' -e 's/@TRAFFIC@/1000001/g' "$HERE/tests/fixtures/nvlink$gen.txt" >"$T/nvlink"
    poll
    grep -q 'GPU NVLink errors' "$T/delivered" || fail "NVLink $gen errors missed"
    if [[ $gen == 5 ]]; then
        for label in 'Malformed packet Errors' 'Buffer overrun Errors' 'Rx Errors' 'Rx remote Errors' 'Rx General Errors' 'Local link integrity Errors' 'Tx discards' 'Link recovery successful events' 'Link recovery failed events' 'Effective Errors'; do
            grep -Fq "NVLink $label +2" "$T/delivered" || fail "NVLink5 $label missed"
        done
        for n in {0..15}; do
            grep -Fq "NVLink FEC Errors - $n +2" "$T/delivered" || fail "FEC bucket $n missed"
        done
    else
        for label in Replay Recovery CRC; do
            grep -Fq "NVLink $label Errors +4" "$T/delivered" || fail "NVLink $gen $label link aggregation"
        done
    fi
    grep -Eq 'NVLink (Tx bytes|Rx bytes|Tx packets|Rx packets|Effective BER|Symbol BER)' "$T/delivered" && fail "traffic or rate in alert"
    echo "ok - NVLink $gen error counters only"
done
