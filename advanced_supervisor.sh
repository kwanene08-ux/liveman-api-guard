#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

STATE_DIR="$ROOT/state"
LOG_DIR="$ROOT/logs"

SUP_STATE="$STATE_DIR/advanced_supervisor.state"
SUP_LOG="$LOG_DIR/advanced_supervisor.log"
SUP_LOCK="$STATE_DIR/advanced_supervisor.lock"

RIDER_PID_FILE="$STATE_DIR/rider.pid"
HEARTBEAT_FILE="$STATE_DIR/heartbeat.state"
SYSTEM_FILE="$STATE_DIR/system.state"

INTERVAL="${SUPERVISOR_INTERVAL:-5}"
HEARTBEAT_TIMEOUT="${SUPERVISOR_HEARTBEAT_TIMEOUT:-45}"
MAX_RESTARTS="${SUPERVISOR_MAX_RESTARTS:-8}"
RESTART_BACKOFF="${SUPERVISOR_RESTART_BACKOFF:-3}"
START_WAIT="${SUPERVISOR_START_WAIT:-15}"
AUTO_RESTART="${SUPERVISOR_AUTO_RESTART:-true}"

STOPPING=0
RESTARTS=0
LAST_RESTART=0
LAST_REASON="NONE"

mkdir -p "$STATE_DIR" "$LOG_DIR"

log() {
    printf '%s | SUP_PID=%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$$" \
        "$1" >> "$SUP_LOG"
}

atomic_write() {
    local file="$1"
    local data="$2"
    local tmp="$file.tmp.$$"

    printf '%s\n' "$data" > "$tmp" || return 1
    mv -f "$tmp" "$file" || return 1
}

rider_pid() {
    local pid=""

    [ -f "$RIDER_PID_FILE" ] || {
        printf '0\n'
        return
    }

    pid="$(tr -cd '0-9' < "$RIDER_PID_FILE" 2>/dev/null || true)"

    [ -n "$pid" ] || pid=0

    printf '%s\n' "$pid"
}

pid_alive() {
    local pid="${1:-0}"

    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac

    [ "$pid" -gt 0 ] || return 1

    kill -0 "$pid" 2>/dev/null
}

pid_is_rider() {
    local pid="${1:-0}"

    pid_alive "$pid" || return 1

    local cmd=""
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"

    case "$cmd" in
        *rider.sh*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

heartbeat_age() {
    local now mt

    [ -f "$HEARTBEAT_FILE" ] || {
        echo 999999
        return
    }

    now="$(date +%s)"
    mt="$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"

    [ "$mt" -gt 0 ] || {
        echo 999999
        return
    }

    echo $((now - mt))
}

wait_for_rider_pid() {
    local wait_s="$START_WAIT"
    local i pid

    case "$wait_s" in
        ''|*[!0-9]*) wait_s=15 ;;
    esac

    i=0

    while [ "$i" -lt "$wait_s" ]; do
        pid="$(rider_pid)"

        if pid_is_rider "$pid"; then
            printf '%s\n' "$pid"
            return 0
        fi

        sleep 1
        i=$((i + 1))
    done

    return 1
}

stop_rider() {
    local pid="${1:-0}"

    if ! pid_is_rider "$pid"; then
        return 0
    fi

    log "RIDER_STOP pid=$pid"

    kill -TERM "$pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
        pid_is_rider "$pid" || return 0
        sleep 1
    done

    kill -KILL "$pid" 2>/dev/null || true
}

start_rider() {
    local launched_pid rider_pid_found

    rm -f "$RIDER_PID_FILE"
    rm -f "$HEARTBEAT_FILE"

    nohup "$ROOT/rider.sh" \
        >> "$LOG_DIR/advanced_rider.stdout.log" 2>&1 &

    launched_pid=$!

    log "RIDER_LAUNCH shell_pid=$launched_pid"

    rider_pid_found="$(wait_for_rider_pid 2>/dev/null || true)"

    if [ -n "$rider_pid_found" ] &&
       pid_is_rider "$rider_pid_found"
    then
        log "RIDER_READY pid=$rider_pid_found"
        return 0
    fi

    log "RIDER_START_FAILED shell_pid=$launched_pid"

    if pid_alive "$launched_pid"; then
        kill -TERM "$launched_pid" 2>/dev/null || true
    fi

    return 1
}

restart_rider() {
    local reason="$1"
    local pid delay

    if [ "$RESTARTS" -ge "$MAX_RESTARTS" ]; then
        LAST_REASON="RESTART_LIMIT"
        log "RESTART_BLOCKED reason=$reason count=$RESTARTS limit=$MAX_RESTARTS"
        return 1
    fi

    pid="$(rider_pid)"

    RESTARTS=$((RESTARTS + 1))
    LAST_RESTART="$(date +%s)"
    LAST_REASON="$reason"

    log "RESTART_EVENT count=$RESTARTS reason=$reason pid=${pid:-0}"

    stop_rider "$pid"

    delay="$RESTART_BACKOFF"

    case "$delay" in
        ''|*[!0-9]*) delay=3 ;;
    esac

    sleep "$delay"

    start_rider
}

write_state() {
    local pid hb age status now

    pid="$(rider_pid)"
    hb="$(awk -F= '
        $1=="HEARTBEAT" { print $2; found=1; exit }
        END {
            if (!found) {
                if ($0 ~ /^[0-9]+$/) print $0
                else print 0
            }
        }
    ' "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"

    # Fallback: system.state is authoritative when heartbeat.state
    # contains only a timestamp/legacy format.
    if ! case "$hb" in ''|*[!0-9]*) false ;; esac; then
        hb=0
    fi

    if [ "$hb" -eq 0 ] && [ -f "$SYSTEM_FILE" ]; then
        sys_hb="$(awk -F= '$1=="HEARTBEAT"{print $2; exit}' "$SYSTEM_FILE" 2>/dev/null || true)"
        case "$sys_hb" in
            ''|*[!0-9]*) ;;
            *) hb="$sys_hb" ;;
        esac
    fi

    age="$(heartbeat_age)"
    status="$(awk -F= '$1=="STATUS"{print $2; exit}' "$SYSTEM_FILE" 2>/dev/null || echo UNKNOWN)"
    now="$(date '+%Y-%m-%d %H:%M:%S')"

    atomic_write "$SUP_STATE" \
"STATUS=RUNNING
SUPERVISOR_PID=$$
RIDER_PID=${pid:-0}
RIDER_PROCESS=$(pid_is_rider "$pid" && echo ALIVE || echo DOWN)
RIDER_STATUS=$status
HEARTBEAT=${hb:-0}
HEARTBEAT_AGE=$age
RESTARTS=$RESTARTS
LAST_RESTART=$LAST_RESTART
LAST_REASON=$LAST_REASON
TIME=$now"
}

show_status() {
    local pid hb age status

    pid="$(rider_pid)"
    hb="$(awk -F= '
        $1=="HEARTBEAT" { print $2; found=1; exit }
        END {
            if (!found) {
                if ($0 ~ /^[0-9]+$/) print $0
                else print 0
            }
        }
    ' "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"

    # Fallback: system.state is authoritative when heartbeat.state
    # contains only a timestamp/legacy format.
    if ! case "$hb" in ''|*[!0-9]*) false ;; esac; then
        hb=0
    fi

    if [ "$hb" -eq 0 ] && [ -f "$SYSTEM_FILE" ]; then
        sys_hb="$(awk -F= '$1=="HEARTBEAT"{print $2; exit}' "$SYSTEM_FILE" 2>/dev/null || true)"
        case "$sys_hb" in
            ''|*[!0-9]*) ;;
            *) hb="$sys_hb" ;;
        esac
    fi

    age="$(heartbeat_age)"
    status="$(awk -F= '$1=="STATUS"{print $2; exit}' "$SYSTEM_FILE" 2>/dev/null || echo UNKNOWN)"

    clear

    echo "=================================================="
    echo " LIVE MAN ADVANCED SUPERVISOR v12.3.1"
    echo "=================================================="

    printf ' Supervisor PID        : %s\n' "$$"
    printf ' Rider PID             : %s\n' "${pid:-0}"

    if pid_is_rider "$pid"; then
        printf ' Rider Process         : ALIVE\n'
    else
        printf ' Rider Process         : DOWN\n'
    fi

    printf ' Rider State           : %s\n' "$status"
    printf ' Heartbeat             : %s\n' "${hb:-0}"
    printf ' Heartbeat Age         : %ss\n' "$age"
    printf ' Restarts              : %s/%s\n' "$RESTARTS" "$MAX_RESTARTS"
    printf ' Last Restart Reason   : %s\n' "$LAST_REASON"
    printf ' Auto Restart          : %s\n' "$AUTO_RESTART"
    printf ' Heartbeat Timeout     : %ss\n' "$HEARTBEAT_TIMEOUT"
    printf ' Start Synchronization : ACTIVE\n'
    printf ' PID Identity Check    : ACTIVE\n'

    echo
    echo "---------------- ADVANCED PROTECTION -------------"
    echo " Process Watch         : ACTIVE"
    echo " Heartbeat Watch       : ACTIVE"
    echo " Auto Restart          : ACTIVE"
    echo " Restart Backoff       : ACTIVE"
    echo " Restart Limit         : ACTIVE"
    echo " Atomic Supervisor     : ACTIVE"
    echo
    echo " Ctrl+C = หยุด Supervisor"
    echo "=================================================="
}

cleanup() {
    [ "$STOPPING" -eq 1 ] && return

    STOPPING=1

    rm -rf "$SUP_LOCK" 2>/dev/null || true

    atomic_write "$SUP_STATE" \
"STATUS=STOPPED
SUPERVISOR_PID=0
RIDER_PID=$(rider_pid)
RESTARTS=$RESTARTS
LAST_RESTART=$LAST_RESTART
LAST_REASON=$LAST_REASON
TIME=$(date '+%Y-%m-%d %H:%M:%S')" || true

    log "SUPERVISOR_STOP"
}

trap 'cleanup; exit 0' INT
trap 'cleanup; exit 0' TERM
trap 'cleanup' EXIT

if [ -d "$SUP_LOCK" ]; then
    echo "ADVANCED SUPERVISOR ALREADY RUNNING"
    exit 1
fi

mkdir "$SUP_LOCK" || exit 1

chmod +x "$ROOT/rider.sh"

log "SUPERVISOR_START version=v12.3.1"

pid="$(rider_pid)"

if pid_is_rider "$pid"; then
    log "EXISTING_RIDER_ACCEPTED pid=$pid"
elif [ "$AUTO_RESTART" = "true" ]; then
    start_rider || {
        log "INITIAL_RIDER_START_FAILED"
    }
fi

while true; do

    pid="$(rider_pid)"
    age="$(heartbeat_age)"

    if ! pid_is_rider "$pid"; then
        if [ "$AUTO_RESTART" = "true" ]; then
            restart_rider "RIDER_PROCESS_DOWN" || true
        fi

    elif [ "$age" -gt "$HEARTBEAT_TIMEOUT" ]; then
        if [ "$AUTO_RESTART" = "true" ]; then
            restart_rider "HEARTBEAT_STALE_${age}s" || true
        fi
    fi

    write_state
    show_status

    sleep "$INTERVAL"
done
