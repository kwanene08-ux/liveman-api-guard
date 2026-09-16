#!/data/data/com.termux/files/usr/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT/state"
LOG_DIR="$ROOT/logs"
START="$(date +%s)"
START_ROUND="$(awk -F= '/^ROUND=/{print $2}' "$STATE_DIR/system.state" 2>/dev/null)"
START_RESTARTS="$(awk -F= '/^RESTARTS=/{print $2}' "$STATE_DIR/supervisor.state" 2>/dev/null || echo 0)"

echo "===== LIVE MAN API GUARD v12.3.4 FINAL QA ====="
echo "เริ่มทดสอบ: $(date '+%F %T')"
echo "ปล่อยระบบทำงาน 5 นาที..."

while [ $(( $(date +%s) - START )) -lt 300 ]; do
    sleep 15
done

END_ROUND="$(awk -F= '/^ROUND=/{print $2}' "$STATE_DIR/system.state" 2>/dev/null)"
CURRENT_PID="$(awk -F= '/^PID=/{print $2}' "$STATE_DIR/system.state" 2>/dev/null)"
HEARTBEAT_AGE="$(awk -v now="$(date +%s)" 'NR==1{print now-$1}' "$STATE_DIR/heartbeat.state" 2>/dev/null)"
END_RESTARTS="$(awk -F= '/^RESTARTS=/{print $2}' "$STATE_DIR/supervisor.state" 2>/dev/null || echo 0)"

[ -n "$START_ROUND" ] || START_ROUND=0
[ -n "$END_ROUND" ] || END_ROUND=0
[ -n "$HEARTBEAT_AGE" ] || HEARTBEAT_AGE=999
[ -n "$START_RESTARTS" ] || START_RESTARTS=0
[ -n "$END_RESTARTS" ] || END_RESTARTS=0

NEW_EVENTS="$(awk -v start="$START" '
/HEARTBEAT_STALE|RIDER_PROCESS_DOWN|AUTO_RESTART|RESTART/ {
    match($0,/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)
    if (RSTART > 0) print
}' "$LOG_DIR"/*.log 2>/dev/null | tail -20)"

echo
echo "===== FINAL RESULT ====="
echo "ROUND_START=$START_ROUND"
echo "ROUND_END=$END_ROUND"
echo "ROUNDS_COMPLETED=$((END_ROUND-START_ROUND))"
echo "CURRENT_PID=$CURRENT_PID"
echo "HEARTBEAT_AGE=${HEARTBEAT_AGE}s"
echo "RESTARTS_START=$START_RESTARTS"
echo "RESTARTS_END=$END_RESTARTS"

if kill -0 "$CURRENT_PID" 2>/dev/null &&
   [ "$HEARTBEAT_AGE" -le 10 ] &&
   [ "$END_RESTARTS" -eq "$START_RESTARTS" ] &&
   [ "$END_ROUND" -gt "$START_ROUND" ]; then
    echo "QA=PASS"
    echo "พร้อมใช้งานเบื้องต้น"
else
    echo "QA=REVIEW_REQUIRED"
    echo "ยังต้องตรวจเพิ่มเติม"
fi
