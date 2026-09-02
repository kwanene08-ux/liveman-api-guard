#!/data/data/com.termux/files/usr/bin/bash

ERROR_GUARD_TOTAL=0
ERROR_GUARD_CONSECUTIVE=0
ERROR_GUARD_RECOVERIES=0
ERROR_GUARD_LAST="NONE"
ERROR_GUARD_TYPE="NONE"
ERROR_GUARD_LAST_TIME="--"

error_guard_log() {

    local type="${1:-UNKNOWN}"
    local message="${2:-UNKNOWN}"

    ERROR_GUARD_TOTAL=$((ERROR_GUARD_TOTAL + 1))
    ERROR_GUARD_CONSECUTIVE=$((ERROR_GUARD_CONSECUTIVE + 1))

    ERROR_GUARD_TYPE="$type"
    ERROR_GUARD_LAST="$message"
    ERROR_GUARD_LAST_TIME="$(date '+%H:%M:%S')"

    mkdir -p "${LOG_DIR:-$HOME/LIVE_MAN_API_GUARD/logs}"

    printf '%s | TYPE=%s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$type" \
        "$message" \
        >> "${LOG_DIR:-$HOME/LIVE_MAN_API_GUARD/logs}/error_guard.log" \
        2>/dev/null || true
}


error_guard_success() {

    ERROR_GUARD_CONSECUTIVE=0
}


safe_engine_run() {
    local name="$1"
    local function="$2"

    if ! declare -F "$function" >/dev/null 2>&1; then
        error_guard_log \
            "FUNCTION_MISSING" \
            "$name function=$function"
        return 1
    fi

    # The actual API timeout is handled by lib/api_guard.sh.
    # Do not use a separate timeout subprocess here because the
    # engine function runs in the parent shell and must return
    # its state variables to rider.sh.

    if "$function"; then
        error_guard_success
        return 0
    fi

    error_guard_log \
        "ENGINE_ERROR" \
        "$name failed"

    return 1
}


api_command() {

    local timeout_sec="${1:-10}"

    shift

    local output
    local rc

    output="$(
        timeout "$timeout_sec" "$@" 2>&1
    )"

    rc=$?

    if [ "$rc" -eq 124 ]; then

        error_guard_log \
            "TIMEOUT" \
            "command=$*"

        return 124
    fi

    if [ "$rc" -ne 0 ]; then

        error_guard_log \
            "COMMAND_ERROR" \
            "command=$* rc=$rc"

        return "$rc"
    fi

    printf '%s\n' "$output"

    return 0
}


error_guard_recovery() {

    local limit="${ERROR_RECOVERY_LIMIT:-3}"

    if [ "$ERROR_GUARD_CONSECUTIVE" -lt "$limit" ]; then
        return 0
    fi

    ERROR_GUARD_RECOVERIES=$((ERROR_GUARD_RECOVERIES + 1))

    printf '%s\n' \
        "$(date +%s)" \
        > "$STATE_DIR/error_guard_recovery.time" \
        2>/dev/null || true

    ERROR_GUARD_CONSECUTIVE=0

    return 0
}


error_guard_status() {

    if [ "$ERROR_GUARD_CONSECUTIVE" -ge "${ERROR_CRITICAL_LIMIT:-5}" ]; then

        echo "CRITICAL"

    elif [ "$ERROR_GUARD_CONSECUTIVE" -ge "${ERROR_WARNING_LIMIT:-2}" ]; then

        echo "WARNING"

    else

        echo "NORMAL"
    fi
}
