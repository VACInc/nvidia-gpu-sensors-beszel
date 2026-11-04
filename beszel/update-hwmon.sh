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
# Synthetic dirs are hwmon<900 + 2*gpu_index (+1 for VRAM)> and
# hwmon<980 + gpu_index> for T.Limit — keyed to the nvidia-smi index so names
# stay stable across boots, far above any real hwmon index, and matched by
# gopsutil's hwmon* glob.
#
# T.Limit is NVIDIA's margin to the GPU's slowdown temperature in degrees C
# (nvidia-smi temperature.gpu.tlimit): it falls as the card heats and
# throttling starts near 0. Only boards that report it (Blackwell so far) get
# the sensor; [N/A] is skipped.
set -euo pipefail

# Overrides exist for tests/update-hwmon.sh only; the unit sets none.
ROOT="${GPU_HOTSPOT_ROOT:-/run/gpu-sensors-sys}"
HW="$ROOT/class/hwmon"
BIN="${GPU_HOTSPOT_BIN:-/opt/gpu-hotspot/bin/nvidia-gpu-sensors}"
SYS_HWMON="${GPU_HOTSPOT_SYS_HWMON:-/sys/class/hwmon}"
# nvidia-smi can block for minutes when a GPU falls off the bus. Bound each
# reader so the oneshot finishes, the timer keeps firing, and sensors that
# could not be read are removed below instead of freezing at stale values.
READ_TIMEOUT="${GPU_HOTSPOT_READ_TIMEOUT:-20}"

mkdir -p "$HW"

# Mirror the real hwmon entries; indices shift across boots and hotplug, so
# rebuild fully and drop mirrors of entries that are gone (below).
declare -A mirrored
for d in "$SYS_HWMON"/hwmon*; do
    [ -e "$d" ] || continue
    ln -sfn "$(readlink -f "$d")" "$HW/${d##*/}"
    mirrored[${d##*/}]=1
done

declare -A GPU_NAME GPU_INDEX GPU_TLIMIT NAME_COUNT
while IFS=, read -r idx name bus tlimit; do
    idx="${idx// /}"
    name="${name# }"; name="${name#NVIDIA }"
    bus="${bus// /}"; bus="${bus,,}"; bdf="${bus: -12}"
    tlimit="${tlimit// /}"
    # Indices feed arithmetic and hwmon numbering: digits only, and below 40 so
    # hwmon900+2*idx+1 never reaches the T.Limit range at hwmon980.
    if ! [[ "$idx" =~ ^[0-9]{1,2}$ ]] || (( 10#$idx >= 40 )); then continue; fi
    idx=$(( 10#$idx ))
    [[ "$bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || continue
    GPU_NAME[$bdf]="$name"
    GPU_INDEX[$bdf]="$idx"
    [[ "$tlimit" =~ ^-?[0-9]+$ ]] && GPU_TLIMIT[$bdf]="$tlimit"
    NAME_COUNT[$name]=$(( ${NAME_COUNT[$name]:-0} + 1 ))
done < <(timeout "$READ_TIMEOUT" nvidia-smi --query-gpu=index,name,pci.bus_id,temperature.gpu.tlimit --format=csv,noheader,nounits)

# milli <degC>: set MILLI to millidegrees. Rejects anything but a plain
# decimal, so a malformed reading never becomes a fake 0 C sensor. Exact for
# the tool's one-decimal output (awk %d of t*1000 turned 64.1 into 64099).
milli() {
    [[ "$1" =~ ^(-?)([0-9]{1,4})(\.([0-9]+))?$ ]] || return 1
    local frac="${BASH_REMATCH[4]}000"
    MILLI=$(( 10#${BASH_REMATCH[2]} * 1000 + 10#${frac:0:3} ))
    [ -z "${BASH_REMATCH[1]}" ] || MILLI=$(( -MILLI ))
}

declare -A written
write_sensor() {  # write_sensor <dirnum> <display-name> <degC>
    local dir="$HW/hwmon$1"
    milli "$3" || return 0
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/name.tmp" && mv "$dir/name.tmp" "$dir/name"
    printf '%d\n' "$MILLI" > "$dir/temp1_input.tmp"
    mv "$dir/temp1_input.tmp" "$dir/temp1_input"
    written[$1]=1
}

# All CSV columns must be consumed, but this exporter only uses mem and hot.
# shellcheck disable=SC2034
while IFS=, read -r bdf core mem hot v0 v1; do
    name="${GPU_NAME[$bdf]:-}"
    [ -n "$name" ] || continue
    idx="${GPU_INDEX[$bdf]}"
    disp="$name"
    [ "${NAME_COUNT[$name]}" -gt 1 ] && disp="$name $idx"
    [ -n "$hot" ] && write_sensor $(( 900 + 2*idx ))     "$disp Hotspot" "$hot"
    [ -n "$mem" ] && write_sensor $(( 900 + 2*idx + 1 )) "$disp VRAM"    "$mem"
    [ -n "${GPU_TLIMIT[$bdf]:-}" ] && write_sensor $(( 980 + idx )) "$disp T.Limit" "${GPU_TLIMIT[$bdf]}"
done < <(timeout "$READ_TIMEOUT" "$BIN" --csv)

# Remove synthetic dirs that weren't written this run and mirrors of hwmon
# entries that no longer exist, so stale sensors and old layouts never linger
# (a dangling mirror makes the agent log read errors every poll).
for d in "$HW"/hwmon*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    if [ -L "$d" ]; then
        [ -n "${mirrored[${d##*/}]:-}" ] || rm -f "$d"
        continue
    fi
    n="${d##*/hwmon}"
    [ -n "${written[$n]:-}" ] || rm -rf "$d"
done
