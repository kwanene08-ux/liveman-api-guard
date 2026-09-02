#!/data/data/com.termux/files/usr/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"

PID_FILE="$ROOT/state/rider.pid"
STOP_FILE="$ROOT/state/stop.request"
LOCK_DIR="$ROOT/state/rider.lock"

echo "=================================================="
echo " LIVE MAN API GUARD STOP"
echo "=================================================="

# ส่งคำสั่งหยุดแบบปลอดภัย
touch "$STOP_FILE"

PID=""

if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE" 2>/dev/null | tr -cd '0-9' || true)"
fi

# หยุดจาก PID
if [ -n "$PID" ]; then

    if kill -0 "$PID" 2>/dev/null; then

        echo "Stopping PID: $PID"

        kill -INT "$PID" 2>/dev/null || true

        for _ in 1 2 3 4 5; do

            kill -0 "$PID" 2>/dev/null || break

            sleep 1
        done

        # ยังอยู่ → TERM
        if kill -0 "$PID" 2>/dev/null; then

            echo "Sending TERM..."

            kill -TERM "$PID" 2>/dev/null || true

            sleep 2
        fi

        # ยังอยู่ → KILL
        if kill -0 "$PID" 2>/dev/null; then

            echo "Force Kill..."

            kill -KILL "$PID" 2>/dev/null || true
        fi

    fi
fi

# เก็บ process ที่เหลือใน project
PIDS="$(pgrep -f "$ROOT" 2>/dev/null || true)"

for P in $PIDS; do

    echo "Stopping leftover PID: $P"

    kill -TERM "$P" 2>/dev/null || true

done

sleep 1

# ล้าง process ค้าง
PIDS="$(pgrep -f "$ROOT" 2>/dev/null || true)"

for P in $PIDS; do

    kill -KILL "$P" 2>/dev/null || true

done

# ล้าง state
rm -f "$PID_FILE" 2>/dev/null || true
rm -f "$STOP_FILE" 2>/dev/null || true
rm -rf "$LOCK_DIR" 2>/dev/null || true

echo
echo "STOP COMPLETE"
echo "LOCK CLEARED"
echo "=================================================="
