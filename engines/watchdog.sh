#!/data/data/com.termux/files/usr/bin/bash

WATCHDOG_STATUS="STARTING"

watchdog_tick() {

    local now

    now="$(date +%s)"

    printf '%s\n' "$now" \
        > "$STATE_DIR/heartbeat.state"

    WATCHDOG_STATUS="HEARTBEAT OK"
}

watchdog_check() {

    local heartbeat

    [ -f "$STATE_DIR/heartbeat.state" ] || {

        WATCHDOG_STATUS="NO HEARTBEAT"

        return 1
    }

    heartbeat="$(cat "$STATE_DIR/heartbeat.state")"

    local now

    now="$(date +%s)"

    local age=$((now - heartbeat))

    if [ "$age" -gt "$WATCHDOG_TIMEOUT" ]; then

        WATCHDOG_STATUS="STALE HEARTBEAT"

        return 1

    fi

    WATCHDOG_STATUS="OK"

    return 0
}
