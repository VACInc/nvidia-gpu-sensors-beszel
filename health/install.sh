#!/usr/bin/env bash
# Install gpu-health-watch (thermal log + slowdown/link-error alerts).
# Idempotent: re-run to update. Root required. Independent of the Beszel
# helper: it builds its own copy of nvidia-gpu-sensors for --detail.
# Alerts need /etc/ntfy.env (NTFY_URL, NTFY_AUTH=user:password).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

mkdir -p /opt/gpu-health/bin
if command -v nvidia-smi >/dev/null 2>&1; then
    command -v gcc >/dev/null || { echo "gcc not found" >&2; exit 1; }
    gcc -std=gnu11 -O2 -Wall -Wextra -o /opt/gpu-health/bin/nvidia-gpu-sensors.new \
        "$HERE/src/nvidia-gpu-sensors.c"
    /opt/gpu-health/bin/nvidia-gpu-sensors.new --detail >/dev/null
    mv -f /opt/gpu-health/bin/nvidia-gpu-sensors.new /opt/gpu-health/bin/nvidia-gpu-sensors
elif [ ! -r /etc/nv_tegra_release ]; then
    echo "no nvidia-smi and not a Jetson: nothing to watch" >&2
    exit 1
fi
install -m 0755 "$HERE/health/gpu-health-watch.sh" /opt/gpu-health/gpu-health-watch.sh
if [ -d "$HERE/.git" ] && command -v git >/dev/null 2>&1; then
    git -C "$HERE" rev-parse HEAD >/opt/gpu-health/SOURCE 2>/dev/null || true
fi
install -m 0644 "$HERE/health/gpu-health-watch.service" "$HERE/health/gpu-health-watch.timer" \
    /etc/systemd/system/
systemctl daemon-reload
systemctl enable gpu-health-watch.timer >/dev/null
systemctl start gpu-health-watch.service
systemctl restart gpu-health-watch.timer
[ -r /etc/ntfy.env ] || echo "WARNING: /etc/ntfy.env missing: alerts are logged but not sent" >&2
echo "latest log lines:"
tail -n 4 "/var/log/gpu-health/gpu-$(date +%F).log"
