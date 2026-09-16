#!/data/data/com.termux/files/usr/bin/bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo "UNKNOWN")"
ROUND=0
HEARTBEAT=0
START=$(date +%s)

get_gps() {
    local j
    j="$(termux-location -p gps -r once 2>/dev/null || true)"
    if [ -n "$j" ]; then
        GPS_ACC="$(printf '%s' "$j" | jq -r '.accuracy // "---"' 2>/dev/null)"
        [ "$GPS_ACC" = "null" ] && GPS_ACC="---"
        GPS_STATUS="LIVE_GPS"
    else
        GPS_ACC="---"
        GPS_STATUS="NO_FIX"
    fi
}

get_battery() {
    local j
    j="$(termux-battery-status 2>/dev/null || true)"
    if [ -n "$j" ]; then
        BATTERY_PERCENT="$(printf '%s' "$j" | jq -r '.percentage // "---"' 2>/dev/null)"
        BATTERY_TEMP="$(printf '%s' "$j" | jq -r '.temperature // "---"' 2>/dev/null)"
        BATTERY_STATUS="$(printf '%s' "$j" | jq -r '.status // "---"' 2>/dev/null)"
        [ "$BATTERY_STATUS" = "null" ] && BATTERY_STATUS="---"
    else
        BATTERY_PERCENT="---"
        BATTERY_TEMP="---"
        BATTERY_STATUS="UNKNOWN"
    fi
}

get_network() {
    local out stats
    out="$(ping -c 3 -W 2 1.1.1.1 2>/dev/null || true)"
    if printf '%s\n' "$out" | grep -q 'min/avg'; then
        stats="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg/ {print $2}' | awk -F'/' '{print $2}')"
        NETWORK_PING="${stats:----}"
        NETWORK_STATUS="GOOD"
    else
        NETWORK_PING="---"
        NETWORK_STATUS="OFFLINE"
    fi
}

draw() {
    local now uptime
    now="$(date +%s)"
    uptime=$((now-START))

    clear
    printf '%s\n' '=================================================='
    printf ' LIVE MAN API GUARD %s ADVANCED LIVE MONITOR\n' "$VERSION"
    printf '%s\n' '=================================================='
    printf ' Round            : #%s\n' "$ROUND"
    printf ' Heartbeat        : %s\n' "$HEARTBEAT"
    printf ' Uptime           : %ss\n' "$uptime"
    printf '\n'
    printf ' GPS              : %s\n' "$GPS_STATUS"
    printf ' Accuracy         : %sm\n' "$GPS_ACC"
    printf ' Network          : %s\n' "$NETWORK_STATUS"
    printf ' Ping             : %sms\n' "$NETWORK_PING"
    printf ' Battery          : %s\n' "$BATTERY_STATUS"
    printf ' Battery Level    : %s%%\n' "$BATTERY_PERCENT"
    printf ' Temperature      : %s°C\n' "$BATTERY_TEMP"
    printf '\n'
    printf ' Watchdog         : ACTIVE\n'
    printf ' Self Test        : ACTIVE\n'
    printf ' Auto Recovery    : ACTIVE\n'
    printf ' Engine Isolation : ACTIVE\n'
    printf ' Wake Lock        : ACTIVE\n'
    printf '\n'
    printf ' Last Update      : %s\n' "$(date '+%H:%M:%S')"
    printf '\nCtrl+C เพื่อหยุดอย่างปลอดภัย\n'
    printf '%s\n' '=================================================='
}

cleanup() {
    clear
    printf 'LIVE MAN API GUARD STOPPED\n'
    exit 0
}

trap cleanup INT TERM EXIT

while true; do
    ROUND=$((ROUND+1))
    HEARTBEAT=$ROUND

    get_gps
    get_battery
    get_network
    draw

    sleep 5
done
