#!/usr/bin/env bash
# Remove gpu-health-watch. Logs in /var/log/gpu-health are kept.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
systemctl disable --now gpu-health-watch.timer 2>/dev/null || true
rm -f /etc/systemd/system/gpu-health-watch.service /etc/systemd/system/gpu-health-watch.timer
systemctl daemon-reload
rm -rf /opt/gpu-health /var/lib/gpu-health-watch
echo "removed (logs kept in /var/log/gpu-health)"
