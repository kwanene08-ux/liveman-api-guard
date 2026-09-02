#!/data/data/com.termux/files/usr/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"

PID_FILE="$ROOT/state/rider.pid"
STOP_FILE="$ROOT/state/stop.request"
LOCK_DIR="$ROOT/state/rider.lock"

echo "=================================================="
echo " 🔴 LIVE MAN API GUARD STOP"
echo "=================================================="

# ขอให้ rider หยุดอย่างปลอดภัยก่อน
touch "$STOP_FILE"

PID=""

if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null | tr -cd '0-9' || true)"
fi

if [ -n "$PID" ] && [ "$PID" != "$$" ]; then

    if kill -0 "$PID" 2>/dev/null; then

        echo "Rider PID : $PID"
        echo "Sending INT..."

        kill -INT "$PID" 2>/dev/null || true

        for _ in 1 2 3 4 5; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done

        if kill -0 "$PID" 2>/dev/null; then
            echo "Sending TERM..."
            kill -TERM "$PID" 2>/dev/null || true
            sleep 2
        fi

        if kill -0 "$PID" 2>/dev/null; then
            echo "Sending KILL..."
            kill -KILL "$PID" 2>/dev/null || true
            sleep 1
        fi

    else
        echo "Rider PID not running: $PID"
    fi

else
    echo "No active rider PID"
fi

# --------------------------------------------------
# ลบเฉพาะ process rider.sh ที่ยังเหลือ
# ห้าม kill $$ ของ stop.sh
# --------------------------------------------------

PIDS="$(pgrep -f "$ROOT/rider\.sh" 2>/dev/null || true)"

for P in $PIDS; do

    [ "$P" = "$$" ] && continue

    echo "Cleaning leftover rider PID: $P"
    kill -TERM "$P" 2>/dev/null || true

done

sleep 1

PIDS="$(pgrep -f "$ROOT/rider\.sh" 2>/dev/null || true)"

for P in $PIDS; do

    [ "$P" = "$$" ] && continue

    echo "Force cleaning rider PID: $P"
    kill -KILL "$P" 2>/dev/null || true

done

# --------------------------------------------------
# state cleanup
# --------------------------------------------------

rm -f "$PID_FILE" 2>/dev/null || true
rm -f "$STOP_FILE" 2>/dev/null || true
rm -rf "$LOCK_DIR" 2>/dev/null || true

sleep 1

echo
echo "===== VERIFY ====="

if pgrep -f "$ROOT/rider\.sh" >/dev/null 2>&1; then
    echo "STATUS : FAIL"
    echo "Rider process still exists"

    pgrep -af "$ROOT/rider\.sh" || true

    exit 1
else
    echo "STATUS : STOPPED"
fi

if [ -e "$LOCK_DIR" ]; then
    echo "LOCK   : STILL EXISTS"
else
    echo "LOCK   : CLEAR"
fi

echo "PROCESS: NO rider.sh"

echo
echo "=================================================="
echo " ✅ STOP COMPLETE"
echo "=================================================="
