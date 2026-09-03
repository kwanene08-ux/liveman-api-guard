#!/data/data/com.termux/files/usr/bin/bash

WAKE_LOCK_STATUS="UNKNOWN"
WAKE_LOCK_ACTIVE=0

wake_lock_start() {
    WAKE_LOCK_STATUS="UNAVAILABLE"
    WAKE_LOCK_ACTIVE=0

    command -v termux-wake-lock >/dev/null 2>&1 || return 0

    if termux-wake-lock >/dev/null 2>&1; then
        WAKE_LOCK_STATUS="ACTIVE"
        WAKE_LOCK_ACTIVE=1
    else
        WAKE_LOCK_STATUS="ERROR"
    fi

    return 0
}

wake_lock_guard() {
    [ "${WAKE_LOCK_ACTIVE:-0}" -eq 1 ] && return 0
    wake_lock_start
    return 0
}

wake_lock_stop() {
    if command -v termux-wake-unlock >/dev/null 2>&1; then
        termux-wake-unlock >/dev/null 2>&1 || true
    fi

    WAKE_LOCK_STATUS="RELEASED"
    WAKE_LOCK_ACTIVE=0
    return 0
}

wake_lock_status() {
    printf '%s\n' "${WAKE_LOCK_STATUS:-UNKNOWN}"
}
