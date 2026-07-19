#!/usr/bin/env bash
# Build nvidia-gpu-sensors and wire its readings into Beszel.
# Idempotent: safe to re-run for updates. Root required.
set -euo pipefail

AGENT_UNIT="${BESZEL_AGENT_UNIT:-beszel-agent}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found — NVIDIA driver required" >&2; exit 1; }
command -v gcc >/dev/null || { echo "gcc not found" >&2; exit 1; }

echo "building..."
mkdir -p /opt/gpu-hotspot/bin /opt/gpu-hotspot/src
gcc -O2 -Wall -o /opt/gpu-hotspot/bin/nvidia-gpu-sensors "$HERE/src/nvidia-gpu-sensors.c"
cp "$HERE/src/nvidia-gpu-sensors.c" "$HERE/src/meson.build" /opt/gpu-hotspot/src/

echo "smoke test (one-shot read)..."
/opt/gpu-hotspot/bin/nvidia-gpu-sensors --csv

install -m755 "$HERE/beszel/update-hwmon.sh" /opt/gpu-hotspot/
install -m644 "$HERE/beszel/gpu-hotspot-hwmon.service" \
              "$HERE/beszel/gpu-hotspot-hwmon.timer" /etc/systemd/system/
install -m644 -D "$HERE/beszel/30-sys-sensors.conf" \
              "/etc/systemd/system/${AGENT_UNIT}.service.d/30-sys-sensors.conf"

systemctl daemon-reload
systemctl enable --now gpu-hotspot-hwmon.timer
systemctl start gpu-hotspot-hwmon.service

echo "published sensors:"
for d in /run/gpu-sensors-sys/class/hwmon/hwmon9*; do
    [ -L "$d" ] || echo "  $(cat "$d/name") = $(awk '{printf "%.1f °C", $1/1000}' "$d/temp1_input")"
done

if systemctl cat "$AGENT_UNIT" >/dev/null 2>&1; then
    systemctl restart "$AGENT_UNIT"
    echo "restarted ${AGENT_UNIT}; sensors appear in the hub on its next poll"
else
    echo "NOTE: no '${AGENT_UNIT}' unit found — set BESZEL_AGENT_UNIT or add the drop-in to your agent manually" >&2
fi
