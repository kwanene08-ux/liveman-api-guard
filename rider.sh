#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

STATE_DIR="$ROOT/state"
LOG_DIR="$ROOT/logs"

PID_FILE="$STATE_DIR/rider.pid"
LOCK_DIR="$STATE_DIR/rider.lock"
STOP_FILE="$STATE_DIR/stop.request"
HEARTBEAT_FILE="$STATE_DIR/heartbeat.state"
SYSTEM_FILE="$STATE_DIR/system.state"

START_TIME="$(date +%s)"

STOPPING=0
ROUND=0
HEARTBEAT=0

BUG_COUNT=0
STATE_ERRORS=0
RECOVERIES=0

LAST_ERROR="NONE"
ERROR_TIME="--"

ENGINE_SUCCESS=0
ENGINE_ERRORS=0

mkdir -p \
    "$STATE_DIR" \
    "$LOG_DIR" \
    "$ROOT/tmp"

# ==================================================
# LOAD CONFIG
# ==================================================

if [ -f "$ROOT/config/config.conf" ]; then
    source "$ROOT/config/config.conf"
fi

if [ -f "$ROOT/config/thresholds.conf" ]; then
    source "$ROOT/config/thresholds.conf"
fi

INTERVAL="${INTERVAL:-5}"

# ==================================================
# LOAD LIBRARY
# ==================================================

source "$ROOT/lib/core.sh"
source "$ROOT/lib/health.sh"
source "$ROOT/lib/trend.sh"
source "$ROOT/lib/alert.sh"
source "$ROOT/lib/error_guard.sh"
source "$ROOT/lib/api_guard.sh"
source "$ROOT/lib/wake_lock.sh"

# ==================================================
# LOAD ENGINES
# ==================================================

source "$ROOT/engines/gps_guard.sh"
source "$ROOT/engines/battery_guard.sh"
source "$ROOT/engines/network_guard.sh"
source "$ROOT/engines/thermal_guard.sh"
source "$ROOT/engines/watchdog.sh"

wake_lock_start

# ==================================================
# LOGGING
# ==================================================

log() {
    printf '%s | PID=%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$$" \
        "$1" \
        >> "$LOG_DIR/current.log"
}

error_log() {
    printf '%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$1" \
        >> "$LOG_DIR/error.log"
}

set_error() {
    LAST_ERROR="$1"
    ERROR_TIME="$(date '+%H:%M:%S')"

    BUG_COUNT=$((BUG_COUNT + 1))

    error_log "$1"
}

atomic_write() {

    local file="$1"
    local data="$2"
    local tmp="$file.tmp.$$"

    printf '%s\n' "$data" > "$tmp" || return 1

    mv -f "$tmp" "$file" || return 1

    return 0
}

# ==================================================
# CLEANUP
# ==================================================

cleanup() {

    local reason="${1:-EXIT}"

    if [ "$STOPPING" -eq 1 ]; then
        return
    fi

    STOPPING=1

      wake_lock_stop

    printf '\n'
    echo "=================================================="
    echo " STOPPING LIVE MAN API GUARD"
    echo "=================================================="
    echo "Reason: $reason"
    echo "PID   : $$"

    log "STOP reason=$reason"

    touch "$STOP_FILE" 2>/dev/null || true

    CHILDREN="$(pgrep -P "$$" 2>/dev/null || true)"

    for child in $CHILDREN; do
        kill -TERM "$child" 2>/dev/null || true
    done

    sleep 1

    for child in $CHILDREN; do
        if kill -0 "$child" 2>/dev/null; then
            kill -KILL "$child" 2>/dev/null || true
        fi
    done
      # Clear API runtime cooldown/backoff state on STOP.
      if declare -F api_guard_cleanup >/dev/null 2>&1; then
          api_guard_cleanup || true
      fi


    rm -f "$PID_FILE" 2>/dev/null || true
    rm -f "$STOP_FILE" 2>/dev/null || true
    rm -rf "$LOCK_DIR" 2>/dev/null || true

    atomic_write "$SYSTEM_FILE" \
"STATUS=STOPPED
PID=0
ROUND=$ROUND
HEARTBEAT=$HEARTBEAT
TIME=$(date '+%Y-%m-%d %H:%M:%S')
REASON=$reason
ENGINE_SUCCESS=$ENGINE_SUCCESS
ENGINE_ERRORS=$ENGINE_ERRORS
BUG_COUNT=$BUG_COUNT
STATE_ERRORS=$STATE_ERRORS
LAST_ERROR=$LAST_ERROR
STATE_OWNER=rider.sh" || true

    log "CLEANUP_COMPLETE"

    echo "PID CLEANED"
    echo "LOCK CLEANED"
    echo "CHILDREN CLEANED"
    echo "CLEANUP COMPLETE"
    echo "=================================================="
}

trap 'cleanup CTRL_C; exit 0' INT
trap 'cleanup TERM; exit 0' TERM
trap 'cleanup EXIT' EXIT

# ==================================================
# STALE LOCK REPAIR
# ==================================================

if [ -d "$LOCK_DIR" ]; then

    OLD_PID=""

    if [ -f "$PID_FILE" ]; then
        OLD_PID="$(tr -cd '0-9' < "$PID_FILE" 2>/dev/null || true)"
    fi

    if [ -n "$OLD_PID" ] && \
       kill -0 "$OLD_PID" 2>/dev/null
    then
        echo "=================================================="
        echo " LIVE MAN API GUARD ALREADY RUNNING"
        echo "=================================================="
        echo "PID: $OLD_PID"
        exit 1
    fi

    echo "STALE LOCK DETECTED -> REPAIRING"

    rm -rf "$LOCK_DIR" 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
fi

# ==================================================
# ATOMIC LOCK
# ==================================================

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: CANNOT CREATE LOCK"
    exit 1
fi

printf '%s\n' "$$" > "$PID_FILE"

rm -f "$STOP_FILE"

# ==================================================
# PREFLIGHT
# ==================================================

PREFLIGHT="PASS"
API_STATUS="READY"
API_HEALTH="READY"

for cmd in \
    bash \
    date \
    sleep \
    awk \
    grep \
    jq \
    timeout
do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        PREFLIGHT="WARNING"
        set_error "MISSING_COMMAND=$cmd"
    fi
done

if ! command -v termux-battery-status >/dev/null 2>&1; then
    API_STATUS="BATTERY_API_MISSING"
fi

if ! command -v termux-location >/dev/null 2>&1; then
    API_STATUS="GPS_API_MISSING"
fi

# Runtime API health is more meaningful than binary presence.
if declare -F api_health_overall >/dev/null 2>&1; then
    API_HEALTH="$(api_health_overall)"
    case "$API_HEALTH" in
        READY)
            API_STATUS="READY"
            ;;
        DEGRADED)
            API_STATUS="DEGRADED"
            ;;
        COOLDOWN)
            API_STATUS="COOLDOWN"
            ;;
        RECOVERING)
            API_STATUS="RECOVERING"
            ;;
        *)
            API_STATUS="$API_HEALTH"
            ;;
    esac
fi

# ==================================================
# ENGINE SUPERVISOR
# ==================================================

run_engine() {

    local name="$1"
    local function="$2"

    if "$function"; then

        ENGINE_SUCCESS=$((ENGINE_SUCCESS + 1))

        return 0

    fi

    ENGINE_ERRORS=$((ENGINE_ERRORS + 1))

    set_error "ENGINE_ERROR=$name"

    return 1
}

run_engines() {

    # ==================================================
    # V8.9.2 API ERROR CLASSIFICATION
    #
    # API timeout/cooldown + usable cache
    # = DEGRADED, NOT ENGINE ERROR
    # ==================================================

    # --------------------------------------------------
    # BATTERY
    # --------------------------------------------------
    if battery_guard; then

        ENGINE_SUCCESS=$((ENGINE_SUCCESS + 1))

        case "${BATTERY_STATUS:-UNSET}" in
            CACHE|API_COOLDOWN)
                log "BATTERY_DEGRADED status=${BATTERY_STATUS:-UNSET} pct=${BATTERY_PCT:---} cache_age=${BATTERY_CACHE_AGE:---}"
                ;;
            *)
                log "ENGINE_OK name=BATTERY status=${BATTERY_STATUS:-UNSET} pct=${BATTERY_PCT:---}"
                ;;
        esac

    else

        # ไม่มี cache/ข้อมูลจริงเลย = engine error จริง
        ENGINE_ERRORS=$((ENGINE_ERRORS + 1))
        set_error "ENGINE_ERROR=BATTERY"
        log "BATTERY_ERROR status=${BATTERY_STATUS:-UNSET}"
    fi

    # --------------------------------------------------
    # GPS
    # --------------------------------------------------
    if gps_guard; then

        ENGINE_SUCCESS=$((ENGINE_SUCCESS + 1))

        case "${GPS_STATUS:-UNSET}" in
            CACHE_FRESH|LIVE_NETWORK_CACHE|LIVE_NETWORK_COOLDOWN|LIVE_NETWORK_PROBE_WAIT|GPS_DRIFT_REJECTED|GPS_CACHE_PRESERVED)
                log "GPS_DEGRADED status=${GPS_STATUS:-UNSET} provider=${GPS_PROVIDER:---} accuracy=${GPS_ACC:---}m cache_age=${GPS_CACHE_AGE:---} cooldown=${GPS_COOLDOWN_UNTIL:-0} timeouts=${GPS_TIMEOUTS:-0}"
                ;;
            *)
                log "GPS_EVENT status=${GPS_STATUS:-UNSET} provider=${GPS_PROVIDER:---} accuracy=${GPS_ACC:---}m cache_age=${GPS_CACHE_AGE:---}s cooldown=${GPS_COOLDOWN_UNTIL:-0} timeouts=${GPS_TIMEOUTS:-0}"
                ;;
        esac

    else

        # V8.9.10 HARDENED:
        # CACHE_STALE is controlled GPS recovery/degraded state.
        # Do not count repeated stale-cache rounds as engine errors.
        # Only true no-location / structural failures are errors.
        case "${GPS_STATUS:-UNSET}" in
            CACHE_STALE)
                log "GPS_DEGRADED status=CACHE_STALE provider=${GPS_PROVIDER:---} accuracy=${GPS_ACC:---}m cache_age=${GPS_CACHE_AGE:---} cooldown=${GPS_COOLDOWN_UNTIL:-0} timeouts=${GPS_TIMEOUTS:-0}"
                ;;
            *)
                ENGINE_ERRORS=$((ENGINE_ERRORS + 1))
                set_error "ENGINE_ERROR=GPS"
                log "GPS_ERROR status=${GPS_STATUS:-UNSET} provider=${GPS_PROVIDER:---} accuracy=${GPS_ACC:---}m cache_age=${GPS_CACHE_AGE:---}"
                ;;
        esac
    fi

    # --------------------------------------------------
    # NETWORK
    # --------------------------------------------------
    if safe_engine_run "NETWORK" network_guard; then

        ENGINE_SUCCESS=$((ENGINE_SUCCESS + 1))
        log "NETWORK_EVENT status=${NETWORK_STATUS:-UNSET} ping=${NETWORK_PING:---}ms host=${NETWORK_HOST:---}"

    else

        ENGINE_ERRORS=$((ENGINE_ERRORS + 1))
        set_error "ENGINE_ERROR=NETWORK"
        log "NETWORK_ERROR status=${NETWORK_STATUS:-UNSET} ping=${NETWORK_PING:---}ms"
    fi

    # --------------------------------------------------
    # THERMAL
    # --------------------------------------------------
    if safe_engine_run "THERMAL" thermal_guard; then

        ENGINE_SUCCESS=$((ENGINE_SUCCESS + 1))
        log "THERMAL_EVENT status=${THERMAL_STATUS:-UNSET} temp=${THERMAL_TEMP:---}C"

    else

        ENGINE_ERRORS=$((ENGINE_ERRORS + 1))
        set_error "ENGINE_ERROR=THERMAL"
        log "THERMAL_ERROR status=${THERMAL_STATUS:-UNSET} temp=${THERMAL_TEMP:---}C"
    fi

    error_guard_recovery || true
}

# ==================================================
# SYSTEM STATE
# ==================================================

write_system_state() {

    local now
    now="$(date '+%Y-%m-%d %H:%M:%S')"

    if ! atomic_write "$SYSTEM_FILE" \
"STATUS=RUNNING
PID=$$
ROUND=$ROUND
HEARTBEAT=$HEARTBEAT
TIME=$now
GPS_STATUS=${GPS_STATUS:-UNSET}
BATTERY_STATUS=${BATTERY_STATUS:-UNSET}
NETWORK_STATUS=${NETWORK_STATUS:-UNSET}
THERMAL_STATUS=${THERMAL_STATUS:-UNSET}
ENGINE_SUCCESS=$ENGINE_SUCCESS
ENGINE_ERRORS=$ENGINE_ERRORS
BUG_COUNT=$BUG_COUNT
STATE_ERRORS=$STATE_ERRORS
LAST_ERROR=$LAST_ERROR
ERROR_GUARD_STATUS=$(error_guard_status)
ERROR_GUARD_TOTAL=${ERROR_GUARD_TOTAL:-0}
ERROR_GUARD_CONSECUTIVE=${ERROR_GUARD_CONSECUTIVE:-0}
ERROR_GUARD_RECOVERIES=${ERROR_GUARD_RECOVERIES:-0}
ERROR_GUARD_TYPE=${ERROR_GUARD_TYPE:-NONE}"
    then
        STATE_ERRORS=$((STATE_ERRORS + 1))
    fi

    atomic_write "$HEARTBEAT_FILE" \
"HEARTBEAT=$HEARTBEAT
ROUND=$ROUND
PID=$$
TIME=$now" || STATE_ERRORS=$((STATE_ERRORS + 1))
}

# ==================================================
# UI
# ==================================================

show_ui() {

    HEALTH_AVG_PING="$(network_average_ping)"
    HEALTH_NET_STABILITY="$(network_stability)"
    HEALTH_SCORE="$(system_health_score)"
    HEALTH_STATUS="$(system_health_status "$HEALTH_SCORE")"

    local now uptime

    now="$(date +%s)"
    uptime=$((now - START_TIME))

    if declare -F api_health_overall >/dev/null 2>&1; then
        API_HEALTH="$(api_health_overall)"
        API_STATUS="$API_HEALTH"
    fi

    clear

    echo "=================================================="
    echo " LIVE MAN API GUARD $(cat "$ROOT/VERSION" 2>/dev/null || echo "UNKNOWN") ENGINE SUPERVISOR"
    echo "=================================================="
    echo

    printf ' PID                   : %s\n' "$$"
    printf ' Round                 : #%s\n' "$ROUND"
    printf ' Heartbeat             : %s\n' "$HEARTBEAT"
    printf ' System                : RUNNING\n'
    printf ' Uptime                : %ss\n' "$uptime"

    echo

    printf ' Preflight             : %s\n' "$PREFLIGHT"
    API_HEALTH_LOCATION="$(api_location_health 2>/dev/null || echo UNKNOWN)"
    API_HEALTH_BATTERY="$(api_battery_health 2>/dev/null || echo UNKNOWN)"

    printf ' Termux:API            : %s\n' "$API_STATUS"
    printf ' Location API          : %s\n' "$API_HEALTH_LOCATION"
    printf ' Battery API           : %s\n' "$API_HEALTH_BATTERY"

    echo
    echo "---------------- ENGINE STATUS ------------------"

    printf ' GPS                   : %s\n' "${GPS_STATUS:-UNSET}"
    printf ' Accuracy              : %sm\n' "${GPS_ACC:---}"

    printf ' Battery               : %s\n' "${BATTERY_STATUS:-UNSET}"
    printf ' Battery Level         : %s%%\n' "${BATTERY_PCT:---}"

    printf ' Network               : %s\n' "${NETWORK_STATUS:-UNSET}"
    printf ' Ping                  : %sms\n' "${NETWORK_PING:---}"
    printf ' Host                  : %s\n' "${NETWORK_HOST:---}"

    printf ' Thermal               : %s\n' "${THERMAL_STATUS:-UNSET}"
    printf ' Temperature           : %s°C\n' "${THERMAL_TEMP:---}"

    echo
    echo "---------------- SMART HEALTH -------------------
 GPS Cache Age         : $(gps_cache_age)s
 Network Average       : ${HEALTH_AVG_PING}ms
 Network Stability     : ${HEALTH_NET_STABILITY}

 SYSTEM HEALTH SCORE   : ${HEALTH_SCORE}/100
 SYSTEM HEALTH STATUS  : ${HEALTH_STATUS}

---------------- SUPERVISOR ---------------------"

    printf ' Engine Success        : %s\n' "$ENGINE_SUCCESS"
    printf ' Engine Errors         : %s\n' "$ENGINE_ERRORS"

    printf ' Auto Debug            : ACTIVE\n'
    printf ' Bug Count             : %s\n' "$BUG_COUNT"
    printf ' State Errors          : %s\n' "$STATE_ERRORS"
    printf ' Recoveries            : %s\n' "$RECOVERIES"

    printf ' Last Error            : %s\n' "$LAST_ERROR"
    printf ' Error Time            : %s\n' "$ERROR_TIME"

    echo
    echo "---------------- PROTECTION ---------------------"

    printf ' Lock                  : ATOMIC DIRECTORY LOCK\n'
    printf ' Stale Lock Repair     : ACTIVE\n'
    printf ' PID Verification      : ACTIVE\n'
    printf ' Ctrl+C Cleanup        : HARDENED\n'
    printf ' TERM Cleanup          : HARDENED\n'
    printf ' Engine Isolation      : ACTIVE\n'
    printf ' Atomic State Write    : ACTIVE\n'
    printf " Wake Lock             : %s\n" "${WAKE_LOCK_STATUS:-UNKNOWN}"


    echo
    printf ' State                 : %s\n' "$STATE_DIR"
    printf ' Log                   : %s/current.log\n' "$LOG_DIR"

    echo
    echo "Ctrl+C เพื่อหยุดอย่างปลอดภัย"
    echo "=================================================="
}

# ==================================================
# START
# ==================================================

log "START version=$(cat "$ROOT/VERSION" 2>/dev/null || echo "UNKNOWN") pid=$$"

while true; do

    # V12 supervisor watchdog
    if ! watchdog_check; then
        STATE_ERRORS=$((STATE_ERRORS + 1))
        log "WATCHDOG_ERROR status=${WATCHDOG_STATUS:-UNKNOWN}"
    fi

    watchdog_tick || {
        STATE_ERRORS=$((STATE_ERRORS + 1))
        log "WATCHDOG_TICK_ERROR"
    }

    wake_lock_guard

    if [ -f "$STOP_FILE" ]; then
        log "STOP_FILE_DETECTED"
        break
    fi

    ROUND=$((ROUND + 1))
    HEARTBEAT=$((HEARTBEAT + 1))

    run_engines

    # Update health values before writing state/UI
    HEALTH_AVG_PING="$(network_average_ping)"
    HEALTH_NET_STABILITY="$(network_stability)"
    HEALTH_SCORE="$(system_health_score)"
    HEALTH_STATUS="$(system_health_status "$HEALTH_SCORE")"

    SYSTEM_HEALTH_SCORE="$HEALTH_SCORE"
    SYSTEM_HEALTH_STATUS="$HEALTH_STATUS"

    # Trend updates
    network_trend_update || true
    gps_trend_update || true
    health_trend_update || true

    # Smart alerts
    smart_alert_check || true

    write_system_state

    show_ui

    log "ROUND_END round=$ROUND heartbeat=$HEARTBEAT gps=${GPS_STATUS:-UNSET} network=${NETWORK_STATUS:-UNSET} battery=${BATTERY_STATUS:-UNSET} thermal=${THERMAL_STATUS:-UNSET} health=${SYSTEM_HEALTH_STATUS:-UNSET} score=${SYSTEM_HEALTH_SCORE:-0}"

    sleep "$INTERVAL"
done

exit 0
