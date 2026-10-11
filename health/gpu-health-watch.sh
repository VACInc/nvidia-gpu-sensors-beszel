#!/usr/bin/env bash
# gpu-health-watch: per-card thermal log plus ntfy alerts for GPU slowdowns and
# link errors. Runs every 30 s from gpu-health-watch.timer as root.
#
# NVIDIA mode (nvidia-smi present):
#   * one log line per card per run: core temp, Hot Spot plus the die sensor
#     register that produced it, hottest GDDR chip (e.g. D1B = partition D,
#     chip 1, back side), T.Limit margin, power, and clock-slowdown seconds
#     accrued since the previous run.
#   * slowdown alert: sw thermal + hw thermal + hw power brake time > 30 s in
#     any 5 min window. Power cap is logged only. One alert per card per hour.
#   * every 5 min: PCIe replays (nvidia-smi -q), PCIe AER totals (sysfs) and
#     NVLink replay/recovery/CRC errors (nvidia-smi nvlink -e). Any rise sends
#     an alert, one per card per counter family per hour.
# Jetson mode (/etc/nv_tegra_release, no nvidia-smi):
#   * one log line per run: hottest thermal zone, margin to the 99 C soctherm
#     throttle trip, active throttle alerts, over-current event counters.
#   * alert when throttle alerts are active > 30 s in 5 min, or an OC event
#     counter rises. One alert per kind per hour.
#
# Logs: $LOG_DIR/gpu-YYYY-MM-DD.log, pruned after 30 days.
# ntfy: /etc/ntfy.env (NTFY_URL, NTFY_AUTH); without it alerts are only logged.
# Alerts carry the ntfy tag no-repair: hardware events, not agent repairs.
#
# Every program started here is an audited execve on these hosts, so the 30 s
# path uses bash builtins except for the readers themselves.
set -uo pipefail
umask 0022
# Pinned PATH; GPU_HEALTH_PATH_PREFIX is the test-injection hook.
export PATH="${GPU_HEALTH_PATH_PREFIX:+${GPU_HEALTH_PATH_PREFIX}:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

HELPER="${GPU_HEALTH_HELPER:-/opt/gpu-health/bin/nvidia-gpu-sensors}"
LOG_DIR="${GPU_HEALTH_LOG_DIR:-/var/log/gpu-health}"
STATE_DIR="${GPU_HEALTH_STATE_DIR:-/var/lib/gpu-health-watch}"
NTFY_ENV="${GPU_HEALTH_NTFY_ENV:-/etc/ntfy.env}"
PCI_SYSFS="${GPU_HEALTH_PCI_SYSFS:-/sys/bus/pci/devices}"
THERMAL_SYSFS="${GPU_HEALTH_THERMAL_SYSFS:-/sys/class/thermal}"
HWMON_SYSFS="${GPU_HEALTH_HWMON_SYSFS:-/sys/class/hwmon}"
WINDOW=300            # slowdown window, seconds
SLOW_LIMIT_US=30000000
REALERT=3600
ERR_EVERY=300         # link error poll interval, seconds
KEEP_DAYS=30
JETSON_TRIP_MC=99000  # soctherm software throttle trip on Orin

mkdir -p "$LOG_DIR" "$STATE_DIR"
STATE="$STATE_DIR/state"
printf -v NOW '%(%s)T' -1
printf -v STAMP '%(%Y-%m-%dT%H:%M:%S%z)T' "$NOW"
printf -v DAY '%(%Y-%m-%d)T' "$NOW"
LOG="$LOG_DIR/gpu-$DAY.log"
HOST="${HOSTNAME%%.*}"

# Persistent state (declare -p dump of these arrays and scalars).
declare -A RING=() LAST_ALERT=() ERRBASE=() LASTCNT=()
WDELTA=0 RISE=0
LAST_ERRPOLL=0 LAST_PRUNE=0
# shellcheck disable=SC1090
[[ -r "$STATE" ]] && source "$STATE"

log() { printf '%s %s\n' "$STAMP" "$*" >>"$LOG"; }

NTFY_URL='' NTFY_AUTH=''
if [[ -r "$NTFY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$NTFY_ENV"
fi

# alert <key> <priority> <title> <body>; rate limited per key.
alert() {
    local key=$1 prio=$2 title=$3 body=$4
    if (( NOW - ${LAST_ALERT[$key]:-0} < REALERT )); then
        log "alert-suppressed key=$key title=\"$title\""
        return 0
    fi
    LAST_ALERT[$key]=$NOW
    log "alert key=$key title=\"$title\" body=\"${body//$'\n'/ | }\""
    [[ -n "$NTFY_URL" ]] || { log "alert-not-sent reason=no-ntfy-env key=$key"; return 0; }
    # NTFY_AUTH is user:password; a --config pipe keeps it off curl's argv.
    curl -fsS -m 15 -o /dev/null --config <(printf 'user = "%s"\n' "$NTFY_AUTH") \
        -H "Title: $title" -H "Priority: $prio" -H "Tags: no-repair,thermometer" \
        --data-binary "$body" "$NTFY_URL" 2>>"$LOG" ||
        log "alert-send-failed key=$key"
}

# window_delta <key> <counter>: append sample, drop samples older than WINDOW,
# set WDELTA to the counter rise across the window. Counter reset clears the
# ring. Results go through globals: a $(...) subshell would drop RING updates.
window_delta() {
    local key=$1 cur=$2 kept='' first='' s ts val
    for s in ${RING[$key]:-}; do
        ts=${s%%:*} val=${s#*:}
        (( NOW - ts > WINDOW )) && continue
        (( val > cur )) && { kept='' first=''; continue; }
        [[ -z "$first" ]] && first=$val
        kept+="$s "
    done
    RING[$key]="$kept$NOW:$cur"
    WDELTA=$(( cur - ${first:-$cur} ))
}

# rise <key> <value>: set RISE to the increase since last poll; 0 on first
# sight or counter reset.
rise() {
    local key=$1 cur=$2 prev=${ERRBASE[$1]:-}
    ERRBASE[$key]=$cur
    RISE=0
    [[ -n "$prev" ]] && (( cur >= prev )) && RISE=$(( cur - prev ))
    return 0
}

us_to_s() { printf '%d.%01d' $(( $1 / 1000000 )) $(( $1 % 1000000 / 100000 )); }

nvidia_cycle() {
    declare -A NAME=() IDX=() DET=()
    local line idx name bus temp tl pwr pcap swt hwt brk bdf
    # Hottest die sensor + hottest GDDR chip from the BAR0 helper.
    if [[ -x "$HELPER" ]]; then
        while IFS= read -r line; do
            DET[${line%%,*}]=$line
        done < <(timeout 20 "$HELPER" --detail 2>/dev/null)
    fi
    while IFS=, read -r idx name bus temp tl pwr pcap swt hwt brk; do
        idx=${idx// /} name=${name# } name=${name#NVIDIA }
        bus=${bus// /} bus=${bus,,} bdf=${bus: -12}
        temp=${temp// /} tl=${tl// /} pwr=${pwr// /}
        pcap=${pcap// /} swt=${swt// /} hwt=${hwt// /} brk=${brk// /}
        [[ "$pcap" =~ ^[0-9]+$ ]] || pcap=0
        [[ "$swt" =~ ^[0-9]+$ ]] || swt=0
        [[ "$hwt" =~ ^[0-9]+$ ]] || hwt=0
        [[ "$brk" =~ ^[0-9]+$ ]] || brk=0
        NAME[$bdf]=$name IDX[$bdf]=$idx
        local d=${DET[$bdf]:-} hot='' hreg='' chip='' chipc='' nchips=''
        if [[ -n "$d" ]]; then
            local f
            IFS=, read -r -a f <<<"$d"
            hot=${f[3]:-} hreg=${f[6]:-} chip=${f[8]:-} chipc=${f[9]:-} nchips=${f[10]:-}
        fi
        [[ "$tl" =~ ^-?[0-9]+$ ]] || tl=''
        local k="gpu$idx" dp ds dh db
        dp=$(( pcap - ${LASTCNT[$k.pcap]:-$pcap} )); (( dp < 0 )) && dp=0
        ds=$(( swt - ${LASTCNT[$k.swt]:-$swt} )); (( ds < 0 )) && ds=0
        dh=$(( hwt - ${LASTCNT[$k.hwt]:-$hwt} )); (( dh < 0 )) && dh=0
        db=$(( brk - ${LASTCNT[$k.brk]:-$brk} )); (( db < 0 )) && db=0
        LASTCNT[$k.pcap]=$pcap LASTCNT[$k.swt]=$swt LASTCNT[$k.hwt]=$hwt LASTCNT[$k.brk]=$brk
        log "gpu=$idx bdf=$bdf name=\"$name\" core=${temp:-na} hot=${hot:-na} hot_sensor=${hreg:-na}" \
            "vram_chip=${chip:-na} vram_chip_c=${chipc:-na} chips=${nchips:-0} tlimit=${tl:-na} power_w=${pwr:-na}" \
            "slow_s pwrcap=$(us_to_s $dp) sw_therm=$(us_to_s $ds) hw_therm=$(us_to_s $dh) pwr_brake=$(us_to_s $db)"
        window_delta "$k.slow" $(( swt + hwt + brk ))
        local w=$WDELTA
        if (( w > SLOW_LIMIT_US )); then
            alert "$k.slow" 4 "GPU slowdown: $HOST GPU$idx $name" \
"Thermal/brake clock slowdown $(us_to_s "$w") s in the last 5 min.
Since last sample: sw_thermal $(us_to_s $ds) s, hw_thermal $(us_to_s $dh) s, power_brake $(us_to_s $db) s.
Core ${temp:-na} C, Hot Spot ${hot:-na} C (${hreg:-na}), hottest VRAM chip ${chip:-na} ${chipc:-na} C, T.Limit ${tl:-na}.
Log: $LOG"
        fi
    done < <(nvidia-smi --query-gpu=index,name,pci.bus_id,temperature.gpu,temperature.gpu.tlimit,power.draw,clocks_event_reasons_counters.sw_power_cap,clocks_event_reasons_counters.sw_thermal_slowdown,clocks_event_reasons_counters.hw_thermal_slowdown,clocks_event_reasons_counters.hw_power_brake_slowdown --format=csv,noheader,nounits 2>>"$LOG")

    (( NOW - LAST_ERRPOLL >= ERR_EVERY - 5 )) || return 0
    LAST_ERRPOLL=$NOW
    nvidia_errors
}

nvidia_errors() {
    declare -A REPLAY=() ROLL=() NVL=()
    local line cur='' gpu='' v
    # PCIe replay counters live only in the full query.
    while IFS= read -r line; do
        if [[ "$line" =~ ^GPU\ ([0-9A-Fa-f]+:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9]) ]]; then
            cur=${BASH_REMATCH[1],,}; cur=${cur: -12}
        elif [[ -n "$cur" && "$line" =~ Replays\ Since\ Reset[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
            REPLAY[$cur]=${BASH_REMATCH[1]}
        elif [[ -n "$cur" && "$line" =~ Replay\ Number\ Rollovers[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
            ROLL[$cur]=${BASH_REMATCH[1]}
        fi
    done < <(timeout 30 nvidia-smi -q 2>/dev/null)
    # NVLink: "GPU n: ..." then "Link x: Replay Errors: v" etc.
    while IFS= read -r line; do
        if [[ "$line" =~ ^GPU\ ([0-9]+): ]]; then
            gpu=${BASH_REMATCH[1]}
        elif [[ -n "$gpu" && "$line" =~ (Replay|Recovery|CRC)\ Errors:\ ([0-9]+) ]]; then
            v=${BASH_REMATCH[2]}
            NVL[$gpu.${BASH_REMATCH[1]}]=$(( ${NVL[$gpu.${BASH_REMATCH[1]}]:-0} + v ))
            NVL[$gpu.any]=1
        fi
    done < <(timeout 30 nvidia-smi nvlink -e 2>/dev/null)

    local bdf idx name k r rr aer_c aer_n aer_f f key val
    for bdf in "${!NAME[@]}"; do
        idx=${IDX[$bdf]} name=${NAME[$bdf]} k="gpu$idx"
        r=${REPLAY[$bdf]:-} rr=${ROLL[$bdf]:-0}
        aer_c='' aer_n='' aer_f=''
        for f in correctable:TOTAL_ERR_COR nonfatal:TOTAL_ERR_NONFATAL fatal:TOTAL_ERR_FATAL; do
            [[ -r "$PCI_SYSFS/$bdf/aer_dev_${f%%:*}" ]] || continue
            while read -r key val; do
                [[ "$key" == "${f#*:}" ]] && printf -v "aer_${f:0:1}" '%s' "$val"
            done <"$PCI_SYSFS/$bdf/aer_dev_${f%%:*}"
        done
        log "errors gpu=$idx bdf=$bdf pcie_replay=${r:-na} pcie_replay_rollover=$rr aer_cor=${aer_c:-na}" \
            "aer_nonfatal=${aer_n:-na} aer_fatal=${aer_f:-na} nvlink_replay=${NVL[$idx.Replay]:-na}" \
            "nvlink_recovery=${NVL[$idx.Recovery]:-na} nvlink_crc=${NVL[$idx.CRC]:-na}"
        local d pcie_msg='' nvl_msg=''
        if [[ -n "$r" ]]; then
            rise "$k.replay" $(( rr * 1000000 + r )); d=$RISE
            (( d > 0 )) && pcie_msg+="PCIe replays +$d (total $r, rollovers $rr). "
        fi
        for f in c:correctable n:nonfatal f:fatal; do
            v=aer_${f%%:*}; v=${!v}
            [[ -n "$v" ]] || continue
            rise "$k.aer_${f#*:}" "$v"; d=$RISE; (( d > 0 )) && pcie_msg+="AER ${f#*:} +$d (total $v). "
        done
        if [[ -n "${NVL[$idx.any]:-}" ]]; then
            for f in Replay Recovery CRC; do
                rise "$k.nvl_$f" "${NVL[$idx.$f]:-0}"; d=$RISE
                (( d > 0 )) && nvl_msg+="NVLink $f errors +$d (total ${NVL[$idx.$f]}). "
            done
        fi
        [[ -n "$pcie_msg" ]] && alert "$k.pcie" 4 "GPU PCIe errors: $HOST GPU$idx $name" "$pcie_msg
BDF $bdf. Log: $LOG"
        [[ -n "$nvl_msg" ]] && alert "$k.nvlink" 4 "GPU NVLink errors: $HOST GPU$idx $name" "$nvl_msg
BDF $bdf. Log: $LOG"
    done
}

jetson_cycle() {
    local z type t hot=-999999 hotname='' zones='' c ctype st active='' nact=0 h n f v oc=''
    for z in "$THERMAL_SYSFS"/thermal_zone*; do
        [[ -r "$z/type" ]] || continue
        read -r type <"$z/type"
        # gpu/cv zones return ENODATA while their rail is gated.
        { read -r t <"$z/temp"; } 2>/dev/null || continue
        [[ "$t" =~ ^-?[0-9]+$ ]] || continue
        zones+="${type%-thermal}=$(( t / 1000 )).$(( (t < 0 ? -t : t) % 1000 / 100 )) "
        (( t > hot )) && { hot=$t; hotname=${type%-thermal}; }
    done
    for c in "$THERMAL_SYSFS"/cooling_device*; do
        { read -r ctype <"$c/type"; } 2>/dev/null || continue
        [[ "$ctype" == *throttle-alert || "$ctype" == hot-surface-alert ]] || continue
        { read -r st <"$c/cur_state"; } 2>/dev/null || continue
        (( st > 0 )) && { active+="${ctype%-throttle-alert}:$st "; nact=$(( nact + 1 )); }
    done
    local ocmsg=''
    for h in "$HWMON_SYSFS"/hwmon*; do
        { read -r n <"$h/name"; } 2>/dev/null || continue
        [[ "$n" == soctherm_oc ]] || continue
        for f in "$h"/oc*_event_cnt; do
            [[ -r "$f" ]] || continue
            read -r v <"$f"
            n=${f##*/}; n=${n%_event_cnt}
            oc+="$n=$v "
            local d
            rise "jetson.$n" "$v"; d=$RISE
            (( d > 0 )) && ocmsg+="$n over-current events +$d (total $v). "
        done
    done
    local margin=na
    (( hot > -999999 )) && margin=$(( (JETSON_TRIP_MC - hot) / 1000 ))
    log "jetson hottest=$hotname hot=$(( hot / 1000 )).$(( hot % 1000 / 100 )) throttle_margin=$margin" \
        "throttle_active=\"${active% }\" oc=\"${oc% }\" zones=\"${zones% }\""
    # Every active-alert sample counts as one full 30 s interval.
    local acc=$(( ${LASTCNT[jetson.thr]:-0} + (nact > 0 ? 30000000 : 0) )) w
    LASTCNT[jetson.thr]=$acc
    window_delta jetson.thr "$acc"; w=$WDELTA
    if (( w > SLOW_LIMIT_US )); then
        alert jetson.thr 4 "Jetson throttling: $HOST" \
"Thermal throttle alerts active for about $(( w / 1000000 )) s in the last 5 min: ${active:-cleared}.
Hottest zone $hotname $(( hot / 1000 )) C, margin to 99 C trip ${margin} C.
Log: $LOG"
    fi
    [[ -n "$ocmsg" ]] && alert jetson.oc 4 "Jetson over-current throttle: $HOST" "$ocmsg
Log: $LOG"
}

MODE="${GPU_HEALTH_MODE:-auto}"
if [[ "$MODE" == nvidia ]] || { [[ "$MODE" == auto ]] && command -v nvidia-smi >/dev/null 2>&1; }; then
    nvidia_cycle
elif [[ "$MODE" == jetson ]] || [[ -r /etc/nv_tegra_release ]]; then
    jetson_cycle
else
    log "no supported GPU found"
fi

if (( NOW - LAST_PRUNE >= 3600 )); then
    LAST_PRUNE=$NOW
    find "$LOG_DIR" -maxdepth 1 -name 'gpu-*.log' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
fi

{
    declare -p RING LAST_ALERT ERRBASE LASTCNT
    printf 'LAST_ERRPOLL=%s LAST_PRUNE=%s\n' "$LAST_ERRPOLL" "$LAST_PRUNE"
} >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
exit 0
