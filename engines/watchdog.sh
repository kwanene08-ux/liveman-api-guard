#!/data/data/com.termux/files/usr/bin/bash

WATCHDOG_STATUS="STARTING"

watchdog_tick() {
    local now
    local tmp_file

    now="$(date +%s)"
    tmp_file="$STATE_DIR/heartbeat.state.tmp.$$"

    mkdir -p "$STATE_DIR" || {
        WATCHDOG_STATUS="STATE DIR FAILED"
        return 1
    }

    printf '%s\n' "$now" > "$tmp_file" || {
        WATCHDOG_STATUS="HEARTBEAT WRITE FAILED"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    }

    mv -f "$tmp_file" "$STATE_DIR/heartbeat.state" || {
        WATCHDOG_STATUS="HEARTBEAT COMMIT FAILED"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    }

    WATCHDOG_STATUS="HEARTBEAT OK"
    return 0
}

watchdog_check() {
    local heartbeat
    local now
    local age
    local timeout="${WATCHDOG_TIMEOUT:-30}"

    [ -f "$STATE_DIR/heartbeat.state" ] || {
        WATCHDOG_STATUS="NO HEARTBEAT"
        return 1
    }

    heartbeat="$(
        head -n 1 "$STATE_DIR/heartbeat.state" 2>/dev/null |
        tr -d '\r\n[:space:]'
    )"

    case "$heartbeat" in
        ''|*[!0-9]*)
            WATCHDOG_STATUS="INVALID HEARTBEAT"
            return 1
            ;;
    esac

    now="$(date +%s)"
    age=$((now - heartbeat))

    if [ "$age" -lt 0 ]; then
        WATCHDOG_STATUS="FUTURE HEARTBEAT"
        return 1
    fi

    if [ "$age" -gt "$timeout" ]; then
        WATCHDOG_STATUS="STALE HEARTBEAT"
        return 1
    fi

    WATCHDOG_STATUS="OK"
    return 0
}
