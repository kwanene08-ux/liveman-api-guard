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
STOP_FILE="$STATE_DIR/stop.request"

INTERVAL="${SUPERVISOR_INTERVAL:-5}"
HEARTBEAT_TIMEOUT="${SUPERVISOR_HEARTBEAT_TIMEOUT:-45}"
MAX_RESTARTS="${SUPERVISOR_MAX_RESTARTS:-8}"
RESTART_BACKOFF="${SUPERVISOR_RESTART_BACKOFF:-3}"
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

read_kv() {
    local file="$1"
    local key="$2"

    [ -f "$file" ] || return 1

    awk -F= -v k="$key" '
        $1 == k {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$file"
}

rider_pid() {
    local pid=""

    if [ -f "$RIDER_PID_FILE" ]; then
        pid="$(tr -cd '0-9' < "$RIDER_PID_FILE" 2>/dev/null || true)"
    fi

    printf '%s\n' "$pid"
}

pid_alive() {
    local pid="${1:-}"

    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
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

stop_rider() {
    local pid="${1:-}"

    [ -n "$pid" ] || return 0

    kill -TERM "$pid" 2>/dev/null || true

    for _ in 1 2 3 4 5; do
        pid_alive "$pid" || return 0
        sleep 1
    done

    kill -KILL "$pid" 2>/dev/null || true
}

start_rider() {
    rm -f "$STOP_FILE" 2>/dev/null || true

    nohup "$ROOT/rider.sh" \
        >> "$LOG_DIR/advanced_rider.stdout.log" 2>&1 &

    local pid=$!

    log "RIDER_START pid=$pid"

    sleep 1

    if pid_alive "$pid"; then
        return 0
    fi

    log "RIDER_START_FAILED pid=$pid"
    return 1
}

restart_rider() {
    local reason="$1"
    local pid
    local delay

    if [ "$RESTARTS" -ge "$MAX_RESTARTS" ]; then
        LAST_REASON="RESTART_LIMIT"
        log "RESTART_BLOCKED reason=$reason count=$RESTARTS limit=$MAX_RESTARTS"
        return 1
    fi

    pid="$(rider_pid)"

    RESTARTS=$((RESTARTS + 1))
    LAST_RESTART="$(date +%s)"
    LAST_REASON="$reason"

    log "RESTART_EVENT count=$RESTARTS reason=$reason old_pid=${pid:-0}"

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
    hb="$(read_kv "$HEARTBEAT_FILE" HEARTBEAT 2>/dev/null || echo 0)"
    age="$(heartbeat_age)"
    status="$(read_kv "$SYSTEM_FILE" STATUS 2>/dev/null || echo UNKNOWN)"
    now="$(date '+%Y-%m-%d %H:%M:%S')"

    atomic_write "$SUP_STATE" \
"STATUS=RUNNING
SUPERVISOR_PID=$$
RIDER_PID=${pid:-0}
RIDER_STATUS=$status
HEARTBEAT=${hb:-0}
HEARTBEAT_AGE=$age
RESTARTS=$RESTARTS
LAST_RESTART=$LAST_RESTART
LAST_REASON=$LAST_REASON
TIME=$now"
}

show_status() {
    local pid hb age status score

    pid="$(rider_pid)"
    hb="$(read_kv "$HEARTBEAT_FILE" HEARTBEAT 2>/dev/null || echo 0)"
    age="$(heartbeat_age)"
    status="$(read_kv "$SYSTEM_FILE" STATUS 2>/dev/null || echo UNKNOWN)"

    score="$(
        grep -o 'health=[0-9]*' \
            "$LOG_DIR/current.log" 2>/dev/null |
        tail -1 |
        cut -d= -f2 || true
    )"

    [ -n "$score" ] || score="--"

    clear

    echo "=================================================="
    echo " LIVE MAN ADVANCED SUPERVISOR"
    echo "=================================================="

    printf ' Supervisor PID        : %s\n' "$$"
    printf ' Rider PID             : %s\n' "${pid:-0}"

    if pid_alive "${pid:-0}"; then
        printf ' Rider Process         : ALIVE\n'
    else
        printf ' Rider Process         : DOWN\n'
    fi

    printf ' Rider State           : %s\n' "$status"
    printf ' Heartbeat             : %s\n' "${hb:-0}"
    printf ' Heartbeat Age         : %ss\n' "$age"
    printf ' Health Score Latest   : %s\n' "$score"
    printf ' Restarts              : %s/%s\n' "$RESTARTS" "$MAX_RESTARTS"
    printf ' Last Restart Reason   : %s\n' "$LAST_REASON"
    printf ' Auto Restart          : %s\n' "$AUTO_RESTART"
    printf ' Heartbeat Timeout     : %ss\n' "$HEARTBEAT_TIMEOUT"

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
    echo " Rider จะไม่ถูกหยุดเมื่อกด Ctrl+C"
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

if ! mkdir "$SUP_LOCK" 2>/dev/null; then
    echo "ERROR: SUPERVISOR LOCK"
    exit 1
fi

if [ ! -x "$ROOT/rider.sh" ]; then
    echo "ERROR: rider.sh ไม่มี execute permission"
    chmod +x "$ROOT/rider.sh" 2>/dev/null || true
fi

log "SUPERVISOR_START version=$(cat "$ROOT/VERSION" 2>/dev/null || echo UNKNOWN)"

if ! pid_alive "$(rider_pid)"; then
    if [ "$AUTO_RESTART" = "true" ]; then
        start_rider || true
    fi
fi

while true; do
    pid="$(rider_pid)"
    age="$(heartbeat_age)"

    if ! pid_alive "$pid"; then
        if [ "$AUTO_RESTART" = "true" ]; then
            restart_rider "RIDER_PROCESS_DOWN" || sleep "$INTERVAL"
        fi

    elif [ "$age" -gt "$HEARTBEAT_TIMEOUT" ]; then
        if [ "$AUTO_RESTART" = "true" ]; then
            restart_rider "HEARTBEAT_STALE_${age}s" || sleep "$INTERVAL"
        fi
    fi

    write_state
    show_status

    sleep "$INTERVAL"
done
