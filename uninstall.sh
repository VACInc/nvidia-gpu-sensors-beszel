#!/usr/bin/env bash
# Remove everything install.sh added and restore the agent's stock sensors.
set -euo pipefail

AGENT_UNIT="${BESZEL_AGENT_UNIT:-beszel-agent}"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now gpu-hotspot-hwmon.timer 2>/dev/null || true
rm -f /etc/systemd/system/gpu-hotspot-hwmon.service \
      /etc/systemd/system/gpu-hotspot-hwmon.timer \
      "/etc/systemd/system/${AGENT_UNIT}.service.d/30-sys-sensors.conf"
rmdir "/etc/systemd/system/${AGENT_UNIT}.service.d" 2>/dev/null || true
systemctl daemon-reload
rm -rf /opt/gpu-hotspot /run/gpu-sensors-sys
systemctl restart "$AGENT_UNIT" 2>/dev/null || true
echo "removed"
