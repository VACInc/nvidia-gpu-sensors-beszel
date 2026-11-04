#!/usr/bin/env bash
# ntfy.env handling in health/gpu-health-watch.sh: parsed, never executed;
# credentials and topic URL quoted into curl's config, never on argv.
# Usage: tests/health-ntfy.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log"
export FIXTURE_ROOT="$T"
echo 0 >"$T/hwt"
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
case "$1" in
    --query-gpu=*) printf '3, Fixture GPU, 00000000:41:00.0, 85, 20, 40, 0, 0, %s, 0\n' "$(cat "$FIXTURE_ROOT/hwt")" ;;
esac
SH
# Fake curl: record argv and the --config contents.
cat >"$T/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FIXTURE_ROOT/argv"
while (( $# )); do
    [[ "$1" == --config ]] && cat "$2" >>"$FIXTURE_ROOT/config"
    shift
done
exit 0
SH
chmod +x "$T/bin/"*
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2 || true; exit 1; }
run() {
    GPU_HEALTH_MODE=nvidia GPU_HEALTH_PATH_PREFIX="$T/bin" GPU_HEALTH_HELPER="$T/missing" \
    GPU_HEALTH_LOG_DIR="$T/log" GPU_HEALTH_STATE_DIR="$T/state" \
    GPU_HEALTH_NTFY_ENV="$T/ntfy.env" GPU_HEALTH_PCI_SYSFS="$T/pci" \
        bash "$HERE/health/gpu-health-watch.sh"
}
slowdown() {  # fresh state, then 40 s of hw thermal slowdown -> one delivery
    rm -rf "$T/state" "$T/argv" "$T/config"; mkdir -p "$T/state"
    echo 0 >"$T/hwt"; run
    echo 40000000 >"$T/hwt"; run
}

{
    echo '# comment'
    echo "touch $T/pwned-line"
    echo "NTFY_URL=\$(touch $T/pwned-subst)"
    echo 'export NTFY_URL="https://ntfy.invalid/secret-topic"'
    echo "NTFY_AUTH='alice:p\"a\\ss\$(touch $T/pwned-auth)'"
} >"$T/ntfy.env"
slowdown
for f in pwned-line pwned-subst pwned-auth; do
    [[ ! -e "$T/$f" ]] || fail "ntfy.env executed ($f)"
done
[[ -s "$T/argv" ]] || fail "no delivery"
if grep -q 'secret-topic\|alice' "$T/argv"; then fail "URL or credential on curl argv"; fi
grep -q -- '--proto =https,http' "$T/argv" || fail "protocol not restricted"
grep -Fqx 'url = "https://ntfy.invalid/secret-topic"' "$T/config" || fail "url config: $(cat "$T/config")"
grep -Fqx "user = \"alice:p\\\"a\\\\ss\$(touch $T/pwned-auth)\"" "$T/config" || fail "user not escaped: $(cat "$T/config")"
echo "ok - ntfy.env parsed not executed, values quoted for curl"

# Unquoted value, trailing blanks, CRLF line ending and no NTFY_AUTH: no user line.
printf 'NTFY_URL=https://ntfy.invalid/t2  \r\n' >"$T/ntfy.env"
slowdown
grep -Fqx 'url = "https://ntfy.invalid/t2"' "$T/config" || fail "unquoted url: $(cat "$T/config")"
if grep -q '^user' "$T/config"; then fail "empty credential sent"; fi
echo "ok - plain values and optional auth"
