#!/data/data/com.termux/files/usr/bin/bash

API_GUARD_SUCCESS="${API_GUARD_SUCCESS:-0}"
API_GUARD_CONSECUTIVE="${API_GUARD_CONSECUTIVE:-0}"
API_GUARD_LAST="${API_GUARD_LAST:-NONE}"
API_GUARD_LAST_TIME="${API_GUARD_LAST_TIME:---}"

API_GUARD_LOG_DIR="${LOG_DIR:-${ROOT:-$PWD}/logs}"
mkdir -p "$API_GUARD_LOG_DIR" 2>/dev/null || true

api_guard_log() {
    local message="$*"

    printf '%s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$message" \
        >> "$API_GUARD_LOG_DIR/api_guard.log" 2>/dev/null || true
}

api_silent() {
    [ "$#" -ge 1 ] || {
        API_GUARD_LAST="ERROR"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        api_guard_log "API_ERROR no_command"
        return 2
    }

    local cmd="$1"
    shift

    local timeout_sec
    local rc
    local arg
    local provider=""

    case "$cmd" in
        termux-location)
            timeout_sec="${API_LOCATION_TIMEOUT:-8}"

            # Separate fast timeout for network provider.
            for arg in "$@"; do
                if [ "$arg" = "network" ]; then
                    provider="network"
                    break
                fi
            done

            if [ "$provider" = "network" ]; then
                timeout_sec="${API_NETWORK_LOCATION_TIMEOUT:-3}"
            fi
            ;;

        termux-battery-status)
            timeout_sec="${API_BATTERY_TIMEOUT:-10}"
            ;;

        *)
            timeout_sec="${API_TIMEOUT:-10}"
            ;;
    esac

    if ! command -v "$cmd" >/dev/null 2>&1; then
        API_GUARD_LAST="COMMAND_MISSING"
        API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"
        API_GUARD_CONSECUTIVE=$((API_GUARD_CONSECUTIVE + 1))
        api_guard_log "API_COMMAND_MISSING command=$cmd"
        return 127
    fi

    timeout \
        --signal=TERM \
        --kill-after=2 \
        "$timeout_sec" \
        "$cmd" "$@" \
        2>>"$API_GUARD_LOG_DIR/api_error.log"

    rc=$?

    if [ "$rc" -eq 0 ]; then
        API_GUARD_SUCCESS=$((API_GUARD_SUCCESS + 1))
        API_GUARD_CONSECUTIVE=0
        API_GUARD_LAST="NONE"
        API_GUARD_LAST_TIME="--"
        return 0
    fi

    API_GUARD_CONSECUTIVE=$((API_GUARD_CONSECUTIVE + 1))
    API_GUARD_LAST_TIME="$(date '+%H:%M:%S')"

    if [ "$rc" -eq 124 ]; then
        API_GUARD_LAST="TIMEOUT"
        api_guard_log "API_TIMEOUT ${timeout_sec}s command=$cmd $*"
    else
        API_GUARD_LAST="ERROR"
        api_guard_log "API_ERROR rc=$rc command=$cmd $*"
    fi

    return "$rc"
}
api_location() {
    api_silent termux-location "$@"
}

api_battery() {
    api_silent termux-battery-status "$@"
}

api_guard_status() {
    if [ "${API_GUARD_CONSECUTIVE:-0}" -ge 5 ]; then
        echo "CRITICAL"
    elif [ "${API_GUARD_CONSECUTIVE:-0}" -ge 2 ]; then
        echo "WARNING"
    else
        echo "NORMAL"
    fi
}

api_guard_reset() {
    API_GUARD_CONSECUTIVE=0
    API_GUARD_LAST="NONE"
    API_GUARD_LAST_TIME="--"
}
