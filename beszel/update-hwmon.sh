#!/usr/bin/env bash
# Publish NVIDIA hotspot/VRAM temps as synthetic hwmon devices for Beszel.
#
# Beszel's agent reads temperature sensors from $SYS_SENSORS/class/hwmon (a
# /sys root override meant for containerized agents). The NVIDIA driver has no
# hwmon interface, so we build a shadow tree: symlinks to every real hwmon
# entry plus synthetic devices fed by nvidia-gpu-sensors --csv. A beszel-agent
# drop-in points SYS_SENSORS here; everything else it reads is unchanged
# because the real entries are mirrored on every run.
#
# Display names: gopsutil lowercases and underscores hwmon *labels* but passes
# the chip *name* through verbatim, so each sensor gets its own device dir
# whose name file holds the display string and no label file. Names mirror
# Beszel's GPU chart naming (nvidia-smi name minus "NVIDIA " prefix, index
# appended only when several GPUs share a name), e.g.
# "RTX PRO 6000 Blackwell Workstation Edition 3 Hotspot".
#
# Synthetic dirs are hwmon<900 + 2*gpu_index (+1 for VRAM)> — keyed to the
# nvidia-smi index so names stay stable across boots, far above any real
# hwmon index, and matched by gopsutil's hwmon* glob.
set -euo pipefail

ROOT=/run/gpu-sensors-sys
HW="$ROOT/class/hwmon"
BIN=/opt/gpu-hotspot/bin/nvidia-gpu-sensors

mkdir -p "$HW"

# Mirror the real hwmon entries; indices shift across boots, so rebuild fully.
for d in /sys/class/hwmon/hwmon*; do
    [ -e "$d" ] || continue
    ln -sfn "$(readlink -f "$d")" "$HW/$(basename "$d")"
done

declare -A GPU_NAME GPU_INDEX NAME_COUNT
while IFS=, read -r idx name bus; do
    idx="${idx// /}"
    name="${name# }"; name="${name#NVIDIA }"
    bus="${bus// /}"; bus="${bus,,}"; bdf="${bus: -12}"
    GPU_NAME[$bdf]="$name"
    GPU_INDEX[$bdf]="$idx"
    NAME_COUNT[$name]=$(( ${NAME_COUNT[$name]:-0} + 1 ))
done < <(nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader)

declare -A written
write_sensor() {  # write_sensor <dirnum> <display-name> <degC>
    local dir="$HW/hwmon$1"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name.tmp" && mv "$dir/name.tmp" "$dir/name"
    awk -v t="$3" 'BEGIN{printf "%d\n", t*1000}' > "$dir/temp1_input.tmp"
    mv "$dir/temp1_input.tmp" "$dir/temp1_input"
    written[$1]=1
}

while IFS=, read -r bdf core mem hot v0 v1; do
    name="${GPU_NAME[$bdf]:-}"
    [ -n "$name" ] || continue
    idx="${GPU_INDEX[$bdf]}"
    disp="$name"
    [ "${NAME_COUNT[$name]}" -gt 1 ] && disp="$name $idx"
    [ -n "$hot" ] && write_sensor $(( 900 + 2*idx ))     "$disp Hotspot" "$hot"
    [ -n "$mem" ] && write_sensor $(( 900 + 2*idx + 1 )) "$disp VRAM"    "$mem"
done < <("$BIN" --csv)

# Remove synthetic dirs (non-symlinks) that weren't written this run, so
# stale sensors and old layouts never linger.
for d in "$HW"/hwmon*; do
    [ -L "$d" ] && continue
    n="${d##*/hwmon}"
    [ -n "${written[$n]:-}" ] || rm -rf "$d"
done
