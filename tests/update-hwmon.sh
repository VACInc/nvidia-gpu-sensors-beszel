#!/usr/bin/env bash
# Exercise beszel/update-hwmon.sh against a fake nvidia-smi, sensor tool and
# /sys/class/hwmon. Usage: tests/update-hwmon.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sys/hwmon0" "$T/sys/hwmon1"
echo k10temp >"$T/sys/hwmon0/name"; echo nvme >"$T/sys/hwmon1/name"
export FIXTURE_ROOT="$T"
cat >"$T/bin/nvidia-smi" <<'SH'
#!/usr/bin/env bash
cat "$FIXTURE_ROOT/smi"
SH
cat >"$T/tool" <<'SH'
#!/usr/bin/env bash
[[ "$1" == --csv ]] || exit 2
[[ ! -e "$FIXTURE_ROOT/hang" ]] || sleep 30
cat "$FIXTURE_ROOT/csv"
SH
chmod +x "$T/bin/nvidia-smi" "$T/tool"
HW="$T/root/class/hwmon"
fail() { echo "FAIL: $*" >&2; ls -l "$HW" >&2 || true; exit 1; }
run() {
    PATH="$T/bin:$PATH" GPU_HOTSPOT_ROOT="$T/root" GPU_HOTSPOT_BIN="$T/tool" \
        GPU_HOTSPOT_SYS_HWMON="$T/sys" GPU_HOTSPOT_READ_TIMEOUT=2 \
        bash "$HERE/beszel/update-hwmon.sh"
}
val() { cat "$HW/hwmon$1/temp1_input"; }

cat >"$T/smi" <<'EOF2'
0, NVIDIA GeForce RTX 5090, 00000000:01:00.0, 25
1, NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 00000000:41:00.0, [N/A]
3, NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 00000000:42:00.0, -3
EOF2
cat >"$T/csv" <<'EOF2'
0000:01:00.0,40.0,,48.6,0.805,
0000:41:00.0,37.1,38.0,64.1,0.805,
0000:42:00.0,37.1,40.5,41.6,0.805,
EOF2
run
[[ -L "$HW/hwmon0" && -L "$HW/hwmon1" ]] || fail "real hwmon not mirrored"
[[ $(cat "$HW/hwmon900/name") == "GeForce RTX 5090 Hotspot" ]] || fail "single-name display"
[[ ! -e "$HW/hwmon901" ]] || fail "VRAM sensor without a reading"
[[ $(cat "$HW/hwmon902/name") == "RTX PRO 6000 Blackwell Workstation Edition 1 Hotspot" ]] || fail "shared-name index"
[[ $(val 902) == 64100 ]] || fail "64.1 C rounding: $(val 902)"
[[ $(val 907) == 40500 ]] || fail "VRAM value"
[[ $(val 980) == 25000 && $(val 983) == -3000 ]] || fail "T.Limit values"
[[ ! -e "$HW/hwmon981" ]] || fail "[N/A] T.Limit published"
echo "ok - sensors published with exact millidegrees"

# A real hwmon device that disappears must not leave a dangling mirror.
rm -rf "$T/sys/hwmon1"; run
[[ ! -e "$HW/hwmon1" && ! -L "$HW/hwmon1" ]] || fail "stale mirror kept"
[[ -L "$HW/hwmon0" ]] || fail "live mirror removed"
echo "ok - mirrors of removed hwmon devices dropped"

# Malformed readings and indices are skipped, never written as 0 C.
cat >"$T/smi" <<'EOF2'
0, NVIDIA GeForce RTX 5090, 00000000:01:00.0, 25
x[$(touch${IFS}pwned)], NVIDIA Bad, 00000000:02:00.0, 1
99, NVIDIA Too High, 00000000:03:00.0, 1
EOF2
cat >"$T/csv" <<'EOF2'
0000:01:00.0,40.0,garbage,48.6x,0.805,
0000:02:00.0,40.0,,50.0,0.805,
0000:03:00.0,40.0,,50.0,0.805,
EOF2
( cd "$T" && run )
[[ ! -e "$T/pwned" ]] || fail "index evaluated as code"
[[ ! -e "$HW/hwmon900" && ! -e "$HW/hwmon901" ]] || fail "malformed reading published"
[[ $(val 980) == 25000 ]] || fail "valid T.Limit dropped"
n=$(find "$HW" -maxdepth 1 -name 'hwmon9*' ! -type l | wc -l)
[[ $n == 1 ]] || fail "unexpected synthetic sensors: $n"
echo "ok - malformed readings and indices skipped"

# A hung reader is bounded and its stale sensors are removed.
touch "$T/hang"; start=$SECONDS; run
(( SECONDS - start < 10 )) || fail "reader not bounded"
n=$(find "$HW" -maxdepth 1 -name 'hwmon9*' ! -type l | wc -l)
[[ $n == 0 ]] || fail "stale sensors kept after reader failure"
echo "ok - hung reader bounded, stale sensors removed"
