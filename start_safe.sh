#!/data/data/com.termux/files/usr/bin/bash
set -u

ROOT="$HOME/LIVE_MAN_API_GUARD"
STATE="$ROOT/state"

PID_FILE="$STATE/rider.pid"
SUP_PID_FILE="$STATE/supervisor.pid"
START_LOCK="$STATE/start_safe.lock"

SUP="$ROOT/advanced_supervisor.sh"

mkdir -p "$STATE" "$ROOT/logs"

log() {
    printf '%s | SAFE_START | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$ROOT/logs/start_safe.log"
}

pid_alive() {
    local pid="${1:-}"

    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac

    kill -0 "$pid" 2>/dev/null
}

is_supervisor_pid() {
    local pid="${1:-}"

    pid_alive "$pid" || return 1

    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null |
        grep -Fq "$ROOT/advanced_supervisor.sh"
}

cleanup() {
    rm -rf "$START_LOCK" 2>/dev/null || true
}

echo "=================================================="
echo " LIVE MAN SAFE START v5"
echo "=================================================="

# กันกด START ซ้อนกัน
if [ -d "$START_LOCK" ]; then
    LOCK_PID="$(cat "$START_LOCK/pid" 2>/dev/null || true)"

    if pid_alive "$LOCK_PID"; then
        echo "START already running : $LOCK_PID"
        log "START_LOCK_BUSY pid=$LOCK_PID"
        exit 0
    fi

    rm -rf "$START_LOCK" 2>/dev/null || true
fi

if ! mkdir "$START_LOCK" 2>/dev/null; then
    echo "START already in progress"
    log "START_LOCK_BUSY"
    exit 0
fi

echo "$$" > "$START_LOCK/pid"
trap cleanup EXIT INT TERM

if [ ! -f "$SUP" ]; then
    echo "❌ ERROR: advanced_supervisor.sh not found"
    log "SUPERVISOR_NOT_FOUND"
    exit 1
fi

# ตรวจจาก PID file ก่อน
if [ -s "$SUP_PID_FILE" ]; then
    OLD_SUP="$(cat "$SUP_PID_FILE" 2>/dev/null || true)"

    if is_supervisor_pid "$OLD_SUP"; then
        echo "Supervisor Already Running : $OLD_SUP"
        log "EXISTING_SUPERVISOR pid=$OLD_SUP"
        exit 0
    fi

    rm -f "$SUP_PID_FILE"
fi

# ตรวจ Supervisor ที่มีอยู่จริง
EXISTING_SUP=""

for PID in $(pgrep -f "$ROOT/advanced_supervisor.sh" 2>/dev/null || true); do
    if is_supervisor_pid "$PID"; then
        if [ -z "$EXISTING_SUP" ]; then
            EXISTING_SUP="$PID"
        else
            echo "❌ พบ Supervisor มากกว่า 1 ตัว"
            echo "PID: $EXISTING_SUP"
            echo "PID: $PID"
            log "MULTIPLE_SUPERVISOR pid1=$EXISTING_SUP pid2=$PID"
            exit 2
        fi
    fi
done

if [ -n "$EXISTING_SUP" ]; then
    echo "$EXISTING_SUP" > "$SUP_PID_FILE"
    echo "Supervisor Already Running : $EXISTING_SUP"
    log "EXISTING_SUPERVISOR pid=$EXISTING_SUP"
    exit 0
fi

# เริ่ม Supervisor
nohup bash "$SUP" \
    >> "$ROOT/logs/advanced_supervisor.stdout.log" 2>&1 &

NEW_SUP="$!"
echo "$NEW_SUP" > "$SUP_PID_FILE"

echo "Supervisor Launch : STARTED"
echo "Supervisor PID    : $NEW_SUP"

log "SUPERVISOR_LAUNCH pid=$NEW_SUP"

# รอ Supervisor
READY=0

for _ in $(seq 1 20); do
    sleep 0.25

    if is_supervisor_pid "$NEW_SUP"; then
        READY=1
        break
    fi
done

if [ "$READY" -ne 1 ]; then
    echo "❌ Supervisor failed to stay alive"
    log "SUPERVISOR_START_FAILED pid=$NEW_SUP"
    rm -f "$SUP_PID_FILE"
    exit 3
fi

# ตรวจเฉพาะ PID ที่เพิ่งเริ่ม ไม่ใช้การนับ pgrep
if ! is_supervisor_pid "$NEW_SUP"; then
    echo "❌ Supervisor PID verification failed"
    log "SUPERVISOR_PID_VERIFY_FAILED pid=$NEW_SUP"
    exit 4
fi

echo
echo "=============================================="
echo "✅ START PASSED"
echo "=============================================="
echo "Supervisor PID : $NEW_SUP"
echo "Supervisor     : RUNNING"
echo "Rider          : SUPERVISOR CONTROLLED"
echo "Duplicate Scan : PID LOCK PASS"
echo "=============================================="

log "START_PASS supervisor=$NEW_SUP"

exit 0
