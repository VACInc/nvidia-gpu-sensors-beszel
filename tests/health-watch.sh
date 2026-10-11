#!/usr/bin/env bash
# Exercise health/gpu-health-watch.sh against fake nvidia-smi, helper, sysfs
# and curl. Usage: tests/health-watch.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/pci/0000:41:00.0" "$T/state" "$T/log"

# Counters come from files the test edits between runs.
echo 0 >"$T/swt"; echo 0 >"$T/replay"; echo 0 >"$T/nvcrc"; echo 0 >"$T/aercor"
cat >"$T/bin/nvidia-smi" <<EOF
#!/bin/sh
case "\$1" in
  --query-gpu=*) echo "3, NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 00000000:41:00.0, 45, 57, 80.5, 100, \$(cat $T/swt), 0, 0" ;;
  -q) printf 'GPU 00000000:41:00.0\n    PCI\n        Replays Since Reset    : %s\n        Replay Number Rollovers : 0\n' "\$(cat $T/replay)" ;;
  nvlink) printf 'GPU 3: NVIDIA RTX PRO 6000 (UUID: x)\n\t Link 0: Replay Errors: 0\n\t Link 0: Recovery Errors: 0\n\t Link 0: CRC Errors: %s\n' "\$(cat $T/nvcrc)" ;;
esac
EOF
cat >"$T/helper" <<'EOF'
#!/bin/sh
echo "0000:41:00.0,45.0,60.0,52.3,0.9,0.9,0xAD0A94,52.3,D1B,64,32"
EOF
cat >"$T/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/curl.log"
EOF
cat >"$T/ntfy.env" <<'EOF'
NTFY_URL=https://ntfy.invalid/TARS
NTFY_AUTH=user:secret
EOF
chmod +x "$T/bin/"* "$T/helper"
aer() { printf 'RxErr 0\nTOTAL_ERR_COR %s\n' "$(cat "$T/aercor")" >"$T/pci/0000:41:00.0/aer_dev_correctable"; }
aer
run() {
  PATH="$T/bin:$PATH" GPU_HEALTH_HELPER="$T/helper" GPU_HEALTH_LOG_DIR="$T/log" \
    GPU_HEALTH_STATE_DIR="$T/state" GPU_HEALTH_NTFY_ENV="$T/ntfy.env" \
    GPU_HEALTH_PCI_SYSFS="$T/pci" GPU_HEALTH_PATH_PREFIX="$T/bin" bash "$HERE/health/gpu-health-watch.sh"
}
fail() { echo "FAIL: $*" >&2; cat "$T"/log/* >&2; exit 1; }

run
grep -q 'gpu=3 bdf=0000:41:00.0 .*hot=52.3 hot_sensor=0xAD0A94 vram_chip=D1B vram_chip_c=64 chips=32 tlimit=57' "$T"/log/* || fail "card line"
grep -q 'errors gpu=3 .*pcie_replay=0 .*aer_cor=0 .*nvlink_crc=0' "$T"/log/* || fail "errors line"
[ ! -e "$T/curl.log" ] || fail "alert on first run"

# 20 s of thermal slowdown: below the 30 s limit.
echo 20000000 >"$T/swt"; run
[ ! -e "$T/curl.log" ] || fail "alert below limit"
grep -q 'sw_therm=20.0' "$T"/log/* || fail "slowdown delta"
# +15 s more inside the window: 35 s total, alert once.
echo 35000000 >"$T/swt"; run
grep -q 'Title: GPU slowdown' "$T/curl.log" || fail "slowdown alert"
grep -q 'secret' "$T/curl.log" && fail "credential on curl argv"
# Still rising, but the hourly limit suppresses a second page.
echo 80000000 >"$T/swt"; run
[ "$(grep -c 'GPU slowdown' "$T/curl.log")" = 1 ] || fail "rate limit"
grep -q 'alert-suppressed key=gpu3.slow' "$T"/log/* || fail "suppressed log"

# Link errors: force the 5 min poll by rewinding its timestamp.
echo 3 >"$T/replay"; echo 2 >"$T/nvcrc"; echo 1 >"$T/aercor"; aer
sed -i 's/^LAST_ERRPOLL=[0-9]*/LAST_ERRPOLL=0/' "$T/state/state"
run
grep -q 'Title: GPU PCIe errors' "$T/curl.log" || fail "pcie alert"
grep -q 'Title: GPU NVLink errors' "$T/curl.log" || fail "nvlink alert"
grep -q 'PCIe replays +3' "$T"/log/* || fail "replay delta"
grep -q 'AER correctable +1' "$T"/log/* || fail "aer delta"

# Logs older than 30 days are pruned.
touch -d '40 days ago' "$T/log/gpu-2000-01-01.log"
sed -i 's/LAST_PRUNE=[0-9]*/LAST_PRUNE=0/' "$T/state/state"
run
[ ! -e "$T/log/gpu-2000-01-01.log" ] || fail "prune"
echo "health-watch ok"

# Jetson mode: fake thermal zones, throttle-alert cooling devices, OC counters.
J="$T/jetson"; mkdir -p "$J/th/thermal_zone0" "$J/th/thermal_zone1" "$J/th/cooling_device0" "$J/hw/hwmon8" "$J/state" "$J/log"
echo cpu-thermal >"$J/th/thermal_zone0/type"; echo 61500 >"$J/th/thermal_zone0/temp"
echo gpu-thermal >"$J/th/thermal_zone1/type"   # no temp file: rail gated
echo gpu-throttle-alert >"$J/th/cooling_device0/type"; echo 0 >"$J/th/cooling_device0/cur_state"
echo soctherm_oc >"$J/hw/hwmon8/name"; echo 0 >"$J/hw/hwmon8/oc1_event_cnt"
rm -f "$T/curl.log"
jrun() {
  PATH="$T/bin:$PATH" GPU_HEALTH_MODE=jetson GPU_HEALTH_LOG_DIR="$J/log" GPU_HEALTH_STATE_DIR="$J/state" \
    GPU_HEALTH_NTFY_ENV="$T/ntfy.env" GPU_HEALTH_THERMAL_SYSFS="$J/th" GPU_HEALTH_HWMON_SYSFS="$J/hw" \
    GPU_HEALTH_PATH_PREFIX="$T/bin" bash "$HERE/health/gpu-health-watch.sh"
}
jrun
grep -q 'jetson hottest=cpu hot=61.5 throttle_margin=37 throttle_active="" oc="oc1=0"' "$J"/log/* || { cat "$J"/log/*; fail "jetson line"; }
echo 1 >"$J/th/cooling_device0/cur_state"; jrun
[ ! -e "$T/curl.log" ] || fail "jetson alert at 30 s"
jrun
grep -q 'Title: Jetson throttling' "$T/curl.log" || { cat "$J"/log/*; fail "jetson throttle alert"; }
echo 2 >"$J/hw/hwmon8/oc1_event_cnt"; jrun
grep -q 'Title: Jetson over-current' "$T/curl.log" || fail "jetson oc alert"
echo "jetson ok"
