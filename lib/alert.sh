#!/data/data/com.termux/files/usr/bin/bash

ALERT_COUNT=0
ALERT_LAST="NONE"

smart_alert() {

    local key="$1"
    local message="$2"

    local cooldown="${ALERT_COOLDOWN:-30}"

    local file="$STATE_DIR/alert_${key}.time"

    local now
    now="$(date +%s)"

    local last=0

    if [ -f "$file" ]; then
        last="$(cat "$file" 2>/dev/null || echo 0)"
    fi

    if ! awk -v n="$now" -v l="$last" -v c="$cooldown" \
        'BEGIN { exit !((n-l) >= c) }'
    then
        return 0
    fi

    echo "$now" > "$file"

    ALERT_COUNT=$((ALERT_COUNT + 1))
    ALERT_LAST="$message"

    echo "ALERT: $message" \
        >> "$LOG_DIR/current.log" 2>/dev/null || true

    return 0
}


smart_alert_check() {

    if [ "${NETWORK_STATUS:-}" = "BAD" ]; then
        smart_alert \
            "network_bad" \
            "NETWORK BAD ping=${NETWORK_PING:---}ms"
    fi

    if [ "${NETWORK_TREND:-}" = "RISING" ]; then
        smart_alert \
            "network_rising" \
            "NETWORK PING RISING"
    fi

    if [ "${GPS_STATUS:-}" = "CACHE" ]; then
        smart_alert \
            "gps_cache" \
            "GPS USING CACHE"
    fi

    if [ "${GPS_TREND:-}" = "RISING" ]; then
        smart_alert \
            "gps_accuracy" \
            "GPS ACCURACY DEGRADING"
    fi

    if [ "${THERMAL_STATUS:-}" = "HIGH" ] ||
       [ "${THERMAL_STATUS:-}" = "CRITICAL" ]
    then
        smart_alert \
            "thermal" \
            "THERMAL ${THERMAL_STATUS}"
    fi

    if [ "${SYSTEM_HEALTH_STATUS:-}" = "WARNING" ] ||
       [ "${SYSTEM_HEALTH_STATUS:-}" = "CRITICAL" ]
    then
        smart_alert \
            "health" \
            "SYSTEM HEALTH ${SYSTEM_HEALTH_STATUS}"
    fi
}
