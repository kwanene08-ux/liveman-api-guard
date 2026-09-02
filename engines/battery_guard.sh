#!/data/data/com.termux/files/usr/bin/bash

BATTERY_STATUS="STARTING"
BATTERY_PCT="--"
BATTERY_TEMP="--"
BATTERY_CACHE_AGE="--"

BATTERY_API_ERRORS=0
BATTERY_RECOVERIES=0


battery_valid_json() {

    printf '%s' "$1" | jq -e '
        type == "object"
        and (.percentage != null)
        and (.temperature != null)
    ' >/dev/null 2>&1
}


battery_cache_age() {

    [ -f "$STATE_DIR/battery.cache.time" ] || return 1

    local saved now age

    saved="$(cat "$STATE_DIR/battery.cache.time" 2>/dev/null)"

    case "$saved" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    now="$(date +%s)"
    age=$((now - saved))

    if [ "$age" -lt 0 ]; then
        age=0
    fi

    BATTERY_CACHE_AGE="$age"

    printf '%s\n' "$age"

    return 0
}


battery_save_state() {

    printf '%s\n' "$1" > "$STATE_DIR/battery.state" || return 1

    date +%s > "$STATE_DIR/battery.cache.time" || true

    BATTERY_CACHE_AGE=0

    return 0
}


battery_load_cache() {

    [ -s "$STATE_DIR/battery.state" ] || return 1

    local max_age="${BATTERY_CACHE_MAX_AGE:-300}"
    local age

    age="$(battery_cache_age)" || return 2

    BATTERY_PCT="$(jq -r '.percentage // "--"' \
        "$STATE_DIR/battery.state" 2>/dev/null || echo "--")"

    BATTERY_TEMP="$(jq -r '.temperature // "--"' \
        "$STATE_DIR/battery.state" 2>/dev/null || echo "--")"

    if [ "$age" -le "$max_age" ]; then
        return 0
    fi

    return 3
}


battery_guard() {

    local output=""
    local rc=0
    local attempt=1
    local max_retries="${API_RETRIES:-3}"
    local had_error=0
    local cache_rc=1

    BATTERY_STATUS="CHECKING"

    if ! have_cmd api_battery; then
        BATTERY_STATUS="COMMAND_MISSING"
        return 1
    fi

    if ! have_cmd jq; then
        BATTERY_STATUS="JQ_MISSING"
        return 1
    fi


    while [ "$attempt" -le "$max_retries" ]; do

        # สำคัญ:
        # เรียก API wrapper โดยตรง
        # ไม่ timeout ครอบ Bash function

        output="$(
            api_battery 2>/dev/null
        )"

        rc=$?

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

            if [ "$had_error" -eq 1 ]; then
                BATTERY_RECOVERIES=$((BATTERY_RECOVERIES + 1))
            fi

            battery_save_state "$output" || true

            BATTERY_STATUS="LIVE"

            return 0
        fi


        had_error=1

        BATTERY_API_ERRORS=$((BATTERY_API_ERRORS + 1))

        attempt=$((attempt + 1))

        if [ "$attempt" -le "$max_retries" ]; then
            sleep 1
        fi
    done


    # cache with age validation

    battery_load_cache
    cache_rc=$?

    if [ "$cache_rc" -eq 0 ]; then

        BATTERY_STATUS="CACHE"

        return 0

    elif [ "$cache_rc" -eq 3 ]; then

        BATTERY_STATUS="STALE_CACHE"

        return 1
    fi


    BATTERY_STATUS="API_ERROR"

    return 1
}
