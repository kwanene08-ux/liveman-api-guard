#!/data/data/com.termux/files/usr/bin/bash

# ==========================================================
# BATTERY GUARD v8.8.3
# Real battery value + API rate limit + cache fallback
# ==========================================================

BATTERY_STATUS="STARTING"
BATTERY_PCT="--"
BATTERY_TEMP="--"
BATTERY_CACHE_AGE="--"

BATTERY_API_ERRORS=0
BATTERY_RECOVERIES=0

BATTERY_POLL_INTERVAL="${BATTERY_POLL_INTERVAL:-30}"
BATTERY_ERROR_COOLDOWN="${BATTERY_ERROR_COOLDOWN:-30}"

BATTERY_LAST_API_TIME=0
BATTERY_LAST_API_RC=0

battery_valid_json() {
    printf '%s' "$1" | jq -e '
        type == "object"
        and (.percentage != null)
        and (.temperature != null)
        and (.percentage | type == "number")
        and (.temperature | type == "number")
    ' >/dev/null 2>&1
}

battery_cache_age() {
    [ -f "$STATE_DIR/battery.cache.time" ] || return 1

    local saved now age

    saved="$(cat "$STATE_DIR/battery.cache.time" 2>/dev/null || echo "")"

    case "$saved" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    now="$(date +%s)"
    age=$((now - saved))

    [ "$age" -lt 0 ] && age=0

    BATTERY_CACHE_AGE="$age"

    printf '%s\n' "$age"

    return 0
}

battery_load_cache() {
    [ -s "$STATE_DIR/battery.state" ] || return 1

    BATTERY_PCT="$(
        jq -r '.percentage // "--"' \
        "$STATE_DIR/battery.state" 2>/dev/null || echo "--"
    )"

    BATTERY_TEMP="$(
        jq -r '.temperature // "--"' \
        "$STATE_DIR/battery.state" 2>/dev/null || echo "--"
    )"

    battery_cache_age >/dev/null 2>&1 || return 1

    return 0
}

battery_save_state() {
    local output="$1"

    printf '%s\n' "$output" \
        > "$STATE_DIR/battery.state.tmp.$$" || return 1

    mv -f "$STATE_DIR/battery.state.tmp.$$" \
        "$STATE_DIR/battery.state" || return 1

    date +%s > "$STATE_DIR/battery.cache.time"

    BATTERY_CACHE_AGE=0

    return 0
}

battery_api_due() {
    local now elapsed

    now="$(date +%s)"
    elapsed=$((now - ${BATTERY_LAST_API_TIME:-0}))

    if [ "${BATTERY_LAST_API_RC:-0}" -ne 0 ]; then
        [ "$elapsed" -ge "${BATTERY_ERROR_COOLDOWN:-30}" ]
        return
    fi

    [ "$elapsed" -ge "${BATTERY_POLL_INTERVAL:-30}" ]
}

battery_mark_api_attempt() {
    BATTERY_LAST_API_TIME="$(date +%s)"
}

battery_guard() {

    local output=""
    local rc=0

    BATTERY_STATUS="CHECKING"

    if ! have_cmd api_battery; then
        BATTERY_STATUS="COMMAND_MISSING"
        return 1
    fi

    if ! have_cmd jq; then
        BATTERY_STATUS="JQ_MISSING"
        return 1
    fi

    # ------------------------------------------------------
    # ใช้ค่าจาก cache ก่อน ถ้ายังไม่ถึงรอบอ่านใหม่
    # ------------------------------------------------------

    if ! battery_api_due; then

        if battery_load_cache; then
            BATTERY_STATUS="CACHE"
            return 0
        fi

        # ยังไม่มี cache แต่ยังไม่ถึงเวลา retry
        BATTERY_STATUS="API_COOLDOWN"
        return 1
    fi

    # ------------------------------------------------------
    # อ่าน Battery จริงเพียง 1 ครั้ง
    # ------------------------------------------------------

    battery_mark_api_attempt

    output="$(
        api_battery 2>/dev/null
    )"

    rc=$?
    BATTERY_LAST_API_RC="$rc"

    if [ "$rc" -eq 0 ] &&
       [ -n "$output" ] &&
       battery_valid_json "$output"
    then

        BATTERY_PCT="$(
            printf '%s' "$output" |
            jq -r '.percentage'
        )"

        BATTERY_TEMP="$(
            printf '%s' "$output" |
            jq -r '.temperature'
        )"

        if [ "${BATTERY_STATUS:-}" = "CACHE" ] ||
           [ "${BATTERY_API_ERRORS:-0}" -gt 0 ]
        then
            BATTERY_RECOVERIES=$((BATTERY_RECOVERIES + 1))
        fi

        battery_save_state "$output" || true

        BATTERY_API_ERRORS=0
        BATTERY_STATUS="LIVE"

        return 0
    fi

    # ------------------------------------------------------
    # API failure → cache fallback
    # ------------------------------------------------------

    BATTERY_API_ERRORS=$((BATTERY_API_ERRORS + 1))

    if battery_load_cache; then
        BATTERY_STATUS="CACHE"
        return 0
    fi

    BATTERY_STATUS="API_ERROR"

    return 1
}
