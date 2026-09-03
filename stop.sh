#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

STATE_DIR="$ROOT/state"
PID_FILE="$STATE_DIR/rider.pid"
STOP_FILE="$STATE_DIR/stop.request"
LOCK_DIR="$STATE_DIR/rider.lock"
SYSTEM_FILE="$STATE_DIR/system.state"

mkdir -p "$STATE_DIR"

echo "=================================================="
echo " 🔴 LIVE MAN API GUARD STOP"
echo "=================================================="

# ==================================================
# SAFE EXACT RIDER DISCOVERY
# ไม่ใช้ pgrep -f
# และไม่ให้นับ awk/stop.sh ตัวเอง
# ==================================================

get_rider_pids() {
    local self="$$"

    ps -eo pid=,args= 2>/dev/null |
    awk -v root="$ROOT/rider.sh" -v self="$self" '
        $1 != self &&
        $2 ~ /(^|\/)(bash|sh)$/ &&
        index($0, root) &&
        $0 !~ /awk -v root=/ {
            print $1
        }
    '
}

# ==================================================
# READ PID FILE
# ==================================================

PID=""

if [ -f "$PID_FILE" ]; then
    PID="$(tr -cd '0-9' < "$PID_FILE" 2>/dev/null || true)"
fi

# ขอให้ rider cleanup ตัวเองก่อน
touch "$STOP_FILE"

# ==================================================
# PRIMARY STOP
# ==================================================

if [ -n "$PID" ] && [ "$PID" != "$$" ] && kill -0 "$PID" 2>/dev/null; then

    echo "Rider PID : $PID"
    echo "Sending INT..."

    kill -INT "$PID" 2>/dev/null || true

    # รอ graceful cleanup สูงสุด 8 วินาที
    for _ in 1 2 3 4 5 6 7 8; do
        if ! kill -0 "$PID" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # TERM
    if kill -0 "$PID" 2>/dev/null; then
        echo "Sending TERM..."
        kill -TERM "$PID" 2>/dev/null || true

        for _ in 1 2 3 4; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi

    # KILL
    if kill -0 "$PID" 2>/dev/null; then
        echo "Sending KILL..."
        kill -KILL "$PID" 2>/dev/null || true
    fi

elif [ -n "$PID" ]; then
    echo "Rider PID not running: $PID"
else
    echo "No active rider PID"
fi

# ==================================================
# CLEAN ANY REMAINING EXACT RIDER
# ==================================================

echo
echo "Checking remaining rider processes..."

PIDS="$(get_rider_pids || true)"

if [ -n "$PIDS" ]; then
    for P in $PIDS; do
        [ "$P" = "$$" ] && continue

        if kill -0 "$P" 2>/dev/null; then
            echo "Cleaning leftover rider PID: $P"
            kill -TERM "$P" 2>/dev/null || true
        fi
    done
fi

# รอให้ทุกตัวหายก่อน
for _ in 1 2 3 4 5; do
    PIDS="$(get_rider_pids || true)"
    [ -z "$PIDS" ] && break
    sleep 1
done

# บังคับครั้งสุดท้าย
PIDS="$(get_rider_pids || true)"

if [ -n "$PIDS" ]; then
    for P in $PIDS; do
        [ "$P" = "$$" ] && continue

        if kill -0 "$P" 2>/dev/null; then
            echo "Force cleaning rider PID: $P"
            kill -KILL "$P" 2>/dev/null || true
        fi
    done
fi

# ==================================================
# FINAL PROCESS WAIT
# ==================================================

for _ in 1 2 3 4 5 6 7 8 9 10; do
    PIDS="$(get_rider_pids || true)"
    [ -z "$PIDS" ] && break
    sleep 1
done

# ==================================================
# WAKE LOCK RELEASE
# ==================================================

if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1 || true
    WAKE_STATUS="RELEASED"
else
    WAKE_STATUS="UNAVAILABLE"
fi

# ==================================================
# FINAL PROCESS CHECK
# ==================================================

PIDS="$(get_rider_pids || true)"

if [ -n "$PIDS" ]; then
    echo
    echo "===== VERIFY ====="
    echo "STATUS : FAIL"
    echo "Rider process still exists"

    for P in $PIDS; do
        ps -p "$P" -o pid=,ppid=,stat=,args= 2>/dev/null || true
    done

    exit 1
fi

# ==================================================
# CLEAN RUNTIME FILES
# ==================================================

rm -f "$PID_FILE" 2>/dev/null || true
rm -f "$STOP_FILE" 2>/dev/null || true
rm -rf "$LOCK_DIR" 2>/dev/null || true

# ==================================================
# PRESERVE FINAL RUNTIME COUNTERS
# ==================================================

state_value() {
    local key="$1"
    grep -m1 "^${key}=" "$SYSTEM_FILE" 2>/dev/null |
        cut -d= -f2-
}

FINAL_ROUND="$(state_value ROUND)"
FINAL_HEARTBEAT="$(state_value HEARTBEAT)"
FINAL_SUCCESS="$(state_value ENGINE_SUCCESS)"
FINAL_ERRORS="$(state_value ENGINE_ERRORS)"
FINAL_BUGS="$(state_value BUG_COUNT)"
FINAL_LAST_ERROR="$(state_value LAST_ERROR)"
FINAL_REASON="$(state_value REASON)"

FINAL_ROUND="${FINAL_ROUND:-0}"
FINAL_HEARTBEAT="${FINAL_HEARTBEAT:-0}"
FINAL_SUCCESS="${FINAL_SUCCESS:-0}"
FINAL_ERRORS="${FINAL_ERRORS:-0}"
FINAL_BUGS="${FINAL_BUGS:-0}"
FINAL_LAST_ERROR="${FINAL_LAST_ERROR:-NONE}"
FINAL_REASON="${FINAL_REASON:-STOP_COMMAND}"

# ==================================================
# WRITE FINAL STOPPED STATE
# ==================================================

NOW="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$ROOT/tmp"
TMP_STATE="$ROOT/tmp/system.state.stop.$$"

cat > "$TMP_STATE" <<STATE
STATUS=STOPPED
PID=0
ROUND=$FINAL_ROUND
HEARTBEAT=$FINAL_HEARTBEAT
TIME=$NOW
REASON=$FINAL_REASON
ENGINE_SUCCESS=$FINAL_SUCCESS
ENGINE_ERRORS=$FINAL_ERRORS
BUG_COUNT=$FINAL_BUGS
LAST_ERROR=$FINAL_LAST_ERROR
WAKE_LOCK=$WAKE_STATUS
STATE_OWNER=stop.sh
STATE

mv -f "$TMP_STATE" "$SYSTEM_FILE"

# ==================================================
# FINAL VERIFY
# ==================================================

FINAL_COUNT=0
FINAL_PIDS="$(get_rider_pids || true)"

for P in $FINAL_PIDS; do
    [ -n "$P" ] && FINAL_COUNT=$((FINAL_COUNT + 1))
done

echo
echo "===== VERIFY ====="
echo "ENGINE_COUNT : $FINAL_COUNT"

if [ "$FINAL_COUNT" -ne 0 ]; then
    echo "STATUS : FAIL"
    exit 1
fi

if [ -e "$PID_FILE" ]; then
    echo "PID_FILE : FAIL"
    exit 1
fi

if [ -e "$LOCK_DIR" ]; then
    echo "LOCK : FAIL"
    exit 1
fi

grep -q '^STATUS=STOPPED$' "$SYSTEM_FILE" || {
    echo "STATE : FAIL"
    exit 1
}

grep -q '^PID=0$' "$SYSTEM_FILE" || {
    echo "STATE_PID : FAIL"
    exit 1
}

echo "STATUS       : STOPPED"
echo "PID_FILE     : CLEAR"
echo "LOCK         : CLEAR"
echo "WAKE_LOCK    : $WAKE_STATUS"
echo "STATE_PID    : 0"
echo "PROCESS      : NONE"

echo
echo "=================================================="
echo " ✅ STOP COMPLETE"
echo "=================================================="
