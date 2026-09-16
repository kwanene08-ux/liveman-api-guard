#!/data/data/com.termux/files/usr/bin/bash

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT/state"
LOG_DIR="$ROOT/logs"

RIDER_PID_FILE="$STATE_DIR/rider.pid"
SUP_PID_FILE="$STATE_DIR/supervisor.pid"
STOP_FILE="$STATE_DIR/stop.request"
LOCK_DIR="$STATE_DIR/rider.lock"
SUP_LOCK_DIR="$STATE_DIR/advanced_supervisor.lock"
SYSTEM_FILE="$STATE_DIR/system.state"

mkdir -p "$STATE_DIR" "$LOG_DIR"

echo "=================================================="
echo " 🔴 LIVE MAN API GUARD STOP ALL"
echo "=================================================="

valid_pid() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
        *) return 0 ;;
    esac
}

cmdline() {
    local pid="$1"
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true
}

is_supervisor() {
    local pid="${1:-0}"
    kill -0 "$pid" 2>/dev/null || return 1
    case "$(cmdline "$pid")" in
        *advanced_supervisor.sh*) return 0 ;;
        *) return 1 ;;
    esac
}

is_rider() {
    local pid="${1:-0}"
    kill -0 "$pid" 2>/dev/null || return 1
    case "$(cmdline "$pid")" in
        *rider.sh*) return 0 ;;
        *) return 1 ;;
    esac
}

read_pid() {
    local file="$1"
    local p=""
    [ -f "$file" ] || return 0
    p="$(tr -cd '0-9' < "$file" 2>/dev/null || true)"
    printf '%s\n' "$p"
}

wait_dead() {
    local pid="$1"
    local seconds="${2:-10}"

    for _ in $(seq 1 "$seconds"); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done

    return 1
}

# --------------------------------------------------
# Stop request first
# --------------------------------------------------

touch "$STOP_FILE"

# --------------------------------------------------
# 1) STOP ADVANCED SUPERVISOR FIRST
#    เพื่อป้องกัน AUTO_RESTART rider
# --------------------------------------------------

SUP_PID="$(read_pid "$SUP_PID_FILE")"

if valid_pid "$SUP_PID" && is_supervisor "$SUP_PID"; then
    echo "Supervisor PID : $SUP_PID"
    echo "Sending TERM to supervisor..."
    kill -TERM "$SUP_PID" 2>/dev/null || true

    if wait_dead "$SUP_PID" 10; then
        echo "Supervisor     : STOPPED"
    else
        echo "Supervisor     : FORCE KILL"
        kill -KILL "$SUP_PID" 2>/dev/null || true
    fi
else
    echo "Supervisor     : NOT ACTIVE"
fi

# --------------------------------------------------
# 2) STOP RIDER
# --------------------------------------------------

RIDER_PID="$(read_pid "$RIDER_PID_FILE")"

if valid_pid "$RIDER_PID" && is_rider "$RIDER_PID"; then
    echo "Rider PID      : $RIDER_PID"
    echo "Sending INT..."
    kill -INT "$RIDER_PID" 2>/dev/null || true

    if wait_dead "$RIDER_PID" 8; then
        echo "Rider          : STOPPED"
    else
        echo "Sending TERM..."
        kill -TERM "$RIDER_PID" 2>/dev/null || true

        if ! wait_dead "$RIDER_PID" 4; then
            echo "Rider          : FORCE KILL"
            kill -KILL "$RIDER_PID" 2>/dev/null || true
        fi
    fi
else
    echo "Rider          : NOT ACTIVE"
fi

# --------------------------------------------------
# 3) CLEAN EXACT REMAINING PROJECT PROCESSES
#    ไม่ใช้ pkill -f แบบกว้าง
# --------------------------------------------------

echo
echo "===== FINAL PROCESS CLEANUP ====="

for P in $(ps -ef 2>/dev/null | awk -v root="$ROOT" '
    $2 ~ /^[0-9]+$/ &&
    index($0, root) &&
    ($0 ~ /advanced_supervisor\.sh/ || $0 ~ /rider\.sh/) {
        print $2
    }
'); do
    [ "$P" = "$$" ] && continue

    if is_supervisor "$P" || is_rider "$P"; then
        echo "Cleaning PID : $P"
        kill -TERM "$P" 2>/dev/null || true
    fi
done

sleep 2

for P in $(ps -ef 2>/dev/null | awk -v root="$ROOT" '
    $2 ~ /^[0-9]+$/ &&
    index($0, root) &&
    ($0 ~ /advanced_supervisor\.sh/ || $0 ~ /rider\.sh/) {
        print $2
    }
'); do
    [ "$P" = "$$" ] && continue

    if is_supervisor "$P" || is_rider "$P"; then
        echo "Force cleaning PID : $P"
        kill -KILL "$P" 2>/dev/null || true
    fi
done

# --------------------------------------------------
# 4) WAKE LOCK RELEASE
# --------------------------------------------------

if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1 || true
    WAKE_STATUS="RELEASED"
else
    WAKE_STATUS="UNAVAILABLE"
fi

# --------------------------------------------------
# 5) VERIFY NO PROJECT PROCESS REMAINS
# --------------------------------------------------

REMAINING="$(ps -ef 2>/dev/null | awk -v root="$ROOT" '
    index($0, root) &&
    ($0 ~ /advanced_supervisor\.sh/ || $0 ~ /rider\.sh/) {
        print
    }
')"

echo
echo "===== VERIFY ====="

if [ -n "$REMAINING" ]; then
    echo "$REMAINING"
    echo "STATUS : FAIL"
    exit 1
fi

# --------------------------------------------------
# 6) CLEAN STATE FILES
# --------------------------------------------------

rm -f "$RIDER_PID_FILE" 2>/dev/null || true
rm -f "$SUP_PID_FILE" 2>/dev/null || true
rm -f "$STOP_FILE" 2>/dev/null || true
rm -rf "$LOCK_DIR" 2>/dev/null || true
rm -rf "$SUP_LOCK_DIR" 2>/dev/null || true

# --------------------------------------------------
# 7) PRESERVE COUNTERS
# --------------------------------------------------

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

FINAL_ROUND="${FINAL_ROUND:-0}"
FINAL_HEARTBEAT="${FINAL_HEARTBEAT:-0}"
FINAL_SUCCESS="${FINAL_SUCCESS:-0}"
FINAL_ERRORS="${FINAL_ERRORS:-0}"
FINAL_BUGS="${FINAL_BUGS:-0}"
FINAL_LAST_ERROR="${FINAL_LAST_ERROR:-NONE}"

NOW="$(date '+%Y-%m-%d %H:%M:%S')"
TMP_STATE="$ROOT/tmp/system.state.stop.$$"

mkdir -p "$ROOT/tmp"

cat > "$TMP_STATE" <<STATE
STATUS=STOPPED
PID=0
ROUND=$FINAL_ROUND
HEARTBEAT=$FINAL_HEARTBEAT
TIME=$NOW
REASON=STOP_COMMAND
ENGINE_SUCCESS=$FINAL_SUCCESS
ENGINE_ERRORS=$FINAL_ERRORS
BUG_COUNT=$FINAL_BUGS
LAST_ERROR=$FINAL_LAST_ERROR
WAKE_LOCK=$WAKE_STATUS
STATE_OWNER=stop.sh
STATE

mv -f "$TMP_STATE" "$SYSTEM_FILE"

echo "STATUS       : STOPPED"
echo "PID_FILE     : CLEAR"
echo "SUPERVISOR   : CLEAR"
echo "LOCK         : CLEAR"
echo "WAKE_LOCK    : $WAKE_STATUS"
echo "PROCESS      : NONE"

echo
echo "=================================================="
echo " ✅ STOP ALL COMPLETE"
echo "=================================================="
